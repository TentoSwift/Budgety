//
//  SheetAIChat.swift
//  Expenso
//
//  シート単位の AI チャット。`LanguageModelSession` (iOS 26+) を使い、
//  シートの最近の支出 / 統計サマリを context として渡し、ユーザーの質問に
//  自然文で答える。マルチターンを保つため session を保持する。
//

import Foundation
import Combine
import FoundationModels

@MainActor
final class SheetAIChat: ObservableObject {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant, error }
        let id = UUID()
        let role: Role
        var text: String
        let createdAt: Date = .now
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isThinking: Bool = false
    @Published var inputText: String = ""

    private let sheet: ExpenseSheet
    private let session: LanguageModelSession?

    init(sheet: ExpenseSheet) {
        self.sheet = sheet
        if SystemLanguageModel.default.availability == .available {
            let context = Self.buildContext(for: sheet)
            let instructions = Self.systemInstructions(context: context)
            self.session = LanguageModelSession(instructions: instructions)
            // ウェルカムメッセージ
            self.messages = [
                Message(
                    role: .assistant,
                    text: "「\(sheet.displayName)」の支出について何でも聞いてください。\n例: 「今月の食費は?」「先週いちばん多く使った日は?」"
                )
            ]
        } else {
            self.session = nil
            self.messages = [
                Message(
                    role: .error,
                    text: "AI チャットには iOS 26+ と Apple Intelligence 対応端末が必要です。"
                )
            ]
        }
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// メッセージ送信。空文字や利用不可状態は黙ってスキップ。
    func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return }
        guard !isThinking else { return }

        messages.append(Message(role: .user, text: trimmed))
        inputText = ""
        isThinking = true

        Task { @MainActor in
            do {
                let response = try await session.respond(to: trimmed)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(Message(role: .assistant, text: text.isEmpty ? "(空の応答)" : text))
            } catch {
                #if DEBUG
                print("⚠️ SheetAIChat: \(error)")
                #endif
                messages.append(Message(role: .error, text: "応答できませんでした: \(error.localizedDescription)"))
            }
            isThinking = false
        }
    }

    func resetConversation() {
        guard Self.isAvailable else { return }
        messages = [
            Message(
                role: .assistant,
                text: "新しいチャットを始めました。何でも聞いてください。"
            )
        ]
        // session 自体は同じものを引き続き使う (instructions は不変)。
        // 過去の Q&A 履歴は LLM 内部で保持されているが、reset 表示で UX 上は新規扱い。
    }

    // MARK: - Context construction

    private static func systemInstructions(context: String) -> String {
        """
        あなたは家計簿アプリ「Expenso」のシート専用アシスタントです。
        ユーザーの支出/収入データに基づいて、日本語で自然に答えます。

        回答ルール:
        - 必ず提供されたデータの数値をもとに答える。データに無い情報は推測しない。
        - 数値を出す時は、コンテキストの通貨記号 (\(context.contains("通貨: JPY") ? "¥" : "$") など) を併記する。
        - 「分かりません」と答える時は、その理由 (例: そのカテゴリは記録がない) を 1 文で添える。
        - 1 メッセージ 3 行以内が望ましい。長い表は避ける。
        - データに含まれない期間 / カテゴリ / 人物について聞かれたら、データ不在を明示する。

        ---
        データ:
        \(context)
        """
    }

    private static func buildContext(for sheet: ExpenseSheet) -> String {
        let cal = Calendar.current
        let now = Date()
        let target = sheet.resolvedDefaultCurrencyCode
        let fx = FXRatesService.shared

        var lines: [String] = []
        lines.append("シート名: \(sheet.displayName)")
        lines.append("通貨: \(target)")
        lines.append("今日: \(formatDate(now))")
        lines.append("")

        let allExpenses = ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        // 今月の合計
        let thisMonth = allExpenses.filter {
            cal.isDate($0.date ?? .distantPast, equalTo: now, toGranularity: .month)
        }
        let (mExp, mInc) = totals(of: thisMonth, target: target, fx: fx)
        lines.append("今月の合計: 支出 \(format(mExp, code: target)) / 収入 \(format(mInc, code: target)) (\(thisMonth.count) 件)")

        // 先月の合計 (比較用)
        if let prev = cal.date(byAdding: .month, value: -1, to: now) {
            let prevMonth = allExpenses.filter {
                cal.isDate($0.date ?? .distantPast, equalTo: prev, toGranularity: .month)
            }
            let (pExp, pInc) = totals(of: prevMonth, target: target, fx: fx)
            lines.append("先月の合計: 支出 \(format(pExp, code: target)) / 収入 \(format(pInc, code: target)) (\(prevMonth.count) 件)")
        }
        lines.append("")

        // 今月のカテゴリ別
        if !thisMonth.isEmpty {
            lines.append("今月のカテゴリ別 (上位):")
            let byCategory = Dictionary(grouping: thisMonth) { $0.categoryDisplayName }
            let rows = byCategory.map { (name, list) -> (String, Decimal, Int) in
                let sum = list.reduce(Decimal(0)) { acc, e in
                    acc + (fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal)
                }
                return (name, sum, list.count)
            }.sorted { $0.1 > $1.1 }
            for r in rows.prefix(8) {
                lines.append("  - \(r.0): \(format(r.1, code: target)) (\(r.2) 件)")
            }
            lines.append("")
        }

        // 最近の Expense (新しい順)
        let recent = Array(allExpenses.prefix(40))
        if !recent.isEmpty {
            lines.append("最近の支出/収入 (新しい順、最大 40 件):")
            for e in recent {
                let dateLabel = formatDate(e.date ?? .now)
                let kindLabel = e.kind == .income ? "収入" : "支出"
                let category = e.categoryDisplayName
                let payer = e.paidBy?.isEmpty == false ? e.paidBy! : "未指定"
                let title = e.displayTitle.isEmpty ? "(無題)" : e.displayTitle
                let amount = format(e.amountDecimal, code: e.resolvedCurrencyCode)
                lines.append("  - \(dateLabel) [\(kindLabel)] \(title) (\(category)): \(amount) / \(payer)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func totals(of list: [Expense], target: String, fx: FXRatesService) -> (Decimal, Decimal) {
        var exp: Decimal = 0
        var inc: Decimal = 0
        for e in list {
            let amt = fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal
            switch e.kind {
            case .expense: exp += amt
            case .income:  inc += amt
            }
        }
        return (exp, inc)
    }

    private static func format(_ value: Decimal, code: String) -> String {
        CurrencyCatalog.format(value, code: code)
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd"
        return f.string(from: date)
    }
}

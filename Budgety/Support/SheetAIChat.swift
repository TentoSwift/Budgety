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
import CoreData
import CryptoKit
import FoundationModels

@MainActor
final class SheetAIChat: ObservableObject {
    struct Message: Identifiable, Equatable, Codable {
        enum Role: String, Codable { case user, assistant, error }
        var id = UUID()
        let role: Role
        var text: String
        var createdAt: Date = .now
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isThinking: Bool = false
    @Published var inputText: String = ""

    private let sheet: ExpenseSheet
    /// セッションは支出データのスナップショット (instructions) を内部に固定で持つため、
    /// 削除/編集でデータが変わったら作り直す必要がある。`refreshContext()` 参照。
    private var session: LanguageModelSession?
    /// 直近に session を組み立てたときのデータ指紋。変化が無ければ作り直しを省く。
    private var contextFingerprint: String = ""
    /// 履歴 JSON の保存先 (Application Support 配下、シートごとに別ファイル)
    private let historyURL: URL

    init(sheet: ExpenseSheet) {
        self.sheet = sheet
        self.historyURL = Self.historyFileURL(for: sheet)

        if SystemLanguageModel.default.availability == .available {
            self.session = Self.makeSession(for: sheet)
            self.contextFingerprint = Self.dataFingerprint(for: sheet)

            // 永続化された履歴があれば復元、なければウェルカム
            if let saved = Self.loadMessages(from: historyURL), !saved.isEmpty {
                self.messages = saved
            } else {
                self.messages = [
                    Message(
                        role: .assistant,
                        text: "「\(sheet.displayName)」の支出について何でも聞いてください。\n例: 「今月の食費は?」「先週いちばん多く使った日は?」"
                    )
                ]
            }
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

    /// 現在のシートデータで `LanguageModelSession` を組み立てる。
    private static func makeSession(for sheet: ExpenseSheet) -> LanguageModelSession {
        let context = buildContext(for: sheet)
        let instructions = systemInstructions(context: context)
        return LanguageModelSession(instructions: instructions)
    }

    /// チャット画面が表示されたタイミングで呼ぶ。支出の追加/編集/削除で
    /// データが変わっていたら session (= instructions のデータスナップショット) を
    /// 作り直して最新状態を反映する。応答ストリーミング中は触らない。
    func refreshContext() {
        guard Self.isAvailable, !isThinking else { return }
        let fingerprint = Self.dataFingerprint(for: sheet)
        guard fingerprint != contextFingerprint else { return }
        session = Self.makeSession(for: sheet)
        contextFingerprint = fingerprint
    }

    /// 支出データの軽量な指紋。件数 + 各支出の id/更新時刻/金額から作る。
    /// これが変われば「データが変わった」とみなして session を作り直す。
    private static func dataFingerprint(for sheet: ExpenseSheet) -> String {
        let expenses = (sheet.expenses as? Set<Expense>) ?? []
        // 並びに依存しないよう、各支出の identity を sort して連結。
        let parts = expenses.map { e -> String in
            let id = e.objectID.uriRepresentation().absoluteString
            let amount = NSDecimalNumber(decimal: e.amountDecimal).stringValue
            let date = (e.date ?? .distantPast).timeIntervalSince1970
            return "\(id)|\(amount)|\(date)|\(e.resolvedCurrencyCode)|\(e.categoryDisplayName)"
        }.sorted()
        return "\(expenses.count)#" + parts.joined(separator: ";")
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// メッセージ送信。空文字や利用不可状態は黙ってスキップ。
    /// 応答はストリーミング受信して、placeholder の assistant メッセージ text を逐次更新する。
    func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return }
        guard !isThinking else { return }

        messages.append(Message(role: .user, text: trimmed))
        // 受信先の placeholder を 1 つ追加。stream で text をどんどん書き換えていく。
        let placeholder = Message(role: .assistant, text: "")
        let placeholderID = placeholder.id
        messages.append(placeholder)
        inputText = ""
        isThinking = true

        Task { @MainActor in
            defer {
                isThinking = false
                saveMessages()
            }
            do {
                let stream = session.streamResponse(to: trimmed)
                for try await partial in stream {
                    if let i = messages.firstIndex(where: { $0.id == placeholderID }) {
                        messages[i].text = partial.content
                    }
                }
                // 末尾を trim して仕上げ
                if let i = messages.firstIndex(where: { $0.id == placeholderID }) {
                    let trimmedFinal = messages[i].text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    messages[i].text = trimmedFinal.isEmpty ? "(空の応答)" : trimmedFinal
                }
            } catch {
                #if DEBUG
                print("⚠️ SheetAIChat stream: \(error)")
                #endif
                // 受信中の placeholder は捨ててエラー表示に置き換え
                if let i = messages.firstIndex(where: { $0.id == placeholderID }) {
                    messages.remove(at: i)
                }
                messages.append(Message(role: .error, text: "応答できませんでした: \(error.localizedDescription)"))
            }
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
        saveMessages()
    }

    // MARK: - Persistence

    /// 現在の messages を historyURL に JSON で書き出す。
    /// ストリーミング中の partial は重いので、`send` の defer / `resetConversation` から
    /// 最終形のみ書く運用。
    private func saveMessages() {
        let url = historyURL
        let snapshot = messages
        // Disk I/O はメインから外す。
        Task.detached(priority: .background) {
            do {
                let dir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                #if DEBUG
                print("⚠️ SheetAIChat saveMessages: \(error)")
                #endif
            }
        }
    }

    private static func loadMessages(from url: URL) -> [Message]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Message].self, from: data)
        } catch {
            #if DEBUG
            print("⚠️ SheetAIChat loadMessages: \(error)")
            #endif
            return nil
        }
    }

    /// シートごとの履歴ファイル URL。
    /// objectID URI を SHA256 してファイル名にする (URI に含まれる /, : を避けるため)。
    private static func historyFileURL(for sheet: ExpenseSheet) -> URL {
        let uri = sheet.objectID.uriRepresentation().absoluteString
        let hash = SHA256.hash(data: Data(uri.utf8))
        let filename = hash.map { String(format: "%02x", $0) }.joined()
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("AIChat", isDirectory: true)
            .appendingPathComponent("\(filename).json")
    }

    // MARK: - Context construction

    private static func systemInstructions(context: String) -> String {
        """
        あなたは家計簿アプリ「Budgety」のシート専用アシスタントです。
        ユーザーの支出/収入データに基づいて、日本語で自然に答えます。

        重要 — 支出と収入は必ず区別する:
        - 各項目には [支出] または [収入] のタグが付いている。
        - 金額は支出なら `-` (マイナス)、収入なら `+` (プラス) で表記される。
        - 「支出」と聞かれたら [支出] タグ / `-` 記号の項目だけ集計する。
        - 「収入」と聞かれたら [収入] タグ / `+` 記号の項目だけ集計する。
        - 「合計」「使った」「払った」「コスト」などは支出のみを意味する。
        - 「もらった」「入った」「給料」「ボーナス」などは収入のみを意味する。
        - 区別せずに混ぜて合算しないこと。

        重要 — 個別の項目を列挙しない:
        - 「いくら?」「合計は?」「今月は?」のような **金額を尋ねる質問** には、
          合計金額 (と件数) のみを 1 行で答え、個別の項目は列挙しない。
          例: 「食費はいくら?」 → 「今月の食費は ¥12,300 (8 件) です。」
        - 個別項目を列挙してよいのは、ユーザーが **明示的に項目を求めた時だけ**:
          「一覧」「リスト」「内訳」「項目」「明細」「詳細」「全部」「履歴」
          「最近の」「直近の」「いくつあるか」「何件」 などの語が含まれている場合。
        - カテゴリ別の内訳を聞かれた場合 (例: 「カテゴリ別に教えて」) は、
          各カテゴリの合計だけを並べる (個別項目ではない)。
        - 列挙を求められた場合でも、上限は 10 件までにし、それ以上は
          「他 N 件」と省略する。

        その他のルール:
        - 必ず提供されたデータの数値をもとに答える。データに無い情報は推測しない。
        - 数値を出す時は通貨単位 (¥ や $) を併記する。
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
        lines.append("注意: 各項目の種別は [支出] / [収入] で明示する。")
        lines.append("金額の符号は支出なら `-`、収入なら `+` を付ける。")
        lines.append("カテゴリ集計は支出と収入を分けて記載する (= 同じカテゴリ名でも種別が違えば別の集計)。")
        lines.append("")

        let allExpenses = ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        // 今月の合計
        let thisMonth = allExpenses.filter {
            cal.isDate($0.date ?? .distantPast, equalTo: now, toGranularity: .month)
        }
        let (mExp, mInc) = totals(of: thisMonth, target: target, fx: fx)
        lines.append("今月の合計:")
        lines.append("  支出: \(format(mExp, code: target)) (\(thisMonth.filter { $0.kind == .expense }.count) 件)")
        lines.append("  収入: \(format(mInc, code: target)) (\(thisMonth.filter { $0.kind == .income }.count) 件)")

        // 先月の合計 (比較用)
        if let prev = cal.date(byAdding: .month, value: -1, to: now) {
            let prevMonth = allExpenses.filter {
                cal.isDate($0.date ?? .distantPast, equalTo: prev, toGranularity: .month)
            }
            let (pExp, pInc) = totals(of: prevMonth, target: target, fx: fx)
            lines.append("先月の合計:")
            lines.append("  支出: \(format(pExp, code: target)) (\(prevMonth.filter { $0.kind == .expense }.count) 件)")
            lines.append("  収入: \(format(pInc, code: target)) (\(prevMonth.filter { $0.kind == .income }.count) 件)")
        }
        lines.append("")

        // 今月のカテゴリ別 (kind ごとに分割)
        appendCategoryBreakdown(
            title: "今月の支出カテゴリ別 (上位):",
            list: thisMonth.filter { $0.kind == .expense },
            target: target, fx: fx, into: &lines
        )
        appendCategoryBreakdown(
            title: "今月の収入カテゴリ別 (上位):",
            list: thisMonth.filter { $0.kind == .income },
            target: target, fx: fx, into: &lines
        )

        // 最近の Expense (新しい順)
        let recent = Array(allExpenses.prefix(40))
        if !recent.isEmpty {
            lines.append("最近の項目 (新しい順、最大 40 件):")
            for e in recent {
                let dateLabel = formatDate(e.date ?? .now)
                let kindLabel = e.kind == .income ? "収入" : "支出"
                let category = e.categoryDisplayName
                let resolved = e.displayPaidBy
                let payer = resolved.isEmpty ? "未指定" : resolved
                let title = e.displayTitle.isEmpty ? "(無題)" : e.displayTitle
                let signed = signedAmount(value: e.amountDecimal, kind: e.kind, code: e.resolvedCurrencyCode)
                lines.append("  - \(dateLabel) [\(kindLabel)] \(title) (\(category)): \(signed) / \(payer)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 1 つの kind に絞ったカテゴリ別合計を append する。空ならセクションごとスキップ。
    private static func appendCategoryBreakdown(
        title: String,
        list: [Expense],
        target: String,
        fx: FXRatesService,
        into lines: inout [String]
    ) {
        guard !list.isEmpty else { return }
        lines.append(title)
        let byCategory = Dictionary(grouping: list) { $0.categoryDisplayName }
        let rows = byCategory.map { (name, items) -> (String, Decimal, Int) in
            let sum = items.reduce(Decimal(0)) { acc, e in
                acc + (fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal)
            }
            return (name, sum, items.count)
        }.sorted { $0.1 > $1.1 }
        for r in rows.prefix(8) {
            lines.append("  - \(r.0): \(format(r.1, code: target)) (\(r.2) 件)")
        }
        lines.append("")
    }

    /// 金額に種別記号を付けて返す。支出は `-`、収入は `+`。
    private static func signedAmount(value: Decimal, kind: TransactionKind, code: String) -> String {
        let sign = kind == .income ? "+" : "-"
        return sign + format(value, code: code)
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

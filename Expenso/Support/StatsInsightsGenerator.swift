//
//  StatsInsightsGenerator.swift
//  Expenso
//
//  StatsView の月次サマリから「気づき」(自然文の観察) を自動生成する。
//  Apple `FoundationModels` (iOS 26+) のオンデバイス LLM を使用。
//  端末で利用できない場合は `nil` を返し、UI 側でセクションを隠す。
//

import Foundation
import FoundationModels

/// 1 個の気づき。
@Generable
struct StatsInsight {
    @Guide(description: "気づきの見出し。20 文字以内、絵文字なし、句読点で終わらない。")
    var title: String

    @Guide(description: "見出しを 1〜2 文で具体的に説明する本文。必ず具体的な金額・カテゴリ名・日付などコンテキストの数値を引用すること。")
    var body: String

    @Guide(description: "気づきの種類。'positive' (節約・改善)、'warning' (注意・支出増)、'info' (中立な観察) のいずれか。")
    var severity: String
}

/// LLM の出力 (= 気づきの配列)。
@Generable
struct StatsInsightsOutput {
    @Guide(description: "気づきを 3〜5 個、重要度の高い順に並べる。重複・矛盾しないこと。")
    var insights: [StatsInsight]
}

/// 表示用に正規化した insight。`severity` を enum 化して UI に渡す。
struct ResolvedInsight: Identifiable {
    enum Severity {
        case positive, warning, info
    }
    let id = UUID()
    let title: String
    let body: String
    let severity: Severity
}

enum StatsInsightsGenerator {
    /// FoundationModels が利用可能か (Apple Intelligence 対応端末 + iOS 26+ で true)。
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// 統計サマリ context から 3〜5 個の気づきをストリーミング生成する。
    /// 部分応答が来るたびに `onUpdate` を呼んで、UI を逐次更新できるようにする。
    /// - Parameters:
    ///   - context: LLM に渡すサマリ
    ///   - onUpdate: 部分応答を受け取って UI を更新するクロージャ (MainActor で呼ばれる)
    /// - Returns: 最終リスト。利用不可・エラー時は `nil`。
    @MainActor
    static func generate(
        context: Context,
        onUpdate: @MainActor @escaping ([ResolvedInsight]) -> Void = { _ in }
    ) async -> [ResolvedInsight]? {
        guard isAvailable else { return nil }

        let instructions = """
        あなたは家計簿アプリのインサイトアシスタントです。
        ユーザーの月次支出/収入サマリを受け取り、「気づき (= 観察)」を 3〜5 個、日本語で生成します。

        ルール:
        - 各気づきは具体的な金額・カテゴリ名・日付・前月比など、入力に含まれる数値を**引用**する。
        - 一般論や挨拶は書かない。「外食を控えましょう」のような提言ではなく、観察に徹する。
        - 重複・矛盾しないようにバリエーションを出す (例: カテゴリ・支払者・日別・前月比から多角的に)。
        - severity の判定 (種別が「支出」の場合):
          * positive: 支出が前月比で減少した / カテゴリ支出が削減された / 件数が減った など、ユーザーにとって嬉しい変化
          * warning: 支出が大きく増加した / 単日で突出した出費があった など、注意が必要な変化
          * info: 増減の方向が中立 / 全体観察 / 構成比など、良い悪いの判断が難しい事実
        - severity の判定 (種別が「収入」の場合):
          * positive: 収入が増加した
          * warning: 収入が大きく減少した
          * info: 中立的な事実
        - 「減少」「削減」「節約」「下回った」などの語が含まれ、それがユーザーにとって望ましい場合は必ず positive を選ぶこと。
        - title は 20 文字以内・絵文字なし・句読点で終わらない。
        - body は 1〜2 文・具体的な数値を含める。**強調したい数値や語句には Markdown の太字 (`**...**`) を使ってよい**。
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let stream = session.streamResponse(
                to: context.prompt,
                generating: StatsInsightsOutput.self
            )
            var lastResolved: [ResolvedInsight] = []
            for try await partial in stream {
                let snapshot = partial.content
                // PartiallyGenerated.insights は optional 配列、各要素のフィールドも optional
                let items = (snapshot.insights ?? []).compactMap { p -> ResolvedInsight? in
                    guard let title = p.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !title.isEmpty,
                          let body = p.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !body.isEmpty else { return nil }
                    let sev: ResolvedInsight.Severity
                    switch (p.severity ?? "info").lowercased() {
                    case "positive": sev = .positive
                    case "warning":  sev = .warning
                    default:         sev = .info
                    }
                    return ResolvedInsight(title: title, body: body, severity: sev)
                }
                lastResolved = items
                onUpdate(items)
            }
            return lastResolved
        } catch {
            #if DEBUG
            print("⚠️ StatsInsightsGenerator: failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Context construction

    /// LLM に渡すプレーンテキストの統計サマリ。
    /// View 側で StatsView の数値から組み立てる。
    struct Context {
        let monthLabel: String           // "2026年5月"
        let kindLabel: String            // "支出" / "収入"
        let currencyCode: String         // "JPY"
        let totalAmount: Decimal
        let totalCount: Int
        let previousMonthTotal: Decimal
        let previousMonthCount: Int
        let categoryRows: [CategoryRow]  // 全カテゴリ
        let payerRows: [PayerRow]        // 全支払者
        let topDays: [DayRow]            // 上位 3 日

        struct CategoryRow {
            let name: String
            let amount: Decimal
            let count: Int
            let prevAmount: Decimal?
        }
        struct PayerRow {
            let name: String
            let amount: Decimal
            let count: Int
        }
        struct DayRow {
            let dateLabel: String   // "2026/05/03"
            let amount: Decimal
            let count: Int
        }

        var diffPercent: Double? {
            let prev = NSDecimalNumber(decimal: previousMonthTotal).doubleValue
            guard prev > 0 else { return nil }
            let cur = NSDecimalNumber(decimal: totalAmount).doubleValue
            return ((cur - prev) / prev) * 100
        }

        /// LLM に渡すプロンプト本文。読み取り易さ重視で markdown 風に整形。
        var prompt: String {
            var lines: [String] = []
            lines.append("月: \(monthLabel)")
            lines.append("種別: \(kindLabel)")
            lines.append("通貨: \(currencyCode)")
            lines.append("今月合計: \(format(totalAmount)) (\(totalCount) 件)")
            lines.append("前月合計: \(format(previousMonthTotal)) (\(previousMonthCount) 件)")
            if let pct = diffPercent {
                let sign = pct >= 0 ? "+" : ""
                lines.append("前月比: \(sign)\(String(format: "%.1f", pct))%")
            } else {
                lines.append("前月比: (前月データなし)")
            }
            lines.append("")

            lines.append("カテゴリ別 (上位):")
            if categoryRows.isEmpty {
                lines.append("  (データなし)")
            } else {
                for c in categoryRows.prefix(8) {
                    var row = "  - \(c.name): \(format(c.amount)) (\(c.count) 件)"
                    if let prev = c.prevAmount, prev > 0 {
                        let cur = NSDecimalNumber(decimal: c.amount).doubleValue
                        let prevD = NSDecimalNumber(decimal: prev).doubleValue
                        let pct = ((cur - prevD) / prevD) * 100
                        let sign = pct >= 0 ? "+" : ""
                        row += " — 前月 \(format(prev)) (\(sign)\(String(format: "%.1f", pct))%)"
                    } else if c.prevAmount != nil {
                        row += " — 前月なし"
                    }
                    lines.append(row)
                }
            }
            lines.append("")

            if !payerRows.isEmpty {
                lines.append("支払者別 (上位):")
                for p in payerRows.prefix(5) {
                    lines.append("  - \(p.name): \(format(p.amount)) (\(p.count) 件)")
                }
                lines.append("")
            }

            if !topDays.isEmpty {
                lines.append("最も金額が多かった日 (上位):")
                for d in topDays.prefix(3) {
                    lines.append("  - \(d.dateLabel): \(format(d.amount)) (\(d.count) 件)")
                }
            }
            return lines.joined(separator: "\n")
        }

        private func format(_ value: Decimal) -> String {
            CurrencyCatalog.format(value, code: currencyCode)
        }
    }
}

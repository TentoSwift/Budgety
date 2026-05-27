//
//  QuickBudgetIntent.swift
//  Budgety
//
//  「追加」「取得」を 1 つの AppIntent で兼ねる統合インテント。
//  JSON ペイロードの `op` フィールドで分岐する:
//    {"op":"add", "amount":500, "title":"ランチ"}                ← 追加
//    {"op":"get", "period":"thisMonth"}                          ← 取得
//
//  op 省略時は "add" を既定とする (= 既存 add 互換)。
//

import AppIntents
import Foundation

struct QuickBudgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Budgety MCP"
    static let description = IntentDescription(
        "支出/収入の追加・取得、定期項目の追加を 1 つの JSON 入力で行います。op='add' / 'get' / 'recurring'。MCP / 自動化向け。"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "入力 (JSON)",
               description: "op='add' または 'get'。例: {\"op\":\"add\",\"amount\":500,\"title\":\"ランチ\"}")
    var payload: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$payload) を実行")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Intent 実行前に Premium entitlements を最新化。
        // refreshEntitlements は UserDefaults を即時更新するので、以後
        // isPremiumCached が正しい値を返す。
        await PurchaseManager.shared.refreshEntitlements()

        let parsed = QuickIntentLogic.parseJSON(payload)
        let op = ((parsed["op"] as? String) ?? "add").lowercased()

        let result: [String: Any]
        switch op {
        case "get":
            result = QuickIntentLogic.get(parsed: parsed)
        case "add":
            result = await QuickIntentLogic.add(parsed: parsed)
        case "recurring":
            result = await QuickIntentLogic.addRecurring(parsed: parsed)
        case "members":
            result = QuickIntentLogic.members(parsed: parsed)
        default:
            result = ["ok": false, "error": "unknown op '\(op)'. Use 'add', 'get', 'recurring', or 'members'."]
        }
        return .result(value: QuickIntentLogic.encodeJSON(result))
    }
}

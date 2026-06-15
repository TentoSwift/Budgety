//
//  MCPServer.swift
//  Budgety For macOS
//
//  アプリ本体に内蔵した MCP (Model Context Protocol) サーバー。
//  `Budgety --mcp` で起動すると GUI を出さず、stdin/stdout 上で JSON-RPC 2.0 を話す
//  stdio トランスポートの MCP サーバーとして動作する (外部 npm パッケージ不要)。
//
//  App Store Guideline 2.4.5(ii): 外部 MCP サーバーを共有場所にインストールさせるのは不可。
//  本方式は「審査済みのアプリ本体バイナリ自身が MCP サーバー」なので追加コードの
//  インストールを伴わない。登録は `--mcp-install` が `claude mcp add ...` コマンドを
//  stdout に出力し、ユーザーのシェル側で実行する (サンドボックスは外部書き込み不可のため)。
//
//  ツールの実体は iOS/MCP と共有の `QuickIntentLogic` (add/get) に委譲する。
//

import Foundation
import CoreData
import AppKit

enum MCPServer {
    static let serverName = "budgety"
    static let serverVersion = "1.0"
    static let defaultProtocolVersion = "2024-11-05"

    // MARK: - エントリ (--mcp)

    /// `--mcp` で呼ばれる。GUI は起動せず stdio で JSON-RPC を処理し続ける。戻らない。
    /// Core Data (CloudKit) スタックは**遅延初期化**: 起動時には触らず、最初のツール呼び出し
    /// (add/get) で `PersistenceController.shared` 経由で読み込む。これにより initialize /
    /// tools/list は CloudKit 無しでも応答でき、データ操作時のみストアを開く。
    static func run() -> Never {
        // .app バンドルのバイナリを直接起動すると macOS は「GUI アプリ起動」として扱い、Dock に
        // 2 つ目の Budgety が出る / この --mcp プロセスは通常の AppKit イベントループを回さないため
        // 「応答なし」になる。バックグラウンドエージェント化 (.prohibited) して Dock/UI に出さない。
        NSApplication.shared.setActivationPolicy(.prohibited)
        log("Budgety MCP server starting…")
        // 読み取りループは別スレッド (readLine がブロックするため)。main スレッドは RunLoop を
        // 回して @MainActor (= main スレッド) のツール実行を処理させる。
        Thread.detachNewThread {
            serveLoop()
            exit(0)   // stdin が閉じた = クライアント終了
        }
        RunLoop.main.run()
        exit(0)   // 到達しない
    }

    /// `--mcp-install`: Claude Code への登録コマンドを stdout に出力する。
    /// (アプリはサンドボックスで設定ファイルに書けないので、シェル側で実行してもらう)
    static func printInstallCommand() {
        let path = Bundle.main.executablePath
            ?? "/Applications/Budgety.app/Contents/MacOS/Budgety"
        print("claude mcp add budgety -- \"\(path)\" --mcp")
    }

    // MARK: - stdin ループ

    private static func serveLoop() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            handleLine(trimmed)
        }
    }

    private static func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(errorCode: -32700, message: "Parse error", id: nil)
            return
        }
        let method = obj["method"] as? String
        let id = obj["id"]                       // Int/String/nil。nil = notification
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? defaultProtocolVersion
            send(result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": serverVersion]
            ], id: id)
        case "notifications/initialized", "initialized", "notifications/cancelled":
            break   // 通知なので応答しない
        case "ping":
            send(result: [String: Any](), id: id)
        case "tools/list":
            send(result: ["tools": toolDefinitions()], id: id)
        case "tools/call":
            handleToolCall(params: params, id: id)
        default:
            if id != nil {
                send(errorCode: -32601, message: "Method not found: \(method ?? "")", id: id)
            }
        }
    }

    // MARK: - tools

    private static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "add_expense",
                "description": "Record an expense or income entry in Budgety. kind defaults to 'expense'; pass 'income' for salary, refunds, etc. To categorize, call list_categories first to see the sheet's categories, then pass the chosen one via `category`. If `category` is omitted, the app falls back to the user's past classification of the same title (no on-device AI guessing).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "amount": ["type": "number", "description": "Amount (plain number, no currency symbol)."],
                        "title": ["type": "string", "description": "Short label (店名・品目)."],
                        "category": ["type": "string", "description": "Category name for this entry. Use list_categories to get valid names for the sheet/kind. Must match an existing category name; otherwise it is ignored. Omit to let the app infer from past history."],
                        "kind": ["type": "string", "enum": ["expense", "income"], "description": "expense (default) or income."],
                        "sheet": ["type": "string", "description": "Sheet name. Optional, defaults to the oldest sheet."],
                        "currency": ["type": "string", "description": "ISO 4217 code. Optional, defaults to sheet currency."],
                        "date": ["type": "string", "description": "ISO8601 date-time. Optional, defaults to now. Future dates rejected."],
                        "password": ["type": "string", "description": "Sheet password if the sheet is locked."]
                    ],
                    "required": ["amount", "title"]
                ]
            ],
            [
                "name": "list_categories",
                "description": "List a sheet's categories (valid names for add_expense's `category`). Call this before add_expense to choose the right category yourself instead of relying on auto-classification.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "sheet": ["type": "string", "description": "Sheet name. Optional, defaults to the oldest sheet."],
                        "kind": ["type": "string", "enum": ["expense", "income"], "description": "Filter by kind. Optional (default both)."]
                    ]
                ]
            ],
            [
                "name": "get_expenses",
                "description": "Get expense / income records for a period from Budgety.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "period": ["type": "string", "enum": ["today", "yesterday", "thisWeek", "thisMonth", "lastMonth", "thisYear", "last30Days", "allTime"], "description": "Time window. Default thisMonth."],
                        "sheet": ["type": "string", "description": "Filter by sheet name. Optional."],
                        "kind": ["type": "string", "enum": ["expense", "income"], "description": "Filter by kind. Optional (default both)."],
                        "from": ["type": "string", "description": "Custom range start (ISO8601). Use with 'to'."],
                        "to": ["type": "string", "description": "Custom range end (ISO8601)."],
                        "password": ["type": "string", "description": "Sheet password if locked."]
                    ]
                ]
            ]
        ]
    }

    private static func handleToolCall(params: [String: Any], id: Any?) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        let resultDict: [String: Any]
        switch name {
        case "add_expense":
            resultDict = callOnMainActorAsync { await QuickIntentLogic.add(parsed: args) }
        case "get_expenses":
            resultDict = callOnMainActorSync { QuickIntentLogic.get(parsed: args) }
        case "list_categories":
            resultDict = callOnMainActorSync { QuickIntentLogic.categories(parsed: args) }
        default:
            send(errorCode: -32602, message: "Unknown tool: \(name)", id: id)
            return
        }
        let ok = resultDict["ok"] as? Bool ?? true
        let text = QuickIntentLogic.encodeJSON(resultDict)
        send(result: [
            "content": [["type": "text", "text": text]],
            "isError": !ok
        ], id: id)
    }

    // MARK: - MainActor ブリッジ (読み取りループは別スレッドなので semaphore で橋渡し)

    private static func callOnMainActorAsync(_ work: @escaping () async -> [String: Any]) -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]
        Task { @MainActor in
            out = await work()
            sem.signal()
        }
        sem.wait()
        return out
    }

    private static func callOnMainActorSync(_ work: @escaping @MainActor () -> [String: Any]) -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]
        Task { @MainActor in
            out = work()
            sem.signal()
        }
        sem.wait()
        return out
    }

    // MARK: - JSON-RPC 出力

    private static func send(result: [String: Any], id: Any?) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func send(errorCode: Int, message: String, id: Any?) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(),
               "error": ["code": errorCode, "message": message]])
    }

    private static func write(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: []) else { return }
        let out = FileHandle.standardOutput
        out.write(data)
        out.write(Data([0x0a]))   // newline 区切り (stdio トランスポート)
    }

    private static func log(_ s: String) {
        // ログは stderr へ (stdout は JSON-RPC 専用)
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

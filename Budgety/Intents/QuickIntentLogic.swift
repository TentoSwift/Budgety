//
//  QuickIntentLogic.swift
//  Budgety
//
//  Quick{Add,Get,Budget}Intent から呼ばれる共通ロジック。
//  どの AppIntent でも `[String: Any]` (= JSON パース結果) → `[String: Any]`
//  (= JSON 化される結果) という同じ I/F で実行する。
//

import CoreData
import Foundation

enum QuickIntentLogic {

    // MARK: - Add (支出 / 収入の追加)

    @MainActor
    static func add(parsed: [String: Any]) async -> [String: Any] {
        // amount: Double / Int / String
        let amount: Double = {
            if let v = parsed["amount"] as? Double { return v }
            if let v = parsed["amount"] as? Int    { return Double(v) }
            if let s = parsed["amount"] as? String, let v = Double(s) { return v }
            return -1
        }()
        guard amount > 0 else {
            return ["ok": false, "error": "amount required (positive number)"]
        }

        let title = (parsed["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            return ["ok": false, "error": "title required"]
        }

        // kind: "expense" (既定) / "income"
        let kind: TransactionKind = {
            if (parsed["kind"] as? String)?.lowercased() == "income" { return .income }
            return .expense
        }()

        // date: ISO8601 / epoch
        let date: Date = {
            if let iso = parsed["date"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: iso) { return d }
                f.formatOptions = [.withInternetDateTime]
                if let d = f.date(from: iso) { return d }
            }
            if let epoch = parsed["date"] as? Double { return Date(timeIntervalSince1970: epoch) }
            if let epoch = parsed["date"] as? Int    { return Date(timeIntervalSince1970: TimeInterval(epoch)) }
            return .now
        }()

        // 未来日付の拒否: AppIntent の意図は「実際に発生した支出/収入の記録」なので、
        // 現在時刻より未来の date はエラーで弾く。タイムゾーン差を考慮して 5 分の猶予あり。
        let nowWithBuffer = Date().addingTimeInterval(5 * 60)
        if date > nowWithBuffer {
            let isoNow = ISO8601DateFormatter().string(from: Date())
            let isoDate = ISO8601DateFormatter().string(from: date)
            return [
                "ok": false,
                "error": "future date not allowed. now=\(isoNow), requested=\(isoDate). Use a past or current date."
            ]
        }

        let sheetName = parsed["sheet"] as? String

        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext

        // シート決定 (= 最古シート優先、同名衝突は warning)
        var nameCollisionCount: Int = 0
        let sheet: ExpenseSheet
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        sheetReq.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)]
        if let name = sheetName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            sheetReq.predicate = NSPredicate(format: "name == %@", name)
            let matches = (try? ctx.fetch(sheetReq)) ?? []
            if let first = matches.first {
                sheet = first
                if matches.count > 1 { nameCollisionCount = matches.count }
            } else {
                sheetReq.predicate = nil
                sheetReq.fetchLimit = 1
                guard let fallback = (try? ctx.fetch(sheetReq))?.first else {
                    return ["ok": false, "error": "no sheet found"]
                }
                sheet = fallback
            }
        } else {
            sheetReq.fetchLimit = 1
            guard let first = (try? ctx.fetch(sheetReq))?.first else {
                return ["ok": false, "error": "no sheet found"]
            }
            sheet = first
        }

        // Premium 制限: 自分がオーナーのシートへの MCP 経由追加は Premium 必須。
        // 共有シート (= 他人がオーナーで Premium 提供してくれている) は無料で追加可能。
        // Intent では同期で isPremiumCached (UserDefaults) を使う。
        // .isPremium (instance) は StoreKit refresh 完了前は false 固定なので不可。
        if !PurchaseManager.isPremiumCached && sheet.isOwnedByCurrentUser {
            return [
                "ok": false,
                "error": "Premium 限定機能です。自分がオーナーのシート「\(sheet.displayName)」への MCP 経由の追加には Budgety Premium が必要です。他の Premium ユーザーが共有してくれているシートには無料で追加できます。",
                "sheet": sheet.displayName,
                "premiumRequired": true
            ]
        }

        // パスワードロック判定
        let lock = SheetLockManager.shared
        if lock.hasPassword(for: sheet) {
            let provided = (parsed["password"] as? String) ?? ""
            if provided.isEmpty {
                return [
                    "ok": false,
                    "error": "sheet \"\(sheet.displayName)\" is locked. Provide `password` to add.",
                    "sheet": sheet.displayName,
                    "locked": true
                ]
            }
            if !lock.unlock(sheet, withPassword: provided) {
                return [
                    "ok": false,
                    "error": "incorrect password for sheet \"\(sheet.displayName)\".",
                    "sheet": sheet.displayName,
                    "locked": true
                ]
            }
        }

        // カテゴリ決定 (= kind に応じて AI 提案 / 最初の同 kind カテゴリ)
        let allKindCats = ((sheet.categories as? Set<ExpenseCategory>) ?? [])
            .filter { $0.kind == kind }
            .sorted { $0.sortOrder < $1.sortOrder }
        var aiSuggested: ExpenseCategory? = nil
        if CategoryAISuggestor.isAvailable {
            let names = allKindCats.map { $0.displayName }
            if !names.isEmpty,
               let suggestedName = await CategoryAISuggestor.suggest(
                title: title,
                kind: kind,
                categories: names
               ) {
                aiSuggested = allKindCats.first(where: { $0.displayName == suggestedName })
            }
        }
        let firstCategory = aiSuggested ?? allKindCats.first

        // 永続化
        let expense = Expense(context: ctx)
        if let store = sheet.objectID.persistentStore {
            ctx.assign(expense, to: store)
        }
        expense.amount = NSDecimalNumber(value: amount)
        // 通貨指定 (任意): ISO 4217 (大文字3文字)。CurrencyCatalog 内に存在すれば採用、
        // それ以外 (= 未指定 or 未対応コード) は sheet のデフォルト通貨にフォールバック。
        expense.currencyCode = {
            if let raw = (parsed["currency"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
               !raw.isEmpty,
               CurrencyCatalog.all.contains(where: { $0.code == raw }) {
                return raw
            }
            return sheet.resolvedDefaultCurrencyCode
        }()
        expense.kindRaw = kind.rawValue
        expense.date = date
        expense.title = title
        expense.note = ""
        expense.createdAt = .now
        expense.sheet = sheet
        expense.category = firstCategory

        let profile = UserProfileStore.shared
        let share = ShareCoordinator.shared.existingShare(for: sheet)

        // 支払者 (payer): 名前指定があれば解決、無ければ自分。
        // "self" / "自分" は明示的に自分を表す。
        let selfPID = profile.canonicalSelfID(forShare: share) ?? ""
        let payerInput = (parsed["payer"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var resolvedPayerID: String = selfPID
        if !payerInput.isEmpty {
            if payerInput.lowercased() == "self" || payerInput == "自分" {
                resolvedPayerID = selfPID
            } else if let mid = Self.resolveMemberID(name: payerInput, in: sheet, selfPID: selfPID) {
                resolvedPayerID = mid
            }
        }
        if !resolvedPayerID.isEmpty {
            expense.payerProfileID = resolvedPayerID
        }
        // 受益者 (beneficiaries): 名前配列 / 単一文字列 / "all" を許容。
        // 未指定なら空のままで「割り勘オフ (= 支払者単独負担)」扱い。
        // 指定されたが解決後 0 人 (例: 存在しない名前のみ / 空配列) はエラーで弾く。
        var beneficiaryIDs: [String] = []
        var beneficiariesProvided: Bool = false
        let benInput = parsed["beneficiaries"]
        if let arr = benInput as? [String] {
            beneficiariesProvided = true
            beneficiaryIDs = Self.resolveBeneficiaries(names: arr, in: sheet, selfPID: selfPID)
        } else if let str = benInput as? String {
            beneficiariesProvided = true
            if str.lowercased() == "all" || str == "全員" {
                beneficiaryIDs = sheet.allMemberProfileIDs()
            } else if !str.isEmpty {
                // CSV 形式も受ける ("Emma, Liam, Sofia")
                let parts = str.split(separator: ",").map { String($0) }
                beneficiaryIDs = Self.resolveBeneficiaries(names: parts, in: sheet, selfPID: selfPID)
            }
        }
        if beneficiariesProvided && beneficiaryIDs.isEmpty {
            ctx.delete(expense)
            return [
                "ok": false,
                "error": "beneficiaries was specified but resolved to 0 members. Select at least one valid sheet member, or omit beneficiaries to record as the payer's sole burden."
            ]
        }
        if !beneficiaryIDs.isEmpty {
            expense.beneficiaryProfileIDs = beneficiaryIDs.joined(separator: ",")
        }
        // payerMemberID は自分が支払者の時のみセット (denormalized キャッシュ)。
        if resolvedPayerID == selfPID, let memberID = profile.selfMemberID {
            expense.payerMemberID = memberID
        }

        // FX スナップショット (MCP / Shortcuts 経由でも current FX を凍結)
        expense.captureFXSnapshot()

        do {
            try ctx.save()
        } catch {
            return ["ok": false, "error": "save failed: \(error.localizedDescription)"]
        }

        var summary: [String: Any] = [
            "ok": true,
            "amount": amount,
            "currency": expense.currencyCode ?? "",
            "title": title,
            "sheet": sheet.displayName,
            "kind": kind == .income ? "income" : "expense",
            "category": firstCategory?.name ?? ""
        ]
        // 割り勘設定したものは確認のためレスポンスに名前を入れる
        if !payerInput.isEmpty, resolvedPayerID != selfPID {
            summary["payer"] = sheet.memberDisplayInfo(for: resolvedPayerID).name
        }
        if !beneficiaryIDs.isEmpty {
            summary["beneficiaries"] = beneficiaryIDs.map { sheet.memberDisplayInfo(for: $0).name }
        }
        if nameCollisionCount > 1 {
            summary["warning"] = "name_collision: \(nameCollisionCount) sheets named \"\(sheet.displayName)\". Using oldest by createdAt."
        }
        return summary
    }

    /// 名前 (displayName) から sheet 内のメンバー profileID を解決する。
    /// "self" / "自分" は selfPID にマップ。完全一致 (大小無視) で探す。
    @MainActor
    private static func resolveMemberID(name: String, in sheet: ExpenseSheet, selfPID: String) -> String? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { return nil }
        if target.lowercased() == "self" || target == "自分" {
            return selfPID.isEmpty ? nil : selfPID
        }
        let lowered = target.lowercased()
        for id in sheet.allMemberProfileIDs() {
            let info = sheet.memberDisplayInfo(for: id)
            if info.name.lowercased() == lowered { return id }
        }
        return nil
    }

    /// 名前の配列を beneficiaries profileID 配列に解決する。重複は dedup。
    /// 解決できなかった名前は無視 (= 部分的な指定でも保存は通す)。
    @MainActor
    private static func resolveBeneficiaries(names: [String], in sheet: ExpenseSheet, selfPID: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for rawName in names {
            let n = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.lowercased() == "all" || n == "全員" {
                for id in sheet.allMemberProfileIDs() where seen.insert(id).inserted {
                    ids.append(id)
                }
                continue
            }
            if let id = resolveMemberID(name: n, in: sheet, selfPID: selfPID),
               seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    // MARK: - Get (支出 / 収入の取得)

    @MainActor
    static func get(parsed: [String: Any]) -> [String: Any] {
        let dateRange: (start: Date, end: Date) = {
            if let fromStr = parsed["from"] as? String,
               let toStr   = parsed["to"]   as? String,
               let from    = parseISO(fromStr),
               let to      = parseISO(toStr) {
                return (from, to)
            }
            let periodStr = (parsed["period"] as? String) ?? "thisMonth"
            let option = PeriodOption(rawValue: periodStr) ?? .thisMonth
            return option.dateRange()
        }()

        let ctx = PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<Expense>(entityName: "Expense")
        var predicates: [NSPredicate] = [
            NSPredicate(format: "date >= %@ AND date <= %@",
                        dateRange.start as NSDate,
                        dateRange.end   as NSDate),
            NSPredicate(format: "sheet != nil")
        ]
        if let sheetName = (parsed["sheet"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sheetName.isEmpty {
            predicates.append(NSPredicate(format: "sheet.name == %@", sheetName))
        }
        if let kindStr = (parsed["kind"] as? String)?.lowercased(),
           ["expense", "income"].contains(kindStr) {
            let raw = (kindStr == "income"
                       ? TransactionKind.income
                       : TransactionKind.expense).rawValue
            predicates.append(NSPredicate(format: "kindRaw == %@", raw))
        }
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \Expense.date, ascending: true)]

        let allExpenses = (try? ctx.fetch(req)) ?? []

        // Premium 制限 + ロックの扱い:
        // - 非 Premium + 自分がオーナーのシート → 除外 (Premium 必須)
        // - 共有シート (他人がオーナー) → 無料で取得可能
        // - ロック済シート → password 一致なら通す、それ以外は除外
        let lock = SheetLockManager.shared
        let isPremium = PurchaseManager.isPremiumCached
        let providedPassword = (parsed["password"] as? String) ?? ""
        var omittedPremiumCount = 0
        var omittedLockedCount = 0
        let expenses = allExpenses.filter { e in
            guard let s = e.sheet else { return false }
            // Premium 制限
            if !isPremium && s.isOwnedByCurrentUser {
                omittedPremiumCount += 1
                return false
            }
            // ロック
            if lock.hasPassword(for: s) {
                if providedPassword.isEmpty || !lock.unlock(s, withPassword: providedPassword) {
                    omittedLockedCount += 1
                    return false
                }
            }
            return true
        }

        let payloadOut: [[String: Any]] = expenses.map { e in
            // 支払者 / 受益者の名前を解決 (空 = 未指定)。
            let payerName: String = {
                guard let s = e.sheet, let pid = e.payerProfileID, !pid.isEmpty else { return "" }
                return s.memberDisplayInfo(for: pid).name
            }()
            let beneficiaryNames: [String] = {
                guard let s = e.sheet else { return [] }
                return e.beneficiaryIDList.map { s.memberDisplayInfo(for: $0).name }
            }()
            return [
                "date": ISO8601DateFormatter().string(from: e.date ?? Date()),
                "title": e.displayTitle,
                "amount": NSDecimalNumber(decimal: e.amountDecimal).doubleValue,
                "currency": e.resolvedCurrencyCode,
                "kind": e.kind == .income ? "income" : "expense",
                "category": e.category?.name ?? "",
                "categoryColor": e.category?.colorHex ?? "",
                "sheet": e.sheet?.name ?? "",
                "paidBy": e.displayPaidBy,
                // 支払者名 (sheet 内 memberDisplayInfo 経由)。
                // payerProfileID が空 (= 未設定) の時は "" 。
                "payer": payerName,
                // 割り勘の受益者名配列。空 (= 未設定 / 割り勘オフ) なら []。
                "beneficiaries": beneficiaryNames,
                "note": e.note ?? ""
            ]
        }

        let periodLabel: String = {
            if parsed["from"] != nil && parsed["to"] != nil { return "カスタム期間" }
            let periodStr = (parsed["period"] as? String) ?? "thisMonth"
            return PeriodOption(rawValue: periodStr)?.label ?? "今月"
        }()

        var result: [String: Any] = [
            "period": periodLabel,
            "from": ISO8601DateFormatter().string(from: dateRange.start),
            "to":   ISO8601DateFormatter().string(from: dateRange.end),
            "count": payloadOut.count,
            "expenses": payloadOut
        ]
        var warnings: [String] = []
        if omittedPremiumCount > 0 {
            result["premiumOmitted"] = omittedPremiumCount
            result["premiumRequired"] = true
            warnings.append("Omitted \(omittedPremiumCount) entries from sheets you own. MCP access to your own sheets requires Budgety Premium. Sheets shared by other Premium users are accessible for free.")
        }
        if omittedLockedCount > 0 {
            result["lockedOmitted"] = omittedLockedCount
            warnings.append("Omitted \(omittedLockedCount) entries from locked sheets. Provide `password` to include them.")
        }
        if !warnings.isEmpty {
            result["warning"] = warnings.joined(separator: " ")
        }
        return result
    }

    // MARK: - Members (シートのメンバー一覧)

    /// シートのメンバー一覧を返す。MCP add_expense の payer / beneficiaries
    /// 指定時に有効な名前を事前に取得するために使う。
    /// 入力: { "op": "members", "sheet": "京都旅行" }  (sheet 省略時は最古シート)
    /// 出力: { "ok": true, "sheet": "...", "members": [
    ///         { "name": "てん", "profileID": "...", "isSelf": true, "isVirtual": false }, ...
    ///       ] }
    @MainActor
    static func members(parsed: [String: Any]) -> [String: Any] {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext
        let sheetName = (parsed["sheet"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // シート決定 (add/get と同じく最古シートフォールバック)
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        sheetReq.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)]
        let sheet: ExpenseSheet
        if !sheetName.isEmpty {
            sheetReq.predicate = NSPredicate(format: "name == %@", sheetName)
            if let s = (try? ctx.fetch(sheetReq))?.first {
                sheet = s
            } else {
                sheetReq.predicate = nil
                sheetReq.fetchLimit = 1
                guard let fallback = (try? ctx.fetch(sheetReq))?.first else {
                    return ["ok": false, "error": "no sheet found"]
                }
                sheet = fallback
            }
        } else {
            sheetReq.fetchLimit = 1
            guard let s = (try? ctx.fetch(sheetReq))?.first else {
                return ["ok": false, "error": "no sheet found"]
            }
            sheet = s
        }

        let profile = UserProfileStore.shared
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        let selfIDs = profile.canonicalSelfIDs(forShare: share)

        var members: [[String: Any]] = []
        for pid in sheet.allMemberProfileIDs() {
            let info = sheet.memberDisplayInfo(for: pid)
            members.append([
                "name": info.name,
                "profileID": pid,
                "isSelf": selfIDs.contains(pid),
                "isVirtual": UserProfileStore.isVirtualRecordName(pid)
            ])
        }
        return [
            "ok": true,
            "sheet": sheet.displayName,
            "count": members.count,
            "members": members
        ]
    }

    // MARK: - Helpers

    static func parseJSON(_ s: String) -> [String: Any] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    static func encodeJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// 期間指定。JSON の `period` 文字列 (rawValue) から日付範囲を解決する。
/// (旧 GetExpensesIntent の AppEnum を、内部ロジック専用の素の enum に整理したもの)
enum PeriodOption: String {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case lastMonth
    case thisYear
    case last30Days
    case allTime

    var label: String {
        switch self {
        case .today:      "今日"
        case .yesterday:  "昨日"
        case .thisWeek:   "今週"
        case .thisMonth:  "今月"
        case .lastMonth:  "先月"
        case .thisYear:   "今年"
        case .last30Days: "直近 30 日"
        case .allTime:    "全期間"
        }
    }

    func dateRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:
            let s = cal.startOfDay(for: now)
            let e = cal.date(byAdding: .day, value: 1, to: s)!
            return (s, e)
        case .yesterday:
            let today = cal.startOfDay(for: now)
            let s = cal.date(byAdding: .day, value: -1, to: today)!
            return (s, today)
        case .thisWeek:
            let s = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (s, now)
        case .thisMonth:
            let s = cal.dateInterval(of: .month, for: now)?.start ?? now
            return (s, now)
        case .lastMonth:
            let thisMonthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
            let s = cal.date(byAdding: .month, value: -1, to: thisMonthStart)!
            return (s, thisMonthStart)
        case .thisYear:
            let s = cal.dateInterval(of: .year, for: now)?.start ?? now
            return (s, now)
        case .last30Days:
            let s = cal.date(byAdding: .day, value: -30, to: now)!
            return (s, now)
        case .allTime:
            return (Date.distantPast, Date.distantFuture)
        }
    }
}

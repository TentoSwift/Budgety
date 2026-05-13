//
//  QuickIntentLogic+Recurring.swift
//  Budgety
//
//  MCP / Shortcuts 経由で定期項目 (RecurringRule) を追加するためのロジック。
//  QuickBudgetIntent (= 「クイック家計簿」shortcut) の op="recurring" から呼ばれる。
//

import CoreData
import Foundation

extension QuickIntentLogic {

    @MainActor
    static func addRecurring(parsed: [String: Any]) async -> [String: Any] {
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

        let kind: TransactionKind = {
            if (parsed["kind"] as? String)?.lowercased() == "income" { return .income }
            return .expense
        }()

        let frequency: RecurrenceFrequency = {
            let raw = (parsed["frequency"] as? String)?.lowercased() ?? "monthly"
            return RecurrenceFrequency(rawValue: raw) ?? .monthly
        }()
        let interval: Int32 = {
            if let v = parsed["interval"] as? Int    { return max(1, Int32(v)) }
            if let v = parsed["interval"] as? Double { return max(1, Int32(v)) }
            if let s = parsed["interval"] as? String, let v = Int32(s) { return max(1, v) }
            return 1
        }()

        let startDate: Date = parseRecurringDate(parsed["startDate"]) ?? .now
        let endDate: Date? = parseRecurringDate(parsed["endDate"])
        if let endDate, endDate <= startDate {
            return ["ok": false, "error": "endDate must be after startDate"]
        }

        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext

        var nameCollisionCount = 0
        let sheet: ExpenseSheet
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        sheetReq.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)]
        if let name = (parsed["sheet"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
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

        // Premium 制限
        if !PurchaseManager.shared.isPremium && sheet.isOwnedByCurrentUser {
            return [
                "ok": false,
                "error": "Premium 限定機能です。自分がオーナーのシート「\(sheet.displayName)」への MCP 経由の定期項目追加には Budgety Premium が必要です。他の Premium ユーザーが共有してくれているシートには無料で追加できます。",
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
                    "error": "sheet \"\(sheet.displayName)\" is locked. Provide `password` to add a recurring rule.",
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

        // カテゴリ自動判定 (= 既存 add() と同じ AI 推測)
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

        let rule = RecurringRule(context: ctx)
        if let store = sheet.objectID.persistentStore {
            ctx.assign(rule, to: store)
        }
        rule.id = UUID()
        rule.amount = NSDecimalNumber(value: amount)
        rule.title = title
        rule.note = ""
        rule.kindRaw = kind.rawValue
        rule.frequency = frequency.rawValue
        rule.interval = interval
        rule.startDate = startDate
        rule.endDate = endDate
        rule.createdAt = .now
        rule.sheet = sheet

        rule.currencyCode = {
            if let raw = (parsed["currency"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
               !raw.isEmpty,
               CurrencyCatalog.all.contains(where: { $0.code == raw }) {
                return raw
            }
            return sheet.resolvedDefaultCurrencyCode
        }()

        if let cat = firstCategory {
            rule.categoryRaw = cat.name ?? ""
        }

        let profile = UserProfileStore.shared
        if let rn = profile.userRecordName, !rn.isEmpty {
            rule.payerProfileID = rn
            rule.paidBy = profile.resolvedDisplayName
        }

        do {
            try ctx.save()
        } catch {
            return ["ok": false, "error": "save failed: \(error.localizedDescription)"]
        }

        // 即座に最初の occurrence を Expense として展開
        RecurringExpenseGenerator.generateAll(in: ctx)

        var summary: [String: Any] = [
            "ok": true,
            "amount": amount,
            "title": title,
            "sheet": sheet.displayName,
            "kind": kind == .income ? "income" : "expense",
            "frequency": frequency.rawValue,
            "interval": Int(interval),
            "category": firstCategory?.name ?? "",
            "startDate": ISO8601DateFormatter().string(from: startDate)
        ]
        if let endDate {
            summary["endDate"] = ISO8601DateFormatter().string(from: endDate)
        }
        if nameCollisionCount > 1 {
            summary["warning"] = "name_collision: \(nameCollisionCount) sheets named \"\(sheet.displayName)\". Using oldest by createdAt."
        }
        return summary
    }

    /// ISO8601 / epoch のいずれかを Date にパース。失敗時は nil。
    private static func parseRecurringDate(_ raw: Any?) -> Date? {
        if let iso = raw as? String {
            let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: trimmed) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: trimmed)
        }
        if let epoch = raw as? Double { return Date(timeIntervalSince1970: epoch) }
        if let epoch = raw as? Int    { return Date(timeIntervalSince1970: TimeInterval(epoch)) }
        return nil
    }
}

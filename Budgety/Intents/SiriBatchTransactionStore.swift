import CoreData
import Foundation

@MainActor
enum SiriBatchTransactionStore {
    struct Entry {
        let title: String
        let amount: Decimal
        let kind: TransactionKind
        var currencyCode: String? = nil
        var date: Date = .now
    }

    struct Edit {
        let identifier: String
        var title: String? = nil
        var amount: Decimal? = nil
        var currencyCode: String? = nil
        var date: Date? = nil
        var categoryID: String? = nil
    }

    enum BatchError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
        case empty, duplicate, invalidRow, invalidCategory, unchanged, stale

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .empty: "明細を選ぶか、追加する明細を入力してください。"
            case .duplicate: "同じ明細が複数回指定されています。"
            case .invalidRow: "「ランチ 1,200円」のように、明細ごとに名前と金額を入力してください。"
            case .invalidCategory: "対象のシートと収支の種類に合うカテゴリを選んでください。"
            case .unchanged: "変更する項目がありません。"
            case .stale: "確認した内容が変わりました。明細を確認し直してください。"
            }
        }
        var errorDescription: String? { String(localized: localizedStringResource) }
    }

    fileprivate struct Snapshot: Equatable {
        let values: NSDictionary
        let categoryID: NSManagedObjectID?
        init(_ row: Expense) {
            values = row.committedValues(forKeys: Array(row.entity.attributesByName.keys)) as NSDictionary
            categoryID = row.category?.objectID
        }
    }

    fileprivate enum Operation {
        case add([Entry])
        case edit([Edit], [Snapshot])
    }

    // A prepared operation can be submitted twice by UI actions. Both submissions share
    // the same receipt, and a failed save leaves it retryable.
    final class Prepared {
        let summary: String
        let count: Int
        fileprivate let sheetID: String
        fileprivate let sheetName: String
        fileprivate let sheetCurrency: String
        fileprivate let operation: Operation
        fileprivate var savedIDs: [String]?

        fileprivate init(sheet: ExpenseSheet, operation: Operation, lines: [String]) {
            sheetID = sheet.objectID.uriRepresentation().absoluteString
            sheetName = sheet.displayName
            sheetCurrency = sheet.resolvedDefaultCurrencyCode
            self.operation = operation
            count = lines.count
            summary = ([sheet.displayName] + lines).joined(separator: "\n")
        }
    }

    static func prepareAdd(sheetID: String, entries: [Entry]) throws -> Prepared {
        guard !entries.isEmpty else { throw BatchError.empty }
        let (access, sheet) = try writableSheet(sheetID)
        let normalized = try entries.map { entry in
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw AppIntentError.emptyTitle }
            guard entry.amount > 0, !entry.amount.isNaN else { throw AppIntentError.invalidAmount }
            let currency = try currency(entry.currencyCode ?? sheet.resolvedDefaultCurrencyCode)
            return Entry(title: title, amount: entry.amount, kind: entry.kind, currencyCode: currency, date: entry.date)
        }
        let prepared = Prepared(sheet: sheet, operation: .add(normalized), lines: normalized.map { entry in
            "\(entry.kind.label)　\(entry.title)　\(entry.amount) \(entry.currencyCode ?? sheet.resolvedDefaultCurrencyCode)　\(entry.date.formatted(date: .abbreviated, time: .shortened))"
        })
        withExtendedLifetime(access) {}
        return prepared
    }

    static func prepareEdit(sheetID: String, edits: [Edit]) throws -> Prepared {
        guard !edits.isEmpty else { throw BatchError.empty }
        guard Set(edits.map(\.identifier)).count == edits.count else { throw BatchError.duplicate }
        let (access, sheet) = try writableSheet(sheetID)
        let rows = try edits.map { try target($0.identifier, in: sheet, access: access) }
        let snapshots = rows.map(Snapshot.init)
        let lines = try zip(edits, rows).compactMap { try apply($0, to: $1, in: sheet, access: access) }
        guard !lines.isEmpty else { throw BatchError.unchanged }
        // The unparented context only contains the preview. Saving requires a fresh
        // access check, even if the caller immediately confirms.
        return Prepared(sheet: sheet, operation: .edit(edits, snapshots), lines: lines)
    }

    @discardableResult
    static func commit(_ prepared: Prepared) throws -> [String] {
        if let saved = prepared.savedIDs { return saved }
        let (access, sheet) = try writableSheet(prepared.sheetID)
        guard sheet.displayName == prepared.sheetName, sheet.resolvedDefaultCurrencyCode == prepared.sheetCurrency
        else { throw BatchError.stale }
        var changed: [Expense] = []
        switch prepared.operation {
        case .add(let entries):
            for entry in entries {
                let category = CategoryHistorySuggestor.suggest(title: entry.title, kind: entry.kind, in: sheet)
                let row = try AddExpenseIntent.insertTransaction(in: sheet, access: access, kind: entry.kind,
                    title: entry.title, amount: entry.amount, currencyCode: entry.currencyCode ?? prepared.sheetCurrency,
                    date: entry.date, category: category)
                changed.append(row)
            }
        case .edit(let edits, let snapshots):
            var lines = [sheet.displayName]
            for (edit, snapshot) in zip(edits, snapshots) {
                let row = try target(edit.identifier, in: sheet, access: access)
                guard Snapshot(row) == snapshot else { throw BatchError.stale }
                if let line = try apply(edit, to: row, in: sheet, access: access) {
                    lines.append(line)
                    changed.append(row)
                }
            }
            guard lines.joined(separator: "\n") == prepared.summary else { throw BatchError.stale }
        }
        try Task.checkCancellation()
        try access.context.save()
        let ids = changed.map { $0.objectID.uriRepresentation().absoluteString }
        prepared.savedIDs = ids
        return ids
    }

    private static func writableSheet(_ id: String) throws -> (IntentSheetAccess, ExpenseSheet) {
        let container = PersistenceController.shared.container
        let access = try IntentSheetAccess(checking: container.viewContext)
        let sheet = try access.resolve(id)
        guard container.canUpdateRecord(forManagedObjectWith: sheet.objectID) else { throw AppIntentError.sheetNotFound }
        return (access, sheet)
    }

    private static func target(_ id: String, in sheet: ExpenseSheet, access: IntentSheetAccess) throws -> Expense {
        let live = try access.transactionForDisplay(identifier: id)
        guard !live.hasPersistentChangedValues,
              let row = try access.context.existingObject(with: live.objectID) as? Expense,
              row.sheet?.objectID == sheet.objectID,
              PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: row.objectID)
        else { throw BatchError.stale }
        return row
    }

    private static func currency(_ raw: String) throws -> String {
        guard let code = CurrencyCatalog.transactionCurrencyCode(for: raw) else { throw AppIntentError.unsupportedCurrency }
        return code
    }

    private static func apply(_ edit: Edit, to row: Expense, in sheet: ExpenseSheet, access: IntentSheetAccess) throws -> String? {
        let originalName = row.displayTitle.isEmpty ? row.categoryDisplayName : row.displayTitle
        let originalDate = row.date?.formatted(date: .abbreviated, time: .shortened) ?? ""
        let originalAmount = "\(row.amountDecimal) \(row.resolvedCurrencyCode)"
        var changes: [String] = []
        if let raw = edit.title {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if row.displayTitle != title {
                changes.append(String(localized: "名前：\(originalName) → \(title.isEmpty ? String(localized: "未設定") : title)"))
                row.title = title.isEmpty ? nil : title
            }
        }
        let amount = edit.amount ?? row.amountDecimal
        if let input = edit.amount, input.isNaN || input <= 0 { throw AppIntentError.invalidAmount }
        let code = try edit.currencyCode.map(currency) ?? row.resolvedCurrencyCode
        if amount != row.amountDecimal || code != row.resolvedCurrencyCode {
            changes.append(String(localized: "金額：\(originalAmount) → \(amount) \(code)"))
            row.amount = NSDecimalNumber(decimal: amount)
            row.currencyCode = code
            if row.generatedFromRuleID == nil { row.captureFXSnapshot() }
            else {
                row.fxConvertedAmountDecimal = nil
                row.fxTargetCurrency = nil
            }
        }
        if let date = edit.date, row.date.map({ !Calendar.current.isDate($0, inSameDayAs: date) }) != false {
            changes.append(String(localized: "日付：\(originalDate) → \(date.formatted(date: .abbreviated, time: .shortened))"))
            row.date = date
        }
        if let id = edit.categoryID {
            let chosen = try category(id, for: row.kind, in: sheet, access: access)
            if row.category?.objectID != chosen?.objectID || (chosen == nil && !(row.categoryRaw ?? "").isEmpty) {
                changes.append(String(localized: "カテゴリ：\(row.categoryDisplayName) → \(chosen?.displayName ?? String(localized: "カテゴリなし"))"))
                row.category = chosen
                row.categoryRaw = chosen?.name
            }
        }
        guard !changes.isEmpty else { return nil }
        return "\(row.kind.label)　\(originalName)　\(originalAmount)　\(originalDate)\n" + changes.joined(separator: "、")
    }

    private static func category(_ id: String, for kind: TransactionKind, in sheet: ExpenseSheet,
                                 access: IntentSheetAccess) throws -> ExpenseCategory? {
        if id == AddExpenseIntent.skipCategoryID { return nil }
        guard let url = URL(string: id), url.scheme == "x-coredata",
              let oid = access.context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
              oid.entity.name == "ExpenseCategory", let cat = try access.context.existingObject(with: oid) as? ExpenseCategory,
              cat.sheet?.objectID == sheet.objectID, cat.kind == kind, !cat.isDeleted else { throw BatchError.invalidCategory }
        if let live = access.viewContext.registeredObject(for: oid), live.isDeleted || live.hasPersistentChangedValues {
            throw BatchError.stale
        }
        return cat
    }
}

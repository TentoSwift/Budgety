#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, macOS 27.3, *)
struct SiriEditingCategoryQuery: EntityStringQuery {
    @IntentParameterDependency<SiriEditTransactionIntent>(\.$transaction) var editTarget
    @IntentParameterDependency<SiriEditTransactionIntent>(\.$sheet) var editSheet

    @MainActor
    func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        try choices(matching: "")
    }

    @MainActor
    func entities(matching string: String) async throws -> [ExpenseCategoryEntity] {
        try choices(matching: string)
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExpenseCategoryEntity] {
        guard let (access, row, _) = try target() else { return [] }
        let categories = try Self.labeledCategories(for: row, access: access)
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.category.objectID.uriRepresentation().absoluteString, $0) })
        return identifiers.compactMap { id in
            if id == AddExpenseIntent.skipCategoryID { return .skipEntity() }
            guard let item = byID[id], Self.allows(item.category, for: row, access: access) else { return nil }
            return item.entity
        }
    }

    @MainActor
    private func target() throws -> (IntentSheetAccess, Expense, ExpenseSheet)? {
        guard let selection = editTarget?.transaction else { return nil }
        if let sheetID = editSheet?.sheet.id, sheetID != selection.sheetID { return nil }
        return try SiriTransactionEditStore.target(selection.id, in: selection.sheetID)
    }

    @MainActor
    private func choices(matching string: String) throws -> [ExpenseCategoryEntity] {
        guard let (access, row, _) = try target() else { return [] }
        let query = Self.searchKey(string)
        let unassigned = ExpenseCategoryEntity.skipEntity()
        let aliases = [unassigned.name, String(localized: "未分類")]
        var choices: [ExpenseCategoryEntity] = query.isEmpty || aliases.contains(where: { Self.searchKey($0).contains(query) })
            ? [unassigned] : []
        for item in try Self.labeledCategories(for: row, access: access) {
            guard Self.allows(item.category, for: row, access: access),
                  query.isEmpty || Self.searchKey(item.label).contains(query) else { continue }
            choices.append(item.entity)
        }
        return choices
    }

    private struct LabeledCategory {
        let category: ExpenseCategory
        let label: String

        @MainActor var entity: ExpenseCategoryEntity {
            var value = ExpenseCategoryEntity.from(category)
            value.name = label
            return value
        }
    }

    /// Number namesakes before filtering by the search text, so a saved choice and its confirmation have the same label.
    @MainActor
    private static func labeledCategories(for transaction: Expense, access: IntentSheetAccess) throws -> [LabeledCategory] {
        guard let sheet = transaction.sheet, access.allows(sheet) else { throw AppIntentError.sheetNotFound }
        let request = NSFetchRequest<ExpenseCategory>(entityName: "ExpenseCategory")
        request.predicate = NSPredicate(format: "sheet == %@", sheet)
        let ordered = try access.context.fetch(request)
            .filter { matchesKind($0, transaction.kind) && !$0.isDeleted && !$0.objectID.isTemporaryID }
            .sorted { left, right in
                if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
                let firstDate = left.createdAt ?? .distantPast, secondDate = right.createdAt ?? .distantPast
                if firstDate != secondDate { return firstDate < secondDate }
                return left.objectID.uriRepresentation().absoluteString < right.objectID.uriRepresentation().absoluteString
            }
        let groups = Dictionary(grouping: ordered, by: \.displayName)
        var positions: [String: Int] = [:]
        return ordered.map { category in
            let name = category.displayName
            positions[name, default: 0] += 1
            let index = positions[name, default: 1]
            let label = groups[name]?.count == 1 ? name : String(localized: "\(name)（\(index)番目）")
            return LabeledCategory(category: category, label: label)
        }
    }

    @MainActor
    static func duplicateLabel(for category: ExpenseCategory, transaction: Expense, access: IntentSheetAccess) throws -> String {
        guard category.sheet?.objectID == transaction.sheet?.objectID else { throw SelectionError.unavailable }
        let choices = try labeledCategories(for: transaction, access: access)
        return choices.first { $0.category.objectID == category.objectID }?.label ?? category.displayName
    }

    private static func matchesKind(_ category: ExpenseCategory, _ kind: TransactionKind) -> Bool {
        let raw = category.kindRaw ?? ""
        return raw == kind.rawValue || (raw.isEmpty && kind == .expense)
    }

    /// Both the picker and the writer resolve the exact chosen ID; nil means an explicit request to clear it.
    @MainActor
    static func resolve(_ id: String, for transaction: Expense, access: IntentSheetAccess) throws -> ExpenseCategory? {
        guard let sheet = transaction.sheet, access.allows(sheet) else { throw AppIntentError.sheetNotFound }
        if id == AddExpenseIntent.skipCategoryID { return nil }
        guard let url = URL(string: id), url.scheme == "x-coredata",
              let oid = access.context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
              oid.entity.name == "ExpenseCategory",
              let category = try? access.context.existingObject(with: oid) as? ExpenseCategory,
              allows(category, for: transaction, access: access) else { throw SelectionError.unavailable }
        return category
    }

    @MainActor
    private static func allows(_ category: ExpenseCategory, for transaction: Expense, access: IntentSheetAccess) -> Bool {
        guard !category.isDeleted, !category.objectID.isTemporaryID,
              let sheet = category.sheet, sheet.objectID == transaction.sheet?.objectID,
              category.objectID.persistentStore == transaction.objectID.persistentStore,
              PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: category.objectID) else { return false }
        guard matchesKind(category, transaction.kind) else { return false }
        if let live = access.viewContext.registeredObject(for: category.objectID) as? ExpenseCategory {
            return !live.isDeleted && !live.hasPersistentChangedValues && live.sheet?.objectID == sheet.objectID
        }
        return true
    }

    private static func searchKey(_ value: String) -> String {
        let folded = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }

    private enum SelectionError: Error, CustomLocalizedStringResourceConvertible {
        case unavailable
        var localizedStringResource: LocalizedStringResource { "この明細に使えるカテゴリを選び直してください。" }
    }
}
#endif

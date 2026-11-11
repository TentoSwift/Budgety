#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, *)
struct SiriEditableTransactionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "編集対象の明細"
    static let defaultQuery = SiriEditableTransactionQuery()
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    let id: String
    @Property(title: "シートの識別子", visibility: .internal) var sheetID: String
    @Property(title: "シート名") var sheetName: String
    @Property(title: "名前") var title: String
    @Property(title: "日付") var date: Date?
    @Property(title: "金額") var amount: String
    @Property(title: "取引の種類") var kindName: String

    @MainActor
    static func from(_ expense: Expense) -> Self { Self(expense) }

    @MainActor
    private init(_ expense: Expense) {
        id = expense.objectID.uriRepresentation().absoluteString
        sheetID = expense.sheet?.objectID.uriRepresentation().absoluteString ?? ""
        sheetName = expense.sheet?.displayName ?? ""
        title = expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle
        date = expense.date
        let currency = expense.resolvedCurrencyCode
        amount = currency == expense.sheet?.resolvedDefaultCurrencyCode ? expense.formattedSignedAmount
            : "\(expense.formattedSignedAmount) \(currency)"
        kindName = expense.kind.label
    }

    var displayRepresentation: DisplayRepresentation {
        let when = date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "日付不明")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(when) · \(amount) · \(sheetName)")
    }
}

@available(iOS 27.3, *)
struct SiriEditableTransactionQuery: EntityStringQuery {
    @IntentParameterDependency<SiriEditTransactionIntent>(\.$sheet) var edit

    @MainActor
    func suggestedEntities() async throws -> [SiriEditableTransactionEntity] {
        try entities(in: edit?.sheet.id, matching: "")
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriEditableTransactionEntity] {
        try entities(in: edit?.sheet.id, matching: string)
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriEditableTransactionEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try Self.resolve(identifiers, in: edit?.sheet.id, access: access)
    }

    @MainActor
    static func resolve(_ identifiers: [String], in sheetID: String?, access: IntentSheetAccess) throws -> [SiriEditableTransactionEntity] {
        let requestedSheet = try sheetID.map { try access.resolve($0) }
        return identifiers.compactMap { id in
            guard let live = try? access.transactionForDisplay(identifier: id), !live.hasPersistentChangedValues,
                  PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: live.objectID),
                  requestedSheet == nil || live.sheet?.objectID == requestedSheet?.objectID,
                  let stored = try? access.context.existingObject(with: live.objectID) as? Expense else { return nil }
            return .from(stored)
        }
    }

    @MainActor
    private func entities(in sheetID: String?, matching string: String) throws -> [SiriEditableTransactionEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet: ExpenseSheet
        if let sheetID {
            sheet = try access.resolve(sheetID)
        } else if let last = UserDefaults.standard.string(forKey: "lastOpenedSheetURI"), !last.isEmpty {
            // A locked or deleted last-used sheet cannot silently redirect an edit into another sheet.
            guard let accessible = try? access.resolve(last) else { throw SelectionError.sheetRequired }
            sheet = accessible
        } else {
            let available = try access.sheets()
            guard available.count == 1 else {
                if available.isEmpty { throw AppIntentError.sheetNotFound }
                throw SelectionError.sheetRequired
            }
            sheet = available[0]
        }
        return try Self.candidates(in: sheet, matching: string, access: access)
    }

    @MainActor
    static func candidates(in sheet: ExpenseSheet, matching string: String,
                           access: IntentSheetAccess) throws -> [SiriEditableTransactionEntity] {
        guard access.allows(sheet) else { throw AppIntentError.sheetNotFound }
        let query = TransactionSearchTerm(string)
        let request = NSFetchRequest<Expense>(entityName: "Expense")
        request.predicate = NSPredicate(format: "sheet == %@ AND (isSkipped == NO OR isSkipped == nil)", sheet)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Expense.date, ascending: false),
                                   NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)]
        request.fetchBatchSize = 64
        var matches: [SiriEditableTransactionEntity] = []
        for expense in try access.context.fetch(request) {
            if let live = access.viewContext.registeredObject(for: expense.objectID) as? Expense,
               live.hasPersistentChangedValues || live.isDeleted || live.isSkipped || live.sheet?.objectID != sheet.objectID { continue }
            guard query.isEmpty || query.matchesNameOrCategory(of: expense),
                  PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: expense.objectID) else { continue }
            matches.append(.from(expense))
            // A blank picker shows recent transactions. A named search includes older matches and namesakes.
            if query.isEmpty, matches.count == 20 { break }
        }
        return matches
    }


    private enum SelectionError: Error, CustomLocalizedStringResourceConvertible {
        case sheetRequired
        var localizedStringResource: LocalizedStringResource { "先に編集する明細のシートを選んでください。" }
    }
}
#endif

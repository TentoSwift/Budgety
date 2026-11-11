//
//  ExpenseSheetEntity.swift
//  Expenso
//
//  AppIntents で「シート」を選ぶための AppEntity ラッパー。
//  Core Data の `ExpenseSheet` は直接 AppEntity 化できないので、
//  objectID の URI 表現を id とした struct でブリッジする。
//

import AppIntents
import CoreData

struct ExpenseSheetEntity: AppEntity {
    #if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
    @available(iOS 27.3, *)
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    #endif

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "シート")
    }
    static var defaultQuery = ExpenseSheetEntityQuery()

    /// `ExpenseSheet.objectID.uriRepresentation().absoluteString` を識別子として使う。
    var id: String
    var name: String
    var symbol: String
    var colorHex: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Read committed data in a fresh context. A pending password change or deletion in the
/// app's view context must take effect before Siri, Shortcuts, or Spotlight can expose it.
@MainActor
struct IntentSheetAccess {
    let context: NSManagedObjectContext
    let viewContext: NSManagedObjectContext

    init(checking viewContext: NSManagedObjectContext) throws {
        guard let coordinator = viewContext.persistentStoreCoordinator else {
            throw AppIntentError.sheetNotFound
        }
        self.viewContext = viewContext
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }

    func sheets() throws -> [ExpenseSheet] {
        let request = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)]
        return try context.fetch(request).filter(allows)
    }

    func resolve(_ id: String) throws -> ExpenseSheet {
        guard let url = URL(string: id),
              let oid = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
              let sheet = try? context.existingObject(with: oid) as? ExpenseSheet,
              allows(sheet) else { throw AppIntentError.sheetNotFound }
        return sheet
    }

    func allows(_ sheet: ExpenseSheet) -> Bool {
        let oid = sheet.objectID
        guard !oid.isTemporaryID, !isProtectedOrDeleted(sheet) else { return false }
        if let editing = viewContext.registeredObject(for: oid) as? ExpenseSheet,
           isProtectedOrDeleted(editing) { return false }
        let key = SheetLockManager.legacyPrefix + oid.uriRepresentation().absoluteString
        return UserDefaults.standard.object(forKey: key) == nil
    }

    private func isProtectedOrDeleted(_ sheet: ExpenseSheet) -> Bool {
        sheet.isDeleted || sheet.lockPasswordHash?.isEmpty == false ||
            sheet.lockPasswordSalt?.isEmpty == false
    }
}

struct ExpenseSheetEntityQuery: EntityStringQuery {
    @MainActor
    func suggestedEntities() async throws -> [ExpenseSheetEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try access.sheets().map(ExpenseSheetEntity.from)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ExpenseSheetEntity] {
        let search = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let sheets = try await suggestedEntities()
        return search.isEmpty ? sheets : sheets.filter { $0.name.localizedStandardContains(search) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExpenseSheetEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return identifiers.compactMap { id in
            (try? access.resolve(id)).map(ExpenseSheetEntity.from)
        }
    }
}

extension ExpenseSheetEntity {
    @MainActor
    static func from(_ sheet: ExpenseSheet) -> ExpenseSheetEntity {
        ExpenseSheetEntity(
            id: sheet.objectID.uriRepresentation().absoluteString,
            name: sheet.displayName,
            symbol: sheet.displaySymbol,
            colorHex: sheet.displayColorHex
        )
    }
}

#if os(iOS) || os(macOS) || os(watchOS)
import CoreData

/// A card opens one specific child screen of a sheet on this device.
struct SiriSheetSelection: Hashable {
    enum Destination: Hashable {
        case expense(String)
        case settlement(String)
    }

    let destination: Destination
    let sheetID: NSManagedObjectID

    @MainActor
    init(_ destination: Destination, in context: NSManagedObjectContext) throws {
        self.destination = destination
        let access = try IntentSheetAccess(checking: context)
        switch destination {
        case .expense(let identifier):
            switch try SiriVirtualExpenseLink.resolve(identifier, access: access) {
            case .stored(let expense):
                guard let sheet = expense.sheet else { throw AppIntentError.expenseUnavailable }
                sheetID = sheet.objectID
            case .virtual(_, let sheet, _):
                sheetID = sheet.objectID
            }
        case .settlement(let identifier):
            sheetID = try access.resolve(identifier).objectID
        }
    }

    /// Selection can wait for foregrounding or an editor. Recheck Siri access before routing.
    @MainActor
    func currentSheet(in context: NSManagedObjectContext) -> ExpenseSheet? {
        guard let current = try? Self(destination, in: context), current.sheetID == sheetID,
              let sheet = try? context.existingObject(with: sheetID) as? ExpenseSheet,
              !sheet.isDeleted else { return nil }
        return sheet
    }
}
#endif

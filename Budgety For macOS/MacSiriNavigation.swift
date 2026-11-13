import AppKit
import Combine
import CoreData
import SwiftUI

@MainActor
final class MacSiriNavigation: ObservableObject {
    struct Selection: Hashable {
        let identifier: String
        let sheetID: NSManagedObjectID
    }

    static let shared = MacSiriNavigation()
    @Published private(set) var selection: Selection?

    func requestOpenExpense(identifier: String) throws {
        let context = PersistenceController.shared.container.viewContext
        let target = try SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
        let sheetID: NSManagedObjectID
        switch target {
        case .stored(let expense):
            guard let sheet = expense.sheet else { throw AppIntentError.expenseUnavailable }
            sheetID = sheet.objectID
        case .virtual(_, let sheet, _):
            sheetID = sheet.objectID
        }
        selection = Selection(identifier: identifier, sheetID: sheetID)
        NSApp.activate()
    }

    func takeSelection() -> Selection? {
        defer { selection = nil }
        return selection
    }
}

struct MacSiriExpenseDetail: View {
    let identifier: String
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        if let target = try? SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context)) {
            switch target {
            case .stored(let expense):
                if let sheet = expense.sheet {
                    ExpenseDetailView(expense: expense, lockRecord: sheet)
                }
            case .virtual(let occurrence, let sheet, _):
                if let draft = RecurringOccurrenceDraft(occurrence, sheet: sheet) {
                    ExpenseDetailView(expense: draft.expense, isVirtualDraft: true, lockRecord: sheet)
                }
            }
        } else {
            ContentUnavailableView("この明細は現在表示できません。", systemImage: "doc.text.magnifyingglass")
        }
    }
}

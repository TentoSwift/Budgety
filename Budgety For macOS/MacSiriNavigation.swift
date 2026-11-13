import AppKit
import CoreData
import SwiftUI

@MainActor
final class MacSiriNavigation: NSObject, NSWindowDelegate {
    static let shared = MacSiriNavigation()
    private var detailWindow: NSWindow?

    func requestOpenExpense(identifier: String) throws {
        let context = PersistenceController.shared.container.viewContext
        let target = try SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
        let detail = MacSiriExpenseDetail(target: target).environment(\.managedObjectContext, context)
        let controller = NSHostingController(rootView: detail)
        let window = detailWindow ?? NSWindow(contentViewController: controller)
        window.contentViewController = controller
        window.title = String(localized: "明細")
        window.isReleasedWhenClosed = false
        window.delegate = self
        if detailWindow == nil { window.center() }
        detailWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        detailWindow = nil
    }
}

private struct MacSiriExpenseDetail: View {
    let target: SiriVirtualExpenseLink.Target

    var body: some View {
        NavigationStack {
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
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 340, idealHeight: 520)
    }
}

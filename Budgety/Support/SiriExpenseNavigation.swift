#if os(iOS)
import CoreData
import SwiftUI
import UIKit

@MainActor
extension DeepLinkRouter {
    func requestOpenExpense(identifier: String) throws {
        let context = PersistenceController.shared.container.viewContext
        _ = try IntentSheetAccess(checking: context).expenseForDisplay(identifier: identifier)
        pendingExpenseIdentifier = identifier
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive && $0.keyWindow != nil }) {
            presentPendingExpense(in: scene)
        }
    }

    func presentPendingExpense(in scene: UIWindowScene) {
        guard let identifier = pendingExpenseIdentifier, scene.activationState == .foregroundActive,
              var presenter = scene.keyWindow?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        if let transition = presenter.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in
               Task { @MainActor in self.presentPendingExpense(in: scene) }
           }) { return }

        pendingExpenseIdentifier = nil
        let context = PersistenceController.shared.container.viewContext
        let expense = try? IntentSheetAccess(checking: context).expenseForDisplay(identifier: identifier)
        let detail = SiriExpenseDetail(expense: expense, context: context)
        if let current = presenter as? UIHostingController<SiriExpenseDetail> {
            current.rootView = detail
        } else {
            // Present above the current editor so following a card never discards an open draft.
            presenter.present(UIHostingController(rootView: detail), animated: true)
        }
    }
}

private struct SiriExpenseDetail: View {
    let expense: Expense?
    let context: NSManagedObjectContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let expense {
                    ExpenseDetailView(expense: expense)
                        .id(expense.objectID)
                } else {
                    ContentUnavailableView("この支出明細は現在表示できません。", systemImage: "doc.text.magnifyingglass")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .environment(\.managedObjectContext, context)
        .appUpdateGate()
    }
}
#endif

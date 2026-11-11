#if os(iOS)
import CoreData
import SwiftUI
import UIKit

@MainActor
extension DeepLinkRouter {
    func requestOpenExpense(identifier: String) throws {
        let context = PersistenceController.shared.container.viewContext
        _ = try SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
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
        let target = try? SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
        let detail = SiriExpenseDetail(identifier: identifier, target: target, context: context)
        if let current = presenter as? UIHostingController<SiriExpenseDetail> {
            current.rootView = detail
        } else {
            // Present above the current editor so following a card never discards an open draft.
            presenter.present(UIHostingController(rootView: detail), animated: true)
        }
    }
}

private struct SiriExpenseDetail: View {
    let identifier: String
    let target: SiriVirtualExpenseLink.Target?
    let context: NSManagedObjectContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch target {
                case .stored(let expense):
                    ExpenseDetailView(expense: expense, onCommit: {
                        if expense.isDeleted || expense.managedObjectContext == nil { dismiss() }
                    })
                    .id(expense.objectID)
                case .virtual(let occurrence, let sheet, let rule):
                    SiriVirtualExpenseDetail(identifier: identifier, occurrence: occurrence, sheet: sheet, rule: rule)
                        .id(identifier)
                case nil:
                    ContentUnavailableView("この明細は現在表示できません。", systemImage: "doc.text.magnifyingglass")
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
/// The detail reads a disposable child-context row. Only an explicit edit needs a live occurrence.
private struct SiriVirtualExpenseDetail: View {
    let identifier: String
    let occurrence: RecurringOccurrence
    @ObservedObject var sheet: ExpenseSheet
    @ObservedObject var rule: RecurringRule
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var backing = VirtualRowBacking()
    @State private var editor: Expense?
    @State private var draft: Expense?
    @State private var didCommit = false
    @State private var pendingRule: RecurringRule?
    @State private var editingRule: RecurringRule?
    @State private var unavailable = false

    var body: some View {
        Group {
            if unavailable || sheet.isDeleted || rule.isDeleted {
                ContentUnavailableView("この明細は現在表示できません。", systemImage: "doc.text.magnifyingglass")
            } else {
                let preview = backing.displayExpense(for: occurrence, sheet: sheet)
                ExpenseDetailView(expense: preview, onEdit: beginEditing, lockRecord: sheet)
                    .onChange(of: rule.note, initial: true) { _, note in preview.note = note }
            }
        }
        .sheet(item: $editor, onDismiss: finishEditing) { expense in
            AddExpenseView(expense: expense, onEditRule: { pendingRule = $0 }, onCommit: { didCommit = true })
        }
        .sheet(item: $editingRule, onDismiss: { dismiss() }) { rule in
            EditRecurringRuleView(mode: .edit(rule: rule))
        }
    }

    private func beginEditing() {
        guard let target = try? SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
        else { unavailable = true; return }
        switch target {
        case .stored(let expense):
            editor = expense
        case .virtual(let occurrence, let sheet, let rule):
            let category = (sheet.categories as? Set<ExpenseCategory>)?.first {
                $0.name == occurrence.categoryRaw && $0.kind == occurrence.kind && $0.objectID.persistentStore == sheet.objectID.persistentStore
            }
            let expense = RecurringExpenseGenerator.makeOccurrence(for: rule, on: occurrence.date, sheet: sheet,
                                                                  category: category, in: context)
            draft = expense
            editor = expense
        }
    }

    private func finishEditing() {
        if let draft, !didCommit, draft.managedObjectContext != nil, !draft.isDeleted {
            let persisted = !draft.isInserted
            context.delete(draft)
            if persisted { PersistenceController.shared.save() }
        }
        draft = nil
        if didCommit { dismiss() }
        didCommit = false
        if let pendingRule {
            editingRule = pendingRule
            self.pendingRule = nil
        }
    }
}
#endif

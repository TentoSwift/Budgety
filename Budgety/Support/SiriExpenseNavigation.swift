#if os(iOS)
import CoreData
import SwiftUI

@MainActor
extension DeepLinkRouter {
    func requestOpenExpense(identifier: String) throws {
        let context = PersistenceController.shared.container.viewContext
        _ = try SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
        pendingExpenseIdentifier = identifier
        NotificationCenter.default.post(name: .expensoOpenExpense, object: nil)
    }
}

struct SiriExpenseDestination: View {
    let identifier: String
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let access = try? IntentSheetAccess(checking: context),
           let target = try? SiriVirtualExpenseLink.resolve(identifier, access: access) {
            switch target {
            case .stored(let expense):
                ExpenseDetailView(expense: expense, onCommit: {
                    if expense.isDeleted || expense.managedObjectContext == nil { dismiss() }
                }, lockRecord: expense.sheet)
            case .virtual(let occurrence, let sheet, let rule):
                SiriVirtualExpenseDetail(identifier: identifier, occurrence: occurrence, sheet: sheet, rule: rule)
            }
        } else {
            ContentUnavailableView("この明細は現在表示できません。", systemImage: "doc.text.magnifyingglass")
        }
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
            AddExpenseView(expense: expense, isVirtualDraft: expense.managedObjectContext !== context, onEditRule: { pendingRule = $0 }, onCommit: { didCommit = true })
        }
        .sheet(item: $editingRule, onDismiss: { dismiss() }) { rule in
            EditRecurringRuleView(mode: .edit(rule: rule), occurrenceDate: occurrence.scheduledDate)
        }
    }

    private func beginEditing() {
        guard let target = try? SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
        else { unavailable = true; return }
        switch target {
        case .stored(let expense):
            editor = expense
        case .virtual(let occurrence, let sheet, _):
            editor = backing.displayExpense(for: occurrence, sheet: sheet)
        }
    }

    private func finishEditing() {
        if didCommit { dismiss() }
        didCommit = false
        if let pendingRule {
            editingRule = pendingRule
            self.pendingRule = nil
        }
    }
}
#endif

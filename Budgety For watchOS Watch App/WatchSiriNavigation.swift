import Combine
import CoreData
import SwiftUI

@MainActor
final class WatchSiriNavigation: ObservableObject {
    struct Selection: Identifiable {
        let id: String
        let sheet: ExpenseSheet
    }

    static let shared = WatchSiriNavigation()
    @Published var selection: Selection?
    @Published var editingDraft = false

    func requestOpenExpense(identifier: String) throws {
        let context = PersistenceController.shared.container.viewContext
        let target = try SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context))
        switch target {
        case .stored(let expense):
            guard let sheet = expense.sheet else { throw AppIntentError.expenseUnavailable }
            selection = Selection(id: identifier, sheet: sheet)
        case .virtual(_, let sheet, _):
            selection = Selection(id: identifier, sheet: sheet)
        }
    }
}

struct WatchSiriExpenseDetail: View {
    let identifier: String
    @ObservedObject var sheet: ExpenseSheet
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        Group {
            if !sheet.isDeleted, let target = try? SiriVirtualExpenseLink.resolve(identifier, access: IntentSheetAccess(checking: context)) {
                switch target {
                case .stored(let expense):
                    WatchExpenseDetailView(expense: expense, sheet: sheet)
                case .virtual(let occurrence, _, _):
                    ScrollView {
                        VStack(spacing: 8) {
                            Label("繰り返し", systemImage: "repeat")
                                .font(.caption)
                            Text(CurrencyCatalog.format(occurrence.amount, code: occurrence.currencyCode))
                                .font(.system(.title2, design: .rounded).bold())
                            Text(occurrence.title.isEmpty ? occurrence.categoryDisplayName : occurrence.title)
                            Text(occurrence.date, format: .dateTime.year().month().day())
                                .font(.caption)
                        }
                    }
                    .navigationTitle(sheet.displayName)
                }
            } else {
                ContentUnavailableView("この明細は現在表示できません。", systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

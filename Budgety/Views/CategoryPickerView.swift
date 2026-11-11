import SwiftUI
import CoreData

struct TransactionCategoryMenu: View {
    @ObservedObject var sheet: ExpenseSheet
    let kind: TransactionKind
    @Binding var selection: ExpenseCategory?
    @State private var addingCategory = false
    @FetchRequest private var categories: FetchedResults<ExpenseCategory>

    init(sheet: ExpenseSheet, kind: TransactionKind, selection: Binding<ExpenseCategory?>) {
        self.sheet = sheet
        self.kind = kind
        _selection = selection
        let predicate = kind == .expense
            ? NSPredicate(format: "sheet == %@ AND (kindRaw == %@ OR kindRaw == nil OR kindRaw == '')", sheet, kind.rawValue)
            : NSPredicate(format: "sheet == %@ AND kindRaw == %@", sheet, kind.rawValue)
        _categories = FetchRequest(sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseCategory.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \ExpenseCategory.createdAt, ascending: true)
        ], predicate: predicate)
    }

    var body: some View {
        Menu {
            Picker("カテゴリ", selection: $selection) {
                Text("未選択").tag(nil as ExpenseCategory?)
                ForEach(categories, id: \.objectID) { category in
                    Label(category.displayName, systemImage: category.displaySymbol)
                        .tag(Optional(category))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("新しいカテゴリを追加", systemImage: "plus") { addingCategory = true }
        } label: {
            HStack(spacing: 8) {
                Text("カテゴリ").foregroundStyle(.primary)
                Spacer()
                if let selection {
                    CategoryIconView(category: selection, size: 24)
                    Text(selection.displayName)
                } else {
                    Text("未選択")
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityValue(selection?.displayName ?? String(localized: "未選択"))
        .sheet(isPresented: $addingCategory) {
            EditCategoryView(mode: .create(record: sheet), defaultKind: kind) { selection = $0 }
        }
    }
}

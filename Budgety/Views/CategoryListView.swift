//
//  CategoryListView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct CategoryListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var record: ExpenseSheet

    @FetchRequest private var categories: FetchedResults<ExpenseCategory>

    @State private var editingCategory: ExpenseCategory?
    @State private var showingNew = false
    @State private var showingPaywall = false
    /// 削除ダイアログの対象。`nil` ならダイアログは閉じている。
    @State private var deletingCategory: ExpenseCategory?

    init(record: ExpenseSheet) {
        self.record = record
        _categories = FetchRequest<ExpenseCategory>(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \ExpenseCategory.sortOrder, ascending: true),
                NSSortDescriptor(keyPath: \ExpenseCategory.createdAt, ascending: true)
            ],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    private var expenseCategories: [ExpenseCategory] {
        categories.filter { $0.kind == .expense }
    }
    private var incomeCategories: [ExpenseCategory] {
        categories.filter { $0.kind == .income }
    }

    var body: some View {
        List {
            section(title: TransactionKind.expense.label, items: expenseCategories)
            section(title: TransactionKind.income.label, items: incomeCategories)
        }
        .navigationTitle("\(record.displayName) のカテゴリ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if !os(macOS)
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if PurchaseManager.canAddCategory(to: record) {
                        showingNew = true
                    } else {
                        showingPaywall = true
                        Haptics.warning()
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editingCategory) { cat in
            #if os(macOS)
            MacEditCategoryView(mode: .edit(category: cat))
            #else
            EditCategoryView(mode: .edit(category: cat))
            #endif
        }
        .sheet(isPresented: $showingNew) {
            #if os(macOS)
            MacEditCategoryView(mode: .create(record: record, defaultKind: .expense))
            #else
            EditCategoryView(mode: .create(record: record))
            #endif
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .confirmationDialog(
            deletingCategory.map { String(localized: "「\($0.displayName)」を削除しますか?") } ?? "",
            isPresented: Binding(
                get: { deletingCategory != nil },
                set: { if !$0 { deletingCategory = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("カテゴリなしに分類") {
                if let cat = deletingCategory { performDelete(category: cat, deleteExpenses: false) }
                deletingCategory = nil
            }
            Button("カテゴリと支出をすべて削除", role: .destructive) {
                if let cat = deletingCategory { performDelete(category: cat, deleteExpenses: true) }
                deletingCategory = nil
            }
            Button("キャンセル", role: .cancel) { deletingCategory = nil }
        } message: {
            Text("このカテゴリを使っている支出を「カテゴリなし」に変えてカテゴリのみ削除するか、支出ごとすべて削除するかを選んでください。")
        }
    }

    /// ダイアログで選択された方針に従ってカテゴリを削除する。
    /// (実装は EditCategoryView と共有)
    private func performDelete(category: ExpenseCategory, deleteExpenses: Bool) {
        EditCategoryView.deleteCategory(
            category,
            deleteExpenses: deleteExpenses,
            in: viewContext
        )
        Haptics.warning()
    }

    @ViewBuilder
    private func section(title: String, items: [ExpenseCategory]) -> some View {
        Section {
            ForEach(items, id: \.objectID) { cat in
                Button {
                    editingCategory = cat
                } label: {
                    HStack(spacing: 12) {
                        CategoryIconView(category: cat, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.displayName)
                                .foregroundStyle(.primary)
                            if cat.isBuiltIn {
                                Text("デフォルト")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        deletingCategory = cat
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
            .onMove { source, destination in
                moveCategories(items: items, from: source, to: destination)
            }
        } header: {
            Text(title)
        }
    }

    private func moveCategories(items: [ExpenseCategory], from source: IndexSet, to destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        let baseSort = items.map(\.sortOrder).min() ?? 0
        for (i, cat) in reordered.enumerated() {
            cat.sortOrder = Int32(i) + baseSort
        }
        PersistenceController.shared.save()
    }
}

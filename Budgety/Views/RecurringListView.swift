//
//  RecurringListView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct RecurringListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var record: ExpenseSheet

    @FetchRequest private var rules: FetchedResults<RecurringRule>

    @State private var editingRule: RecurringRule?
    @State private var showingNew = false
    /// 親 view から「この Rule を表示直後に開いて」と指定されるとここに入り、
    /// `onAppear` で `editingRule` にセットしてシートを開く。
    private let autoEditRule: RecurringRule?
    @State private var didAutoOpen = false

    init(record: ExpenseSheet, autoEditRule: RecurringRule? = nil) {
        self.record = record
        self.autoEditRule = autoEditRule
        _rules = FetchRequest<RecurringRule>(
            sortDescriptors: [NSSortDescriptor(keyPath: \RecurringRule.createdAt, ascending: true)],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    private var expenseRules: [RecurringRule] {
        rules.filter { $0.kind == .expense }
    }

    private var incomeRules: [RecurringRule] {
        rules.filter { $0.kind == .income }
    }

    var body: some View {
        Group {
            if rules.isEmpty {
                ContentUnavailableView {
                    Label("定期項目がありません", systemImage: "repeat")
                } description: {
                    Text("家賃・サブスク・給料など、毎月や毎週に繰り返される支出/収入を登録すると、自動でシートに追加されます。")
                } actions: {
                    Button {
                        showingNew = true
                    } label: {
                        Label("追加", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    section(title: TransactionKind.expense.label, items: expenseRules)
                    section(title: TransactionKind.income.label, items: incomeRules)
                }
            }
        }
        .navigationTitle("定期項目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            EditRecurringRuleView(mode: .edit(rule: rule))
        }
        .sheet(isPresented: $showingNew) {
            EditRecurringRuleView(mode: .create(record: record))
        }
        .onAppear {
            // AddExpenseView から飛んできた直後など、開いた瞬間に
            // 特定の Rule の編集シートを自動的に開く。
            guard !didAutoOpen, let target = autoEditRule else { return }
            didAutoOpen = true
            DispatchQueue.main.async {
                editingRule = target
            }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [RecurringRule]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { rule in
                    Button {
                        editingRule = rule
                    } label: {
                        RecurringRow(rule: rule, sheet: record)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    deleteRules(items: items, at: offsets)
                }
            }
        }
    }

    private func deleteRules(items: [RecurringRule], at offsets: IndexSet) {
        withAnimation {
            offsets.map { items[$0] }.forEach(viewContext.delete)
            PersistenceController.shared.save()
            Haptics.warning()
        }
    }
}

private struct RecurringRow: View {
    @ObservedObject var rule: RecurringRule
    let sheet: ExpenseSheet

    /// Rule.categoryRaw からシートの ExpenseCategory を引く。無ければ nil。
    private var resolvedCategory: ExpenseCategory? {
        guard let raw = rule.categoryRaw, !raw.isEmpty,
              let cats = sheet.categories as? Set<ExpenseCategory> else { return nil }
        return cats.first(where: { $0.name == raw })
    }

    private var icon: some View {
        Group {
            if let cat = resolvedCategory {
                CategoryIconView(category: cat, size: 36)
            } else {
                CategoryIconView(symbol: "tag.slash", tint: .gray, size: 36)
            }
        }
    }

    private var categoryName: String {
        resolvedCategory?.displayName ?? (rule.categoryRaw?.isEmpty == false ? rule.categoryRaw! : String(localized: "未分類"))
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayTitle.isEmpty ? String(localized: "(無題)") : rule.displayTitle)
                    .font(.body)
                HStack(spacing: 6) {
                    Image(systemName: "repeat")
                    Text(rule.resolvedFrequency.summary(interval: rule.resolvedInterval))
                    Text("·")
                    Text(categoryName)
                    if let next = rule.nextOccurrence {
                        Text("·")
                        Text("次回 \(formatted(next))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(rule.formattedAmount)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(rule.kind == .income ? .green : .primary)
        }
        .padding(.vertical, 2)
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }
}

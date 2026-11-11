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
    private let autoEditDate: Date?
    @State private var occurrenceDate: Date?
    @State private var didAutoOpen = false

    init(record: ExpenseSheet, autoEditRule: RecurringRule? = nil, autoEditDate: Date? = nil) {
        self.record = record
        self.autoEditRule = autoEditRule
        self.autoEditDate = autoEditDate
        _rules = FetchRequest<RecurringRule>(
            sortDescriptors: [NSSortDescriptor(keyPath: \RecurringRule.createdAt, ascending: true)],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    private var displayedRules: [RecurringRule] {
        let families = Dictionary(grouping: rules) { $0.recurringSeriesID?.uuidString ?? $0.objectID.uriRepresentation().absoluteString }
        return families.values.compactMap { segments in
            let chronological = segments.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            return chronological.first { $0.nextScheduledOccurrence != nil } ?? chronological.last
        }.sorted {
            ($0.createdAt ?? .distantPast, $0.objectID.uriRepresentation().absoluteString) <
            ($1.createdAt ?? .distantPast, $1.objectID.uriRepresentation().absoluteString)
        }
    }

    var body: some View {
        Group {
            if rules.isEmpty {
                ContentUnavailableView {
                    Label("繰り返しがありません", systemImage: "repeat")
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
                    let items = displayedRules
                    section(title: TransactionKind.expense.label, items: items.filter { $0.kind == .expense })
                    section(title: TransactionKind.income.label, items: items.filter { $0.kind == .income })
                }
            }
        }
        .navigationTitle("繰り返し")
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
            EditRecurringRuleView(mode: .edit(rule: rule), occurrenceDate: occurrenceDate)
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
                occurrenceDate = autoEditDate
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
                        occurrenceDate = nil
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
            for i in offsets {
                RecurringExpenseGenerator.deleteRule(items[i], in: viewContext)
            }
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
        HStack(alignment: .top, spacing: 10) {
            icon
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        amount.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        amount
                    }
                }
                let frequency = rule.resolvedFrequency.summary(interval: rule.resolvedInterval)
                Text(verbatim: "\(frequency) · \(categoryName)")
                    .font(.sheetNumber(.subheadline))
                    .foregroundStyle(.secondary)
                if let next = rule.nextOccurrence {
                    Text("次回 \(formatted(next))")
                        .font(.sheetNumber(.body))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 4)
    }

    private var title: some View {
        Text(rule.displayTitle.isEmpty ? String(localized: "(無題)") : rule.displayTitle)
            .font(.body)
    }

    private var amount: some View {
        Text(rule.formattedAmount)
            .font(.sheetNumber(.title3, weight: .semibold))
            .foregroundStyle(rule.kind == .income ? Color.green : Color.primary)
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }
}

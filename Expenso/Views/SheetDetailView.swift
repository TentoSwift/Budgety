//
//  SheetDetailView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct SheetDetailView: View {
    @ObservedObject var record: ExpenseSheet
    @Environment(\.managedObjectContext) private var viewContext

    enum Period: String, CaseIterable, Identifiable {
        case thisMonth, lastMonth, thisYear, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .thisMonth: "今月"
            case .lastMonth: "先月"
            case .thisYear:  "今年"
            case .all:       "全期間"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case dateDesc, dateAsc, amountDesc, amountAsc
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dateDesc: "新しい順"
            case .dateAsc: "古い順"
            case .amountDesc: "金額が多い順"
            case .amountAsc: "金額が少ない順"
            }
        }
    }

    @State private var period: Period = .thisMonth
    @State private var showingAddExpense = false
    @State private var showingShare = false
    @State private var editingExpense: Expense?
    @State private var editingRule: RecurringRule?
    @State private var showingEditGroup = false
    @State private var searchText: String = ""
    @State private var selectedCategory: ExpenseCategory?
    @State private var demoOpenCalendar: Bool = false
    @State private var demoOpenTemplates: Bool = false
    @State private var demoOpenStats: Bool = false
    @AppStorage("expenseSortOption") private var sortOptionRaw: String = SortOption.dateDesc.rawValue

    /// シート配下の Expense を直接観測。`record.expenses` 経由だと子の attribute 変更
    /// (date / amount 等) で SwiftUI 再描画が走らず、編集後に古い日付グループに残り続けてしまう。
    @FetchRequest private var allExpenses: FetchedResults<Expense>

    init(record: ExpenseSheet) {
        self.record = record
        self._allExpenses = FetchRequest<Expense>(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    private var sortOption: SortOption {
        SortOption(rawValue: sortOptionRaw) ?? .dateDesc
    }

    // MARK: - Filtering

    /// 一覧に表示する支出/収入。期間フィルタは適用しない (= 期間ピッカーは
    /// SummaryCard の合計金額にのみ影響し、行の表示は全期間で固定)。
    /// カテゴリピル・検索・並び順はここで適用する。
    private var filteredExpenses: [Expense] {
        var list = Array(allExpenses)
        if let cat = selectedCategory {
            list = list.filter { $0.category?.objectID == cat.objectID }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayTitle.lowercased().contains(q)
                    || $0.displayPaidBy.lowercased().contains(q)
                    || ($0.note ?? "").lowercased().contains(q)
            }
        }
        switch sortOption {
        case .dateDesc:   list.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .dateAsc:    list.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        case .amountDesc: list.sort { $0.amountDecimal > $1.amountDecimal }
        case .amountAsc:  list.sort { $0.amountDecimal < $1.amountDecimal }
        }
        return list
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 16) {
                    SummaryCard(record: record, period: $period, selectedCategory: selectedCategory)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    if !allExpenses.isEmpty {
                        categoryPills
                            .padding(.horizontal)
                    }

                    if allExpenses.isEmpty {
                        emptyStateInitial
                            .padding(.top, 40)
                    } else if filteredExpenses.isEmpty {
                        emptyStateFiltered
                            .padding(.top, 40)
                    } else {
                        sectionedList
                            .padding(.horizontal)
                    }
                }
                .padding(.bottom, 100) // floating bar の余白
            }

            floatingBottomBar
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingShare = true
                } label: {
                    Image(systemName: record.isOwnedByCurrentUser ? "person.crop.circle.badge.plus" : "person.2.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        SheetCalendarView(record: record)
                    } label: {
                        Label("カレンダー", systemImage: "calendar")
                    }
                    NavigationLink {
                        SettlementView(record: record)
                    } label: {
                        Label("精算", systemImage: "arrow.left.arrow.right.circle")
                    }
                    NavigationLink {
                        StatsView(record: record)
                    } label: {
                        Label("統計を見る", systemImage: "chart.pie.fill")
                    }
                    Divider()
                    Picker("並び順", selection: $sortOptionRaw) {
                        ForEach(SortOption.allCases) { opt in
                            Text(opt.label).tag(opt.rawValue)
                        }
                    }
                    Divider()
                    Button {
                        showingEditGroup = true
                    } label: {
                        Label("シートを編集", systemImage: "pencil")
                    }
                    NavigationLink {
                        CategoryListView(record: record)
                    } label: {
                        Label("カテゴリを管理", systemImage: "tag.fill")
                    }
                    NavigationLink {
                        RecurringListView(record: record)
                    } label: {
                        Label("定期項目", systemImage: "repeat")
                    }
                    NavigationLink {
                        TemplateListView(record: record)
                    } label: {
                        Label("テンプレ", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView(record: record)
        }
        .sheet(isPresented: $showingShare) {
            CloudSharingView(record: record)
        }
        .sheet(item: $editingExpense) { expense in
            AddExpenseView(expense: expense)
        }
        .sheet(item: $editingRule) { rule in
            EditRecurringRuleView(mode: .edit(rule: rule))
        }
        .sheet(isPresented: $showingEditGroup) {
            EditSheetView(record: record)
        }
        .onAppear {
            switch ProcessInfo.processInfo.environment["EXPENSO_DEMO"] {
            case "addExpense": showingAddExpense = true
            case "share": showingShare = true
            case "editGroup": showingEditGroup = true
            case "editExpense":
                if let first = allExpenses.first { editingExpense = first }
            case "calendar":
                demoOpenCalendar = true
            case "templates":
                demoOpenTemplates = true
            case "stats":
                demoOpenStats = true
            default: break
            }
        }
        .navigationDestination(isPresented: $demoOpenCalendar) {
            SheetCalendarView(record: record)
        }
        .navigationDestination(isPresented: $demoOpenTemplates) {
            TemplateListView(record: record)
        }
        .navigationDestination(isPresented: $demoOpenStats) {
            StatsView(record: record)
        }
    }

    // MARK: - Components

    private var emptyStateInitial: some View {
        ContentUnavailableView(
            "支出がありません",
            systemImage: "yensign.circle",
            description: Text("右下の + から最初の取引を追加してください。")
        )
    }

    private var emptyStateFiltered: some View {
        ContentUnavailableView.search(text: searchText)
    }

    private var sectionedList: some View {
        LazyVStack(spacing: 16) {
            ForEach(groupedByDay(), id: \.key) { section in
                VStack(spacing: 6) {
                    DateHeaderView(label: section.dayLabel,
                                   net: section.dayNet,
                                   currency: record.resolvedDefaultCurrencyCode,
                                   tint: record.tint)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(section.value.enumerated()), id: \.element.objectID) { idx, expense in
                            Button {
                                editingExpense = expense
                            } label: {
                                ExpenseRowView(expense: expense)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { editingExpense = expense } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                                if expense.generatedFromRuleID != nil {
                                    Button {
                                        editingRule = expense.relatedRule
                                    } label: {
                                        Label("定期項目を編集", systemImage: "repeat")
                                    }
                                }
                                Button { duplicate(expense) } label: {
                                    Label("複製", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    viewContext.delete(expense)
                                    PersistenceController.shared.save()
                                    Haptics.warning()
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                            if idx < section.value.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
        }
    }

    private var categoryPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedCategory = nil
                } label: {
                    Text("すべて")
                        .font(.caption.weight(selectedCategory == nil ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selectedCategory == nil ? record.tint.opacity(0.18) : Color(.tertiarySystemBackground))
                        )
                        .foregroundStyle(selectedCategory == nil ? record.tint : .primary)
                }
                .buttonStyle(.plain)

                ForEach(usedCategories, id: \.objectID) { cat in
                    Button {
                        selectedCategory = (selectedCategory?.objectID == cat.objectID) ? nil : cat
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: cat.displaySymbol)
                            Text(cat.displayName)
                        }
                        .font(.caption.weight(selectedCategory?.objectID == cat.objectID ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selectedCategory?.objectID == cat.objectID ? cat.tint.opacity(0.22) : Color(.tertiarySystemBackground))
                        )
                        .foregroundStyle(selectedCategory?.objectID == cat.objectID ? cat.tint : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var floatingBottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("検索", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Capsule().fill(.regularMaterial))

            Button {
                showingAddExpense = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(record.tint.gradient))
                    .shadow(color: record.tint.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private struct DaySection {
        let key: String
        let dayLabel: String
        let dayNet: Decimal
        let value: [Expense]
    }

    private func groupedByDay() -> [DaySection] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filteredExpenses) { exp -> Date in
            cal.startOfDay(for: exp.date ?? .now)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日 (E)"

        let target = record.resolvedDefaultCurrencyCode
        let fx = FXRatesService.shared

        let sections = dict.map { (day, items) -> DaySection in
            let label = formatter.string(from: day)
            var net: Decimal = 0
            for e in items {
                let amt = fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal
                net += (e.kind == .income) ? amt : -amt
            }
            let key = ISO8601DateFormatter().string(from: day)
            return DaySection(key: key, dayLabel: label, dayNet: net, value: items)
        }
        return sections.sorted { $0.key > $1.key }
    }

    private var usedCategories: [ExpenseCategory] {
        var seen: Set<NSManagedObjectID> = []
        var result: [ExpenseCategory] = []
        for exp in allExpenses {
            if let cat = exp.category, !seen.contains(cat.objectID) {
                seen.insert(cat.objectID)
                result.append(cat)
            }
        }
        return result.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func duplicate(_ expense: Expense) {
        let pc = PersistenceController.shared
        let copy = Expense(context: viewContext)

        // 1) 親シートと同じストアに先に割り当てる
        let parentSheet = expense.sheet
        let parentStore: NSPersistentStore? = parentSheet?.objectID.persistentStore
        if let store = parentStore {
            viewContext.assign(copy, to: store)
        }

        // 2) スカラー値
        copy.title = expense.title
        copy.amount = expense.amount
        copy.kindRaw = expense.kindRaw
        copy.currencyCode = expense.currencyCode
        copy.categoryRaw = expense.categoryRaw
        copy.paidBy = expense.paidBy
        copy.payerProfileID = expense.payerProfileID
        copy.date = .now
        copy.note = expense.note
        copy.createdAt = .now

        // 3) 関係 (同一ストア内のみ)
        copy.sheet = parentSheet
        if let cat = expense.category,
           cat.objectID.persistentStore == parentStore {
            copy.category = cat
        }
        pc.save()
        Haptics.success()
    }
}

// MARK: - Summary Card

private struct SummaryCard: View {
    @ObservedObject var record: ExpenseSheet
    @Binding var period: SheetDetailView.Period
    let selectedCategory: ExpenseCategory?
    @ObservedObject private var fx = FXRatesService.shared

    /// 子 Expense の編集 (amount 変更等) は ExpenseSheet の objectWillChange を発火させないため、
    /// `record.expenses` 経由で集計すると view が再描画されない。
    /// @FetchRequest を直接観測することで、expense 単位の変更でも合計表示が即時更新される。
    @FetchRequest private var expenses: FetchedResults<Expense>

    init(record: ExpenseSheet, period: Binding<SheetDetailView.Period>, selectedCategory: ExpenseCategory? = nil) {
        self.record = record
        self._period = period
        self.selectedCategory = selectedCategory
        self._expenses = FetchRequest<Expense>(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    private var code: String { record.resolvedDefaultCurrencyCode }

    private func totals() -> (expense: Decimal, income: Decimal, missing: Set<String>) {
        let cal = Calendar.current
        let now = Date()
        let periodFilter: (Expense) -> Bool
        switch period {
        case .thisMonth:
            periodFilter = { cal.isDate($0.date ?? .distantPast, equalTo: now, toGranularity: .month) }
        case .lastMonth:
            guard let lm = cal.date(byAdding: .month, value: -1, to: now) else { return (.zero, .zero, []) }
            periodFilter = { cal.isDate($0.date ?? .distantPast, equalTo: lm, toGranularity: .month) }
        case .thisYear:
            periodFilter = { cal.isDate($0.date ?? .distantPast, equalTo: now, toGranularity: .year) }
        case .all:
            periodFilter = { _ in true }
        }
        let categoryID = selectedCategory?.objectID
        let target = code
        var expenseSum: Decimal = 0
        var incomeSum: Decimal = 0
        var missing: Set<String> = []
        for e in expenses where periodFilter(e) {
            if let categoryID, e.category?.objectID != categoryID { continue }
            let from = e.resolvedCurrencyCode
            guard let converted = fx.convert(e.amountDecimal, from: from, to: target) else {
                missing.insert(from)
                continue
            }
            switch e.kind {
            case .expense: expenseSum += converted
            case .income:  incomeSum += converted
            }
        }
        return (expenseSum, incomeSum, missing)
    }

    var body: some View {
        let t = totals()
        let net = t.income - t.expense
        let tint = record.tint
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Menu {
                    ForEach(SheetDetailView.Period.allCases) { p in
                        Button {
                            period = p
                        } label: {
                            HStack {
                                Text(p.label)
                                if p == period { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(period.label)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(record.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(record.tint.opacity(0.18)))
                }
                if let cat = selectedCategory {
                    HStack(spacing: 4) {
                        Image(systemName: cat.displaySymbol)
                            .font(.caption2)
                        Text(cat.displayName)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(cat.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(cat.tint.opacity(0.18)))
                }
                Spacer()
                ShareStatusBadge(record: record)
            }

            VStack(spacing: 4) {
                Text(CurrencyCatalog.format(net, code: code))
                    .font(.system(size: 38, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 24) {
                    Label {
                        Text(CurrencyCatalog.format(t.expense, code: code))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "minus.circle")
                    }
                    .foregroundStyle(.secondary)

                    Label {
                        Text(CurrencyCatalog.format(t.income, code: code))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "plus.circle")
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            // 月予算の進捗バー (今月 + カテゴリ未選択時のみ)
            if period == .thisMonth, selectedCategory == nil,
               let budget = record.monthlyBudgetDecimal {
                budgetProgress(spent: t.expense, budget: budget)
            }

            if !t.missing.isEmpty {
                Label("\(t.missing.sorted().joined(separator: ", ")) のレート未取得", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if hasMultipleCurrencies, let date = fx.lastRateDate {
                Label("為替: \(date) 基準", systemImage: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(tint.opacity(0.18))
        )
    }

    private var hasMultipleCurrencies: Bool {
        Set(expenses.map { $0.resolvedCurrencyCode }).count > 1
    }

    /// 月予算の進捗バー。
    /// - 80% 未満: アクセントカラー
    /// - 80% 以上 100% 未満: オレンジ
    /// - 100% 以上 (= 超過): 赤、超過分の表示も追加
    @ViewBuilder
    private func budgetProgress(spent: Decimal, budget: Decimal) -> some View {
        let ratio = NSDecimalNumber(decimal: spent / budget).doubleValue
        let clamped = max(0, min(1, ratio))
        let isOver = spent > budget
        let color: Color = isOver ? .red : (ratio >= 0.8 ? .orange : record.tint)
        let remaining = budget - spent

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("月予算", systemImage: "target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isOver {
                    Text("超過 \(CurrencyCatalog.format(-remaining, code: code))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.red)
                } else {
                    Text("残り \(CurrencyCatalog.format(remaining, code: code))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemBackground))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(CurrencyCatalog.format(spent, code: code)) / \(CurrencyCatalog.format(budget, code: code))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Date Section Header

private struct DateHeaderView: View {
    let label: String
    let net: Decimal
    let currency: String
    let tint: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Spacer()
            Text(formattedNet)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint))
        }
    }

    private var formattedNet: String {
        let abs = net.magnitude
        let sign: String
        if net == 0 { sign = "" }
        else if net > 0 { sign = "+" }
        else { sign = "-" }
        return sign + CurrencyCatalog.format(abs, code: currency)
    }
}

// MARK: - Expense Row

private struct ExpenseRowView: View {
    @ObservedObject var expense: Expense

    /// 支払/受取の人がいればカテゴリアイコンの右下にアバターを重ねる。
    /// (居なければカテゴリアイコンのみ)
    @ViewBuilder
    private var categoryIconWithPayer: some View {
        let payerName = expense.displayPaidBy
        ZStack(alignment: .bottomTrailing) {
            CategoryIconView(expense: expense, size: 36)
            if !payerName.isEmpty {
                PayerAvatar(
                    member: expense.resolvedPayer,
                    participantProfile: expense.resolvedParticipantProfile,
                    fallbackName: payerName,
                    fallbackColorHex: "#8E8E93",
                    fallbackPhoto: nil,
                    size: 18
                )
                .overlay(
                    Circle().stroke(Color(.systemBackground), lineWidth: 2)
                )
                .offset(x: 4, y: 4)
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            categoryIconWithPayer

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                if showSubtitle {
                    HStack(spacing: 6) {
                        let displayName = expense.displayPaidBy
                        if !displayName.isEmpty {
                            // アバターはカテゴリアイコンに重ねて表示しているので、
                            // 字幕には名前のみ出す
                            Text(displayName)
                                .foregroundStyle(expense.payerTint)
                        }
                        if let note = expense.note, !note.isEmpty {
                            if !displayName.isEmpty { Text("·").foregroundStyle(.secondary) }
                            Text(note)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if expense.generatedFromRuleID != nil {
                        Image(systemName: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(expense.formattedSignedAmount)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                if expense.resolvedCurrencyCode != (expense.sheet?.resolvedDefaultCurrencyCode ?? "JPY") {
                    Text(expense.resolvedCurrencyCode)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var showSubtitle: Bool {
        !(expense.paidBy?.isEmpty ?? true) || (expense.note?.isEmpty == false)
    }
}

//
//  SheetDetailView.swift
//  Expenso
//

import SwiftUI
import CoreData
import CustomPicker

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

    /// 並び替えの「軸」。方向 (asc/desc) は `sortAscending` で別管理。
    /// `CustomPicker.Item` プロトコル準拠 — Menu 内で軸選択 + 昇順/降順トグルが
    /// 一体化された UI を出すために、`label` (軸名) / `firstLabel` (asc 時の説明) /
    /// `secondLabel` (desc 時の説明) を提供する。
    enum SortField: String, CaseIterable, Hashable, Item {
        case date
        case amount

        var label: String {
            switch self {
            case .date:   "追加"
            case .amount: "金額"
            }
        }
        var firstLabel: String {  // 昇順時
            switch self {
            case .date:   "古い順"
            case .amount: "低い順"
            }
        }
        var secondLabel: String { // 降順時
            switch self {
            case .date:   "新しい順"
            case .amount: "高い順"
            }
        }
    }

    @State private var period: Period = .thisMonth
    @State private var showingAddExpense = false
    @State private var showingCSVImport = false
    @State private var showingShare = false
    @State private var editingExpense: Expense?
    @State private var editingRule: RecurringRule?
    @State private var showingEditGroup = false
    @State private var pendingDeleteExpense: Expense?
    @State private var searchText: String = ""
    @State private var selectedCategory: ExpenseCategory?
    @State private var demoOpenCalendar: Bool = false
    @State private var demoOpenTemplates: Bool = false
    @State private var exportPaywall: Bool = false
    @State private var lockPaywall: Bool = false
    @State private var showingSetPassword: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var showingLeaveConfirm: Bool = false
    @State private var exportShareItem: ExportShareItem?
    @Environment(\.dismiss) private var dismiss
    @State private var demoOpenStats: Bool = false
    @State private var demoOpenChat: Bool = false
    /// AddExpenseView から「定期項目を編集」が押された時にセットされる。
    /// シートが閉じきった後で `recurringListAutoEdit` に流して RecurringListView へ push する。
    @State private var pendingEditRule: RecurringRule?
    @State private var showRecurringListAutoEdit: Bool = false
    @State private var recurringListAutoEdit: RecurringRule?
    @AppStorage("expenseSortField") private var sortFieldRaw: String = SortField.date.rawValue
    /// `true` = 昇順 (古い順 / 少ない順), `false` = 降順 (新しい順 / 多い順)。
    /// デフォルトは降順 = 新しい順。
    @AppStorage("expenseSortAscending") private var sortAscending: Bool = false

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

    private var sortField: SortField {
        SortField(rawValue: sortFieldRaw) ?? .date
    }

    private var sortFieldBinding: Binding<SortField> {
        Binding(
            get: { self.sortField },
            set: { self.sortFieldRaw = $0.rawValue }
        )
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
        switch (sortField, sortAscending) {
        case (.date, true):    list.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        case (.date, false):   list.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case (.amount, true):  list.sort { $0.amountDecimal < $1.amountDecimal }
        case (.amount, false): list.sort { $0.amountDecimal > $1.amountDecimal }
        }
        return list
    }

    var body: some View {
        List {
            Section {
                SummaryCard(
                    record: record,
                    period: $period,
                    selectedCategory: selectedCategory,
                    searchQuery: searchText.trimmingCharacters(in: .whitespaces)
                )
            }
            .listSectionSeparator(.hidden)

                if !allExpenses.isEmpty {
                    categoryPills
                        .listSectionSeparator(.hidden)
                }

                if allExpenses.isEmpty {
                    emptyStateInitial
                } else if filteredExpenses.isEmpty {
                    emptyStateFiltered
                } else {
                    sectionedList
                }
        }
        .listStyle(.plain)
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // iOS 26: 検索バーは bottomBar の DefaultToolbarItem に置き、`+` を ToolbarItem で
        // 並列に並べる。ToolbarSpacer で間を空ける。
        // (Liquid Glass デザインの推奨パターン:
        //  https://qiita.com/RS6/items/2f55281499ef7bad96b2)
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("支出、収入を検索"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingShare = true
                } label: {
                    Image(systemName: record.isOwnedByCurrentUser ? "person.crop.circle.badge.plus" : "person.2.fill")
                }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(role: .confirm) {
                    showingAddExpense = true
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .tint(record.tint)
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
                        Label("統計", systemImage: "chart.pie.fill")
                    }
                    if SheetAIChat.isAvailable {
                        NavigationLink {
                            SheetAIChatView(record: record)
                        } label: {
                            Label("AI チャット", systemImage: "sparkles.rectangle.stack")
                        }
                    }
                    Divider()
                    // CustomPicker: 軸選択 + 昇順/降順トグルが 1 つの Menu Section に
                    // まとまる。選択軸の行は Toggle 化されて asc/desc を切替できる。
                    CustomPickerView(
                        selection: sortFieldBinding,
                        isSortAscending: $sortAscending,
                        title: "並び順"
                    )
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
                    // ロック設定はオーナーのみ。参加者 (= 非オーナー) はロック解除画面で
                    // パスワードを入れて閲覧することしかできない。
                    if record.isOwnedByCurrentUser {
                        Button {
                            if PurchaseManager.shared.isPremium {
                                showingSetPassword = true
                            } else {
                                lockPaywall = true
                                Haptics.warning()
                            }
                        } label: {
                            if SheetLockManager.shared.hasPassword(for: record) {
                                Label("ロック設定", systemImage: "lock.fill")
                            } else {
                                Label("シートをロック", systemImage: "lock")
                            }
                        }
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
                    Divider()
                    Button {
                        startExport(.csv)
                    } label: {
                        Label("CSV にエクスポート", systemImage: "doc.text")
                    }
                    Button {
                        startExport(.pdf)
                    } label: {
                        Label("PDF レポート", systemImage: "doc.richtext")
                    }
                    Button {
                        showingCSVImport = true
                    } label: {
                        Label("CSV を取り込む", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    // 削除/離脱はオーナー or 参加者で分岐
                    if record.isOwnedByCurrentUser {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("シートを削除", systemImage: "trash")
                        }
                    } else {
                        Button(role: .destructive) {
                            showingLeaveConfirm = true
                        } label: {
                            Label("このシートから離脱", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView(record: record)
        }
        .sheet(isPresented: $showingCSVImport) {
            CSVImportView(sheet: record)
        }
        .sheet(isPresented: $exportPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $lockPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showingSetPassword) {
            NavigationStack {
                SetSheetPasswordView(record: record)
            }
        }
        .sheet(item: $exportShareItem) { item in
            // CSV / PDF をまずプレビュー表示 → ユーザーが内容確認した上で
            // 右上の共有ボタンから「ファイルに保存」「AirDrop」「印刷」等を選ぶ。
            QuickLookPreview(url: item.url)
        }
        .sheet(isPresented: $showingShare) {
            CloudSharingView(record: record)
        }
        .alert("シートを削除しますか?", isPresented: $showingDeleteConfirm) {
            Button("削除", role: .destructive) {
                Task { @MainActor in
                    viewContext.delete(record)
                    PersistenceController.shared.save()
                    Haptics.warning()
                    dismiss()
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("「\(record.displayName)」とこのシートの全ての支出データが完全に削除されます。共有している場合は参加者からも見えなくなります。この操作は取り消せません。")
        }
        .alert("このシートから離脱しますか?", isPresented: $showingLeaveConfirm) {
            Button("離脱", role: .destructive) {
                Task { @MainActor in
                    try? await ShareCoordinator.shared.leaveSharedSheet(record)
                    Haptics.warning()
                    dismiss()
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("「\(record.displayName)」がこの端末から消えます。オーナーや他の参加者のデータは残ります。")
        }
        .sheet(item: $editingExpense, onDismiss: {
            // 「定期項目を編集」経由で閉じた時だけ、RecurringListView に
            // 遷移して該当 Rule の編集シートを自動で開く。
            if let rule = pendingEditRule {
                pendingEditRule = nil
                recurringListAutoEdit = rule
                showRecurringListAutoEdit = true
            }
        }) { expense in
            AddExpenseView(expense: expense, onEditRule: { rule in
                pendingEditRule = rule
            })
        }
        .sheet(item: $editingRule) { rule in
            EditRecurringRuleView(mode: .edit(rule: rule))
        }
        .sheet(isPresented: $showingEditGroup) {
            EditSheetView(record: record)
        }
        .confirmationDialog(
            "この支出を削除しますか?",
            isPresented: Binding(
                get: { pendingDeleteExpense != nil },
                set: { if !$0 { pendingDeleteExpense = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteExpense
        ) { expense in
            Button("削除する", role: .destructive) {
                viewContext.delete(expense)
                PersistenceController.shared.save()
                Haptics.warning()
                pendingDeleteExpense = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingDeleteExpense = nil
            }
        } message: { expense in
            Text("「\(expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle)」を削除します。元に戻せません。")
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
            case "chat":
                demoOpenChat = true
            default: break
            }
        }
        .navigationDestination(isPresented: $showRecurringListAutoEdit) {
            RecurringListView(record: record, autoEditRule: recurringListAutoEdit)
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
        .navigationDestination(isPresented: $demoOpenChat) {
            SheetAIChatView(record: record)
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
            ForEach(groupedByDay(), id: \.key) { section in
                Section {
                        ForEach(Array(section.value.enumerated()), id: \.element.objectID) { idx, expense in
                            Button {
                                editingExpense = expense
                            } label: {
                                ExpenseRowView(expense: expense)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteExpense = expense
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                                Button {
                                    duplicate(expense)
                                } label: {
                                    Label("複製", systemImage: "doc.on.doc")
                                }
                                .tint(.blue)
                            }
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
                                    pendingDeleteExpense = expense
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                } header: {
                    DateHeaderView(label: section.dayLabel,
                                   net: section.dayNet,
                                   currency: record.resolvedDefaultCurrencyCode,
                                   tint: record.tint)
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

    /// CSV / PDF エクスポートのエントリ。Premium で gate して、
    /// 通れば一時ファイルを作って `ShareSheet` で共有する。
    private func startExport(_ kind: ExportKind) {
        guard PurchaseManager.shared.isPremium else {
            exportPaywall = true
            Haptics.warning()
            return
        }
        let url: URL?
        switch kind {
        case .csv: url = SheetExporter.writeCSV(for: record)
        case .pdf: url = SheetExporter.writePDF(for: record)
        }
        if let url {
            exportShareItem = ExportShareItem(url: url, kind: kind)
            Haptics.success()
        }
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
        copy.paidBy = nil
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
    /// 親 view (SheetDetailView) の searchText (trimmed)。空でなければ
    /// 集計を検索ヒットに絞る + ヘッダーを「検索: \"...\" • N 件」表示に切替。
    let searchQuery: String
    @ObservedObject private var fx = FXRatesService.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 子 Expense の編集 (amount 変更等) は ExpenseSheet の objectWillChange を発火させないため、
    /// `record.expenses` 経由で集計すると view が再描画されない。
    /// @FetchRequest を直接観測することで、expense 単位の変更でも合計表示が即時更新される。
    @FetchRequest private var expenses: FetchedResults<Expense>

    init(
        record: ExpenseSheet,
        period: Binding<SheetDetailView.Period>,
        selectedCategory: ExpenseCategory? = nil,
        searchQuery: String = ""
    ) {
        self.record = record
        self._period = period
        self.selectedCategory = selectedCategory
        self.searchQuery = searchQuery
        self._expenses = FetchRequest<Expense>(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    private var isSearching: Bool { !searchQuery.isEmpty }

    private var code: String { record.resolvedDefaultCurrencyCode }

    private func totals() -> (expense: Decimal, income: Decimal, missing: Set<String>, hitCount: Int) {
        let cal = Calendar.current
        let now = Date()
        let periodFilter: (Expense) -> Bool
        // 検索中は期間フィルタを外す (= シート全体から検索) — 検索結果が
        // 当月外にあると 0 件と思われる UX を避ける。
        if isSearching {
            periodFilter = { _ in true }
        } else {
            switch period {
            case .thisMonth:
                periodFilter = { cal.isDate($0.date ?? .distantPast, equalTo: now, toGranularity: .month) }
            case .lastMonth:
                guard let lm = cal.date(byAdding: .month, value: -1, to: now) else { return (.zero, .zero, [], 0) }
                periodFilter = { cal.isDate($0.date ?? .distantPast, equalTo: lm, toGranularity: .month) }
            case .thisYear:
                periodFilter = { cal.isDate($0.date ?? .distantPast, equalTo: now, toGranularity: .year) }
            case .all:
                periodFilter = { _ in true }
            }
        }
        let categoryID = selectedCategory?.objectID
        let target = code
        let q = searchQuery.lowercased()
        var expenseSum: Decimal = 0
        var incomeSum: Decimal = 0
        var missing: Set<String> = []
        var hitCount = 0
        for e in expenses where periodFilter(e) {
            if let categoryID, e.category?.objectID != categoryID { continue }
            if !q.isEmpty {
                let matches = e.displayTitle.lowercased().contains(q)
                    || e.displayPaidBy.lowercased().contains(q)
                    || (e.note ?? "").lowercased().contains(q)
                if !matches { continue }
            }
            hitCount += 1
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
        return (expenseSum, incomeSum, missing, hitCount)
    }

    var body: some View {
        let t = totals()
        let net = t.income - t.expense
        let budget = record.monthlyBudgetDecimal
        let showBudgetMetrics = !isSearching && period == .thisMonth
            && selectedCategory == nil && budget != nil
        VStack(alignment: .leading, spacing: 18) {
            // Header: 期間・シート名 + 共有バッジ + カテゴリ pill
            topHeader

            // 大型の支出合計
            mainExpense(t.expense)

            Divider()

            // メトリクス列 (収入 / 残予算 / 収支)
            metricsRow(income: t.income, expense: t.expense, net: net, budget: budget,
                       showRemaining: showBudgetMetrics)

            // 月予算プログレスバー
            if showBudgetMetrics, let budget {
                cleanBudgetBar(spent: t.expense, budget: budget)
            }

            // 為替警告
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
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: - New clean UI components

    private var topHeader: some View {
        HStack(spacing: 8) {
            if isSearching {
                searchPill
            } else {
                periodMenuLabel
            }
            if let cat = selectedCategory {
                categoryPill(cat)
            }
            Spacer()
            ShareStatusBadge(record: record)
        }
    }

    /// "2026年11月 · Tento" 形式のメニュー (= 期間切替トリガ)。
    /// シート名はサブテキストとして同じ行に出す。
    private var periodMenuLabel: some View {
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
            HStack(spacing: 6) {
                Text(periodHeaderLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// 期間のヘッダー表示 ("2026年11月" / "先月" / "全期間" / "カスタム")
    private var periodHeaderLabel: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy年M月"
        switch period {
        case .thisMonth: return df.string(from: .now)
        case .lastMonth:
            let last = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
            return df.string(from: last)
        case .thisYear:
            let yf = DateFormatter()
            yf.locale = Locale(identifier: "ja_JP")
            yf.dateFormat = "yyyy年"
            return yf.string(from: .now)
        case .all: return "全期間"
        }
    }

    /// 期間に応じた支出キャプション
    private var expenseCaption: String {
        switch period {
        case .thisMonth: "今月の支出"
        case .lastMonth: "先月の支出"
        case .thisYear:  "今年の支出"
        case .all:       "全期間の支出"
        }
    }

    private func mainExpense(_ expense: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CurrencyCatalog.format(expense, code: code))
                .font(.system(size: 56, weight: .bold, design: .default).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: doubleValue(expense)))
                .animation(.snappy, value: expense)
            Text(expenseCaption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 3 (or 2) 列のメトリクス。残予算は今月+予算設定時のみ。
    private func metricsRow(income: Decimal, expense: Decimal, net: Decimal, budget: Decimal?, showRemaining: Bool) -> some View {
        let remaining = (budget ?? 0) - expense
        return HStack(alignment: .top, spacing: 12) {
            metricColumn(
                label: "収入",
                value: CurrencyCatalog.format(income, code: code),
                dotStyle: .filled(.green),
                valueColor: .primary
            )
            if showRemaining {
                metricColumn(
                    label: "残予算",
                    value: CurrencyCatalog.format(remaining, code: code),
                    dotStyle: .filled(remaining < 0 ? .red : .primary),
                    valueColor: remaining < 0 ? .red : .primary
                )
            }
            metricColumn(
                label: "収支",
                value: (net >= 0 ? "+" : "") + CurrencyCatalog.format(net, code: code),
                dotStyle: .outline,
                valueColor: net > 0 ? .green : (net < 0 ? .red : .primary)
            )
        }
    }

    private enum DotStyle {
        case filled(Color)
        case outline
    }

    private func metricColumn(label: String, value: String, dotStyle: DotStyle, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                metricDot(dotStyle)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metricDot(_ style: DotStyle) -> some View {
        switch style {
        case .filled(let color):
            Circle().fill(color).frame(width: 8, height: 8)
        case .outline:
            Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 8, height: 8)
        }
    }

    /// 新しい予算プログレスバー (左: 予算金額 / 右: %、下: capsule バー)
    @ViewBuilder
    private func cleanBudgetBar(spent: Decimal, budget: Decimal) -> some View {
        let ratio = NSDecimalNumber(decimal: spent / budget).doubleValue
        let clamped = max(0, min(1, ratio))
        let isOver = spent > budget
        let color: Color = isOver ? .red : (ratio >= 0.8 ? .orange : .primary)
        VStack(spacing: 8) {
            HStack {
                Text("予算 \(CurrencyCatalog.format(budget, code: code))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((ratio * 100).rounded())) %")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 4)
        }
    }

    /// `Decimal` をロール表示用 `Double` に。`Decimal` は直接 `numericText(value:)`
    /// に渡せないので Double に変換する。±1e15 を超える金額は誤差が出るが、
    /// 家計簿の合計には十分な精度。
    private func doubleValue(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue
    }

    /// 集計カードのヘッダー (期間 pill + カテゴリ pill + 共有バッジ)。
    /// 1 行に収まらなくなる AX では、pill 群と共有バッジを縦 2 段に分ける。
    @ViewBuilder
    private var summaryHeader: some View {
        // 検索中は期間 pill の代わりに「検索: \"q\" • N 件」 pill を出す。
        // (period は検索終了後に元の値で復活)
        let leadingPill = AnyView(isSearching ? AnyView(searchPill) : AnyView(periodPill))

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    leadingPill
                    if let cat = selectedCategory {
                        categoryPill(cat)
                    }
                    Spacer()
                }
                HStack {
                    Spacer()
                    ShareStatusBadge(record: record)
                }
            }
        } else {
            HStack {
                leadingPill
                if let cat = selectedCategory {
                    categoryPill(cat)
                }
                Spacer()
                ShareStatusBadge(record: record)
            }
        }
    }

    private var searchPill: some View {
        let count = totals().hitCount
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.bold))
            Text("\"\(searchQuery)\" • \(count) 件")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(record.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(record.tint.opacity(0.18)))
    }

    private var periodPill: some View {
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
    }

    private func categoryPill(_ cat: ExpenseCategory) -> some View {
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

    /// 支出 / 収入の内訳行。AX サイズでは横一列に収まらないので、
    /// `AnyLayout` で V/H を切替 (WWDC24 推奨パターン)。
    @ViewBuilder
    private func expenseIncomeBreakdown(expense: Decimal, income: Decimal) -> some View {
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 24))

        layout {
            Label {
                Text(CurrencyCatalog.format(expense, code: code))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: doubleValue(expense)))
                    .animation(.snappy, value: expense)
            } icon: {
                Image(systemName: "minus.circle")
            }
            .foregroundStyle(.secondary)

            Label {
                Text(CurrencyCatalog.format(income, code: code))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: doubleValue(income)))
                    .animation(.snappy, value: income)
            } icon: {
                Image(systemName: "plus.circle")
            }
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .frame(
            maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
            alignment: .leading
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // AX サイズでは日付と日合計の pill が 1 行に収まらず、ラベルが
        // 切れたり pill がはみ出す。縦 2 段に分けて、合計 pill は右寄せ。
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                HStack {
                    Spacer()
                    netPill
                }
            }
        } else {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                netPill
            }
        }
    }

    private var netPill: some View {
        Text(formattedNet)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 個人専用シート (= 自分以外の参加者が居ない) かどうか。
    private var isSoloSheet: Bool {
        guard let sheet = expense.sheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return true }
        let myRN = UserProfileStore.shared.userRecordName ?? ""
        return !profiles.contains { p in
            let rn = p.recordName ?? ""
            return !rn.isEmpty && rn != myRN
        }
    }

    /// この支出の支払者 (or 受取者) が自分自身か。
    private var payerIsSelf: Bool {
        let store = UserProfileStore.shared
        if let pid = expense.payerProfileID, !pid.isEmpty,
           let myRN = store.userRecordName, !myRN.isEmpty {
            return pid == myRN
        }
        if let mid = expense.payerMemberID, mid == store.selfMemberID {
            return true
        }
        return false
    }

    /// 支払/受取の人がいればカテゴリアイコンの右下にアバターを重ねる。
    /// 個人専用シート + 自分払い の場合は出さない (= UI ノイズを避ける)。
    /// 過去の共有シート時代に他人が支払者だった支出は引き続きアバターを出す。
    @ViewBuilder
    private var categoryIconWithPayer: some View {
        let payerName = expense.displayPaidBy
        let showAvatar = !payerName.isEmpty && !(isSoloSheet && payerIsSelf)
        ZStack(alignment: .bottomTrailing) {
            CategoryIconView(expense: expense, size: 36)
            if showAvatar {
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

    @ViewBuilder
    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle)
                .font(.body)
                .foregroundStyle(.primary)
            if showSubtitle {
                HStack(spacing: 6) {
                    let rawName = expense.displayPaidBy
                    let displayName = (isSoloSheet && payerIsSelf) ? "" : rawName
                    if !displayName.isEmpty {
                        // 支払者の name text にはアバター背景色を使わない (= secondary に統一)。
                        // 背景色はアバター丸の塗りつぶしにだけ使うのが意図。
                        Text(displayName)
                            .foregroundStyle(.secondary)
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
    }

    @ViewBuilder
    private var amountAndCurrency: some View {
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

    var body: some View {
        // Dynamic Type が AX サイズに上がると 1 列に詰まったレイアウトが破綻する。
        // Apple Music の AX 表示にならって、ヘッダー行 (アイコン+金額) →
        // タイトル (全幅で wrap) → サブタイトル の 3 段に展開する。
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    categoryIconWithPayer
                    Spacer(minLength: 12)
                    amountAndCurrency
                }
                Text(expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showSubtitle {
                    accessibilitySubtitle
                }
            }
        } else {
            HStack(spacing: 12) {
                categoryIconWithPayer
                titleAndSubtitle
                Spacer()
                amountAndCurrency
            }
        }
    }

    /// AX 用のサブタイトル: 払った人 (色付き) と note を改行ありで縦に並べる。
    /// (通常レイアウトの 1 行 HStack と違い、長い note を切らない)
    @ViewBuilder
    private var accessibilitySubtitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            let displayName = expense.displayPaidBy
            if !displayName.isEmpty {
                Text(displayName)
                    .foregroundStyle(expense.payerTint)
            }
            if let note = expense.note, !note.isEmpty {
                Text(note)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showSubtitle: Bool {
        !(expense.paidBy?.isEmpty ?? true) || (expense.note?.isEmpty == false)
    }
}

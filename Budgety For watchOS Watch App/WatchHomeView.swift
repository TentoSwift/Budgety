//
//  WatchHomeView.swift
//  Budgety Watch
//
//  watchOS 版 Budgety のメインフロー。
//
//  ・ホームは TabView (ページ式): 横スワイプ / Crown でシート切替
//  ・各タブは WatchSheetPage = 今日の合計 + 月予算プログレス + 「追加」+ 直近
//  ・追加は Digital Crown で金額調整 (= WatchAddExpenseView)
//

import SwiftUI
import CoreData

struct WatchHomeView: View {
    @Environment(\.managedObjectContext) private var ctx
    @StateObject private var persistence = PersistenceController.shared

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)
        ],
        animation: .default
    )
    private var sheets: FetchedResults<ExpenseSheet>

    /// 直近で開いたシートを記憶 (= 次回起動時に直接そのシートを表示)。
    @AppStorage("watchSelectedSheetID") private var selectedSheetIDString: String = ""

    @State private var selectedSheetID: NSManagedObjectID?

    var body: some View {
        NavigationStack {
            Group {
                if sheets.isEmpty {
                    ContentUnavailableView(
                        "シートがありません",
                        systemImage: "tray",
                        description: Text("iPhone でシートを作成すると同期されます。")
                    )
                } else {
                    TabView(selection: $selectedSheetID) {
                        ForEach(sheets, id: \.objectID) { sheet in
                            WatchLockedSheetGate(sheet: sheet) {
                                WatchSheetPage(sheet: sheet)
                            }
                            .tag(Optional(sheet.objectID))
                        }
                    }
                    .tabViewStyle(.verticalPage)
                    .onChange(of: selectedSheetID) { _, new in
                        if let new {
                            selectedSheetIDString = new.uriRepresentation().absoluteString
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            ensureDefaultSheetIfNeeded()
            restoreSelectedSheet()
        }
        // CloudKit 初回同期完了時に再判定 (= 実機で「同期完了したらシート 0 件 → seed」用)
        .onChange(of: persistence.initialSyncComplete) { _, _ in
            ensureDefaultSheetIfNeeded()
            restoreSelectedSheet()
        }
    }

    /// 起動時に前回開いていたシートを復元。無ければ最初のシート。
    private func restoreSelectedSheet() {
        guard !sheets.isEmpty else { return }
        if !selectedSheetIDString.isEmpty,
           let url = URL(string: selectedSheetIDString),
           let id = ctx.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
           sheets.contains(where: { $0.objectID == id }) {
            selectedSheetID = id
        } else {
            selectedSheetID = sheets.first?.objectID
        }
    }

    /// シート / カテゴリが 1 つも無ければデフォルトを作る。
    /// 実機では CloudKit 初回同期完了を待ってから判定 (= iPhone のデータが
    /// 降ってくる前に seed して重複作成するのを防ぐ)。
    /// シミュレータでは CloudKit に繋がらないため即時 seed する。
    private func ensureDefaultSheetIfNeeded() {
        #if !targetEnvironment(simulator)
        // 実機: CloudKit 同期完了を待つ (= iPhone のシートが降りてくる)
        guard PersistenceController.shared.initialSyncComplete else { return }
        #endif

        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        req.fetchLimit = 1
        let existing = (try? ctx.fetch(req)) ?? []
        guard existing.isEmpty else { return }

        let sheet = ExpenseSheet(context: ctx)
        sheet.name = "家計簿"
        sheet.symbol = "yensign.circle.fill"
        sheet.colorHex = "#5B8DEF"
        sheet.defaultCurrencyCode = CurrencyCatalog.defaultCode
        sheet.createdAt = .now
        PersistenceController.seedDefaultCategories(for: sheet, in: ctx)
        try? ctx.save()
    }
}

// MARK: - Single Sheet Page (= TabView の 1 ページ)

private struct WatchSheetPage: View {
    let sheet: ExpenseSheet
    @Environment(\.managedObjectContext) private var ctx
    @State private var showingAdd: Bool = false
    @State private var pendingDeleteExpense: Expense?

    @FetchRequest private var expenses: FetchedResults<Expense>

    init(sheet: ExpenseSheet) {
        self.sheet = sheet
        _expenses = FetchRequest<Expense>(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
            predicate: NSPredicate(format: "sheet == %@", sheet),
            animation: .default
        )
    }

    private var todayExpenses: [Expense] {
        let dayStart = Calendar.current.startOfDay(for: Date())
        return expenses.filter { ($0.date ?? .distantPast) >= dayStart }
    }

    private var todayTotal: Decimal {
        todayExpenses
            .filter { $0.kind == .expense }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    private var monthExpenses: [Expense] {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return expenses.filter { ($0.date ?? .distantPast) >= monthStart }
    }

    private var monthTotal: Decimal {
        monthExpenses
            .filter { $0.kind == .expense }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    private var budgetProgress: Double? {
        guard let budget = sheet.monthlyBudgetDecimal, budget > 0 else { return nil }
        let used = NSDecimalNumber(decimal: monthTotal).doubleValue
        let total = NSDecimalNumber(decimal: budget).doubleValue
        return used / total
    }

    private var budgetExceeded: Bool {
        (budgetProgress ?? 0) > 1.0
    }

    var body: some View {
        List {
            Section {
                heroCard
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                addButton
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 4, trailing: 0))
            }
            if !expenses.isEmpty {
                Section {
                    ForEach(Array(expenses.prefix(6)), id: \.objectID) { expense in
                        NavigationLink {
                            WatchExpenseDetailView(expense: expense, sheet: sheet)
                        } label: {
                            recentRow(expense)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.12))
                        )
                        .listRowInsets(.init(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteExpense = expense
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("最近")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .listStyle(.plain)
        .containerBackground(sheet.tint.gradient, for: .tabView)
        .navigationTitle {
            (Text(Image(systemName: sheet.displaySymbol)) + Text(" \(sheet.displayName)"))
                .foregroundStyle(sheet.tint)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                WatchAddExpenseView(sheet: sheet)
            }
        }
        .alert(
            "削除しますか?",
            isPresented: Binding(
                get: { pendingDeleteExpense != nil },
                set: { if !$0 { pendingDeleteExpense = nil } }
            ),
            presenting: pendingDeleteExpense
        ) { expense in
            Button("削除", role: .destructive) {
                delete(expense)
                pendingDeleteExpense = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingDeleteExpense = nil
            }
        } message: { _ in
            Text("元に戻せません。")
        }
    }

    private func delete(_ e: Expense) {
        ctx.delete(e)
        try? ctx.save()
        WKInterfaceDevice.current().play(.success)
    }

    private var heroCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: sheet.displaySymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("今日")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(formatYen(todayTotal))
                .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy, value: todayTotal)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let p = budgetProgress {
                budgetBar(progress: p)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func budgetBar(progress: Double) -> some View {
        let displayProgress = min(1.0, progress)
        let exceeded = progress > 1.0
        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                    Capsule()
                        .fill(exceeded ? Color.red : Color.white)
                        .frame(width: geo.size.width * CGFloat(displayProgress))
                }
            }
            .frame(height: 5)
            HStack {
                Text("今月")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(exceeded ? Color.red : Color.white)
            }
        }
        .padding(.horizontal, 4)
    }

    private var addButton: some View {
        Button {
            showingAdd = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                Text("支出を追加")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(0.20))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ e: Expense) -> some View {
        HStack(spacing: 8) {
            Image(systemName: e.category?.symbol ?? "yensign.circle.fill")
                .foregroundStyle(.white)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(Color(hex: e.category?.colorHex ?? "#FFFFFF") ?? .white)
                )
            Text(displayTitle(e))
                .font(.caption2)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text(formatYen(e.amountDecimal))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private func displayTitle(_ e: Expense) -> String {
        if let t = e.title, !t.isEmpty { return t }
        if let c = e.category, let n = c.name, !n.isEmpty { return n }
        return "支出"
    }

    private func formatYen(_ d: Decimal) -> String {
        CurrencyCatalog.format(d, code: sheet.resolvedDefaultCurrencyCode)
    }
}

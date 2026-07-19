//
//  WatchHomeView.swift
//  Budgety Watch
//
//  watchOS 版 Budgety のメインフロー。
//
//  ・ホームはシート一覧 (List): タップでそのシートへ push 遷移
//  ・遷移先は WatchSheetPage = 今日の合計 + 月予算プログレス + 「追加」+ 直近
//  ・追加は Digital Crown で金額調整 (= WatchAddExpenseView)
//

import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct WatchHomeView: View {
    @Environment(\.managedObjectContext) private var ctx
    @StateObject private var lockManager = SheetLockManager.shared

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)
        ],
        animation: .default
    )
    private var sheets: FetchedResults<ExpenseSheet>

    @State private var path: [NSManagedObjectID] = []
    /// 前回開いていたシート (= 次回起動時にそこへ自動遷移)。
    @AppStorage("watchLastOpenedSheetURI") private var lastOpenedSheetURI: String = ""
    @State private var didRestorePath = false
    /// 共有シート受諾の成否を知らせるトースト。iOS の BudgetyApp と同じ仕組み。
    @State private var shareToast: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sheets.isEmpty {
                    ContentUnavailableView(
                        "シートがありません",
                        systemImage: "tray",
                        description: Text("iPhone でシートを作成すると同期されます。")
                    )
                } else {
                    let activeSheets = sheets.filter { !$0.archived }
                    let archivedSheets = sheets.filter { $0.archived }
                    List {
                        ForEach(activeSheets, id: \.objectID) { sheet in
                            NavigationLink(value: sheet.objectID) {
                                sheetRow(sheet)
                            }
                        }
                        if !archivedSheets.isEmpty {
                            Section("アーカイブ済み") {
                                ForEach(archivedSheets, id: \.objectID) { sheet in
                                    NavigationLink(value: sheet.objectID) {
                                        sheetRow(sheet)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("シート")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchProfileAvatar()
                }
            }
            .navigationDestination(for: NSManagedObjectID.self) { id in
                if let sheet = try? ctx.existingObject(with: id) as? ExpenseSheet {
                    WatchLockedSheetGate(sheet: sheet) {
                        WatchSheetPage(sheet: sheet)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let shareToast {
                Text(shareToast)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .shadow(radius: 4)
            }
        }
        // 共有シートの受諾結果 (BudgetyWatchAppDelegate が投稿) をトースト表示。
        .onReceive(NotificationCenter.default.publisher(for: .expensoShareAccepted)) { note in
            let title = (note.userInfo?["shareTitle"] as? String) ?? String(localized: "シート")
            showShareToast(String(localized: "「\(title)」に参加しました"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .expensoShareAcceptanceFailed)) { note in
            let message = (note.userInfo?["message"] as? String) ?? String(localized: "共有の受諾に失敗しました")
            showShareToast(message)
        }
        .onAppear { restoreLastOpenedSheetIfNeeded() }
        .onChange(of: sheets.count) { _, _ in restoreLastOpenedSheetIfNeeded() }
        .onChange(of: path) { oldPath, newPath in
            // 末尾のシート URI を覚えておき、次回起動時に復元する。
            lastOpenedSheetURI = newPath.last?.uriRepresentation().absoluteString ?? ""
            // 一覧に戻った (= path から外れた) シートを再ロックする。
            // pop アニメ完了後に行い、その間に開き直していたらスキップ
            // (表示中のシートを誤ってロックしないため)。
            let removed = Set(oldPath).subtracting(newPath)
            for id in removed {
                guard let sheet = try? ctx.existingObject(with: id) as? ExpenseSheet,
                      lockManager.hasPassword(for: sheet) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard !path.contains(id) else { return }
                    lockManager.lock(sheet)
                }
            }
        }
    }

    /// 前回開いていたシートへ起動時に 1 度だけ自動遷移する (iOS と同じ挙動)。
    /// シートがまだ同期されていなければ sheets.count の変化で再試行する。
    private func restoreLastOpenedSheetIfNeeded() {
        guard !didRestorePath else { return }
        guard !lastOpenedSheetURI.isEmpty, sheets.first != nil else { return }
        guard let coord = ctx.persistentStoreCoordinator,
              let url = URL(string: lastOpenedSheetURI),
              let objectID = coord.managedObjectID(forURIRepresentation: url),
              let _ = try? ctx.existingObject(with: objectID) as? ExpenseSheet
        else {
            // URI 不正 / 削除済 → 以後再試行しない
            didRestorePath = true
            return
        }
        path = [objectID]
        didRestorePath = true
    }

    /// 共有受諾トーストを表示し 3 秒後に自動で消す (iOS BudgetyApp.showToast と同じ)。
    private func showShareToast(_ message: String) {
        withAnimation { shareToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { shareToast = nil }
        }
    }

    /// シート一覧の 1 行 (アイコン + 名前 + 今月合計 + ロック表示)。
    private func sheetRow(_ sheet: ExpenseSheet) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(sheet.tint.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: sheet.displaySymbol)
                    .foregroundStyle(.white)
                    .font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(sheet.displayName)
                    .font(.body)
                    .lineLimit(1)
                // ロック中 (パスワードあり & 未解錠) のシートは合計を出さない。
                Text(lockManager.isUnlocked(sheet) ? monthlyLabel(for: sheet) : String(localized: "ロック中"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if lockManager.hasPassword(for: sheet) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 今月の支出合計を短く表示。
    private func monthlyLabel(for sheet: ExpenseSheet) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        let total = ((sheet.expenses as? Set<Expense>) ?? [])
            .filter { e in
                guard let d = e.date, e.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: d)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        // 完全仮想化 ON 時は今月の仮想 occurrence も合算 (OFF なら空)。
        let virtualTotal = RecurringOccurrenceService.virtualOccurrences(for: sheet, includeFuture: false)
            .filter { occ in
                guard occ.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: occ.date)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return String(localized: "今月 ") + CurrencyCatalog.format(total + virtualTotal, code: sheet.resolvedDefaultCurrencyCode)
    }

}

// MARK: - Single Sheet Page (= TabView の 1 ページ)

/// サマリーの収支に適用する期間 (iOS の Period の watch 版)。
private enum WatchPeriod: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, thisYear, all, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMonth: String(localized: "今月")
        case .lastMonth: String(localized: "先月")
        case .thisYear:  String(localized: "今年")
        case .all:       String(localized: "全期間")
        case .custom:    String(localized: "カスタム")
        }
    }

    /// カスタム期間は AppStorage に保存されるため enum からは読めない。
    /// 呼び出し側が保存済みの開始日・終了日を渡す。
    func contains(_ date: Date, customStart: Date, customEnd: Date) -> Bool {
        let cal = Calendar.current
        switch self {
        case .all:
            return true
        case .thisMonth:
            return cal.isDate(date, equalTo: .now, toGranularity: .month)
        case .lastMonth:
            guard let last = cal.date(byAdding: .month, value: -1, to: .now) else { return false }
            return cal.isDate(date, equalTo: last, toGranularity: .month)
        case .thisYear:
            return cal.isDate(date, equalTo: .now, toGranularity: .year)
        case .custom:
            // 日付単位の閉区間 (開始日の 0:00 〜 終了日の 23:59:59)。
            let lower = cal.startOfDay(for: customStart)
            let endDay = cal.startOfDay(for: customEnd)
            guard let upper = cal.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) else {
                return date >= lower
            }
            return date >= lower && date <= upper
        }
    }
}

/// サマリーの「期間」を選ぶシート。
/// Picker ではなくボタン行 + チェックマークで即時反映する。
/// 種類 (支出/収支/収入) は選ばせず、常に収支 + 内訳を表示する (iOS と同じ)。
private struct WatchSummaryOptionsView: View {
    @Binding var periodRaw: String
    /// カスタム期間の開始日・終了日 (timeIntervalSinceReferenceDate)。
    @Binding var customStart: Double
    @Binding var customEnd: Double
    @Environment(\.dismiss) private var dismiss

    /// Double(参照日時からの秒) の Binding を DatePicker 用の Binding<Date> に変換。
    private func dateBinding(_ raw: Binding<Double>) -> Binding<Date> {
        Binding(
            get: { Date(timeIntervalSinceReferenceDate: raw.wrappedValue) },
            set: { raw.wrappedValue = $0.timeIntervalSinceReferenceDate }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                // シートは期間選択専用になったのでセクション見出しは出さない
                // (タイトルが「期間」を兼ねる)。
                Section {
                    ForEach(WatchPeriod.allCases) { p in
                        optionRow(p.label, isOn: periodRaw == p.rawValue) {
                            periodRaw = p.rawValue
                        }
                    }
                    // カスタム選択時のみ開始日・終了日を編集する DatePicker を出す。
                    if periodRaw == WatchPeriod.custom.rawValue {
                        DatePicker(
                            "開始日",
                            selection: dateBinding($customStart),
                            displayedComponents: [.date]
                        )
                        DatePicker(
                            "終了日",
                            selection: dateBinding($customEnd),
                            displayedComponents: [.date]
                        )
                    }
                }
            }
            .navigationTitle("期間")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private func optionRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

private struct WatchSheetPage: View {
    let sheet: ExpenseSheet
    @Environment(\.managedObjectContext) private var ctx
    @State private var showingAdd: Bool = false
    /// 収支サマリーの期間 (端末に永続化・全シート共通)。
    @AppStorage("watchSummaryPeriod") private var periodRaw: String = WatchPeriod.thisMonth.rawValue
    private var period: WatchPeriod { WatchPeriod(rawValue: periodRaw) ?? .thisMonth }
    /// カスタム期間の開始日・終了日 (timeIntervalSinceReferenceDate)。既定は今日。全シート共通。
    @AppStorage("watchSummaryCustomStart") private var customStart: Double = Date().timeIntervalSinceReferenceDate
    @AppStorage("watchSummaryCustomEnd") private var customEnd: Double = Date().timeIntervalSinceReferenceDate
    private var customStartDate: Date { Date(timeIntervalSinceReferenceDate: customStart) }
    private var customEndDate: Date { Date(timeIntervalSinceReferenceDate: customEnd) }
    /// 種類・期間を選ぶシートの表示。
    @State private var showingSummaryOptions = false
    /// 空状態でツールバー + を指す矢印の上下アニメーション用。
    @State private var emptyArrowUp = false
    @State private var pendingDeleteExpense: Expense?
    /// 他メンバーのプロフィール写真が Public DB からロードされたら行を再描画する。
    @ObservedObject private var pub = PublicProfileSync.shared

    /// 共有シート (他メンバーあり) か。支払い者アバターはこの時だけ行に重ねる。
    private var isShared: Bool { sheet.hasAcceptedOtherMembers() }

    @FetchRequest private var expenses: FetchedResults<Expense>

    init(sheet: ExpenseSheet) {
        self.sheet = sheet
        _expenses = FetchRequest<Expense>(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
            predicate: NSPredicate(format: "sheet == %@", sheet),
            animation: .default
        )
    }

    /// ルールから算出した仮想 occurrence (完全仮想化フラグ OFF なら空)。
    private var virtualOccurrences: [RecurringOccurrence] {
        RecurringOccurrenceService.virtualOccurrences(for: sheet, includeFuture: false)
    }

    private var todayExpenses: [Expense] {
        let dayStart = Calendar.current.startOfDay(for: Date())
        return expenses.filter { ($0.date ?? .distantPast) >= dayStart }
    }

    private var todayTotal: Decimal {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let e = todayExpenses.filter { $0.kind == .expense }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let v = virtualOccurrences
            .filter { $0.kind == .expense && $0.date >= dayStart }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return e + v
    }

    private var monthExpenses: [Expense] {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return expenses.filter { ($0.date ?? .distantPast) >= monthStart }
    }

    private var monthTotal: Decimal {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let e = monthExpenses.filter { $0.kind == .expense }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let v = virtualOccurrences
            .filter { $0.kind == .expense && $0.date >= monthStart }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return e + v
    }

    /// 先月の支出合計 (実データ + 先月内の仮想 occurrence)。
    private var lastMonthTotal: Decimal {
        let cal = Calendar.current
        guard let last = cal.date(byAdding: .month, value: -1, to: Date()) else { return 0 }
        let e = expenses
            .filter { e in
                guard let d = e.date, e.kind == .expense else { return false }
                return cal.isDate(d, equalTo: last, toGranularity: .month)
            }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let v = virtualOccurrences
            .filter { $0.kind == .expense && cal.isDate($0.date, equalTo: last, toGranularity: .month) }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return e + v
    }

    /// 予算バーが対象とする月の支出合計 (今月/先月で切り替え)。
    private var selectedMonthExpenseTotal: Decimal {
        switch period {
        case .lastMonth: return lastMonthTotal
        default:         return monthTotal
        }
    }

    /// 選択期間内の種類別合計。実データ + 仮想 occurrence を合算する。
    private func periodTotal(_ kind: TransactionKind) -> Decimal {
        let inPeriod = expenses.filter { period.contains($0.date ?? .distantPast, customStart: customStartDate, customEnd: customEndDate) }
        let inPeriodVirtual = virtualOccurrences.filter { period.contains($0.date, customStart: customStartDate, customEnd: customEndDate) }
        return inPeriod.filter { $0.kind == kind }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
            + inPeriodVirtual.filter { $0.kind == kind }.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// 選択期間の収入合計。
    private var periodIncome: Decimal { periodTotal(.income) }
    /// 選択期間の支出合計。
    private var periodExpense: Decimal { periodTotal(.expense) }
    /// 選択期間の収支 (収入 - 支出)。ヒーローカードの大きな数字。
    private var periodNet: Decimal { periodIncome - periodExpense }

    /// 収支の表示。正なら符号付き ("+¥1,200")、負・0 はそのまま ("-¥3,150" / "¥0")。
    private var periodNetFormatted: String {
        if periodNet > 0 { return "+" + formatYen(periodNet) }
        return formatYen(periodNet)
    }

    private var budgetProgress: Double? {
        guard let budget = sheet.monthlyBudgetDecimal, budget > 0 else { return nil }
        let used = NSDecimalNumber(decimal: selectedMonthExpenseTotal).doubleValue
        let total = NSDecimalNumber(decimal: budget).doubleValue
        return used / total
    }

    private var budgetExceeded: Bool {
        (budgetProgress ?? 0) > 1.0
    }

    var body: some View {
        // タブ 1: サマリー (今月合計 + 「追加」ボタン)
        // タブ 2: 取引リスト (支出 + 収入。セクションヘッダーは無し)
        // .verticalPage で Digital Crown / 縦スワイプで切替。
        TabView {
            summaryTab.tag(0)
            transactionsTab.tag(1)
        }
        .tabViewStyle(.verticalPage)
        .containerBackground(sheet.tint.gradient, for: .navigation)
        .navigationTitle {
            Text(sheet.displayName)
                .foregroundStyle(sheet.tint)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 支出の追加はツールバーの + から (サマリー内のボタンは廃止)。
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                WatchAddExpenseView(sheet: sheet)
            }
        }
        .sheet(isPresented: $showingSummaryOptions) {
            WatchSummaryOptionsView(
                periodRaw: $periodRaw,
                customStart: $customStart,
                customEnd: $customEnd
            )
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

    // MARK: - Tabs

    /// 1 ページ目: 収支サマリー (期間ピッカー付き)。追加はツールバーの + から。
    @ViewBuilder
    private var summaryTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                heroCard
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    /// 2 ページ目: 全取引 (支出 + 収入)。セクションヘッダーは無し。
    @ViewBuilder
    private var transactionsTab: some View {
        let items: [LedgerItem] = Array(expenses).map { LedgerItem.expense($0) }
            + virtualOccurrences.map { LedgerItem.occurrence($0) }
        let sorted = items.sorted { $0.date > $1.date }
        return Group {
            if sorted.isEmpty {
                // 空状態: 右上のツールバー + を指す矢印を上下にアニメーションして
                // 「ここから追加できる」ことを視覚的に示す (説明文は出さない)。
                ZStack(alignment: .topTrailing) {
                    ContentUnavailableView(
                        "まだ記録がありません",
                        systemImage: "tray"
                    )
                    Image(systemName: "arrow.up")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .offset(y: emptyArrowUp ? -6 : 2)
                        .animation(
                            .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                            value: emptyArrowUp
                        )
                        .padding(.trailing, 10)
                        .onAppear { emptyArrowUp = true }
                        .onDisappear { emptyArrowUp = false }
                        .accessibilityLabel(Text("右上の + から記録できます。"))
                }
            } else {
                List {
                    ForEach(sorted) { item in
                        switch item {
                        case .expense(let expense):
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
                        case .occurrence(let occ):
                            // 仮想 occurrence (未実体化の定期分)。watch は表示のみ。
                            virtualRow(occ)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.white.opacity(0.08))
                                )
                                .listRowInsets(.init(top: 2, leading: 4, bottom: 2, trailing: 4))
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear { prefetchPayerPhotos(Array(expenses)) }
            }
        }
    }

    private var heroCard: some View {
        VStack(spacing: 6) {
            // 見出し: 常に「収支」(iOS の SummaryCard と同じく種類は選ばせない)
            HStack(spacing: 6) {
                Image(systemName: sheet.displaySymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("収支")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            // 期間ボタン (タップで期間の選択シートを開く)。ラベルは出さず
            // 現在の期間だけをコンパクトなカプセルで表示する。
            Button {
                showingSummaryOptions = true
            } label: {
                HStack(spacing: 4) {
                    Text(period.label)
                        .font(.caption2.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.20)))
            }
            .buttonStyle(.plain)
            // 選択期間の収支 (大きな数字・正なら符号付き)
            Text(periodNetFormatted)
                .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy, value: periodNet)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            // 内訳: "+ 収入" | "- 支出" (iOS の incomeExpenseSummaryRow と同じ形)。
            // 背景がグラデーションなので .secondary ではなく白の半透明で出す。
            HStack(spacing: 8) {
                Text("+ \(formatYen(periodIncome))")
                Text("|")
                    .foregroundStyle(.white.opacity(0.5))
                Text("- \(formatYen(periodExpense))")
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // 月予算バーは単月 (今月/先月) のときだけ (予算は月の支出に対するもの)
            if period == .thisMonth || period == .lastMonth, let p = budgetProgress {
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
                Text(period.label)
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

    private func recentRow(_ e: Expense) -> some View {
        HStack(spacing: 8) {
            // iOS の CategoryPayerIconView と同じ見た目: カテゴリアイコン円の
            // 右下に支払い者/受取者アバターを小さく重ねる。
            categoryPayerIcon(e)
            // タイトルと金額を縦並びに (狭い画面で折り返しが起きないよう)。
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(e))
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // 支出は "-", 収入は "+" を符号として表示。
                Text(e.formattedSignedAmount)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    /// カテゴリアイコン円 + 支払い者/受取者アバター (右下に重ね)。
    /// iOS の `CategoryPayerIconView` に相当する watch 版。共有シートで、かつ
    /// 「ソロ + 自分払い」でない時だけアバターを重ねる (= iOS と同じ出し分け)。
    @ViewBuilder
    private func categoryPayerIcon(_ e: Expense) -> some View {
        let pid = e.payerProfileID ?? ""
        let hasPayer = !pid.isEmpty || e.payerMemberID != nil || !(e.paidBy ?? "").isEmpty
        // ソロ (他メンバー無し) + 自分払いの時はアバターを出さない。
        let isSelf = pid.isEmpty
            ? true
            : UserProfileStore.shared.canonicalSelfIDs(forShare: nil).contains(pid)
        let showAvatar = hasPayer && !(!isShared && isSelf)
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: e.categorySymbol)
                .foregroundStyle(.white)
                // Dynamic Type で巨大化しないよう固定サイズに。
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(e.categoryTint.gradient)
                )
            if showAvatar {
                let info = sheet.memberDisplayInfo(for: pid)
                payerBadge(info)
                    // カテゴリアイコンと分けるため、背景色の縁取りを一回り敷く。
                    .background(
                        Circle()
                            .fill(sheet.tint)
                            .padding(-1.5)
                    )
                    .offset(x: 3, y: 3)
            }
        }
    }

    /// 行に重ねる小さな支払い者バッジ (写真 or 頭文字)。
    @ViewBuilder
    private func payerBadge(_ info: (name: String, colorHex: String, photoData: Data?)) -> some View {
        let color = Color(hex: info.colorHex) ?? .gray
        let badgeSize: CGFloat = 12
        #if canImport(UIKit)
        if let data = info.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: badgeSize, height: badgeSize)
                .clipShape(Circle())
        } else {
            payerInitial(name: info.name, color: color, size: badgeSize)
        }
        #else
        payerInitial(name: info.name, color: color, size: badgeSize)
        #endif
    }

    private func payerInitial(name: String, color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    /// 行に表示する支払い者の写真を Public DB からまとめて先読みする。
    private func prefetchPayerPhotos(_ items: [Expense]) {
        guard isShared else { return }
        let urns = Set(items.compactMap { $0.payerProfileID })
            .filter {
                !$0.isEmpty
                && !$0.hasPrefix("email:")
                && !$0.hasPrefix("phone:")
                && !UserProfileStore.isVirtualRecordName($0)
            }
        guard !urns.isEmpty else { return }
        Task { await PublicProfileSync.shared.fetchProfiles(forURNs: Array(urns)) }
    }

    /// 仮想 occurrence の行 (watch, 表示のみ・控えめ)。
    private func virtualRow(_ occ: RecurringOccurrence) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "repeat")
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.gray.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(occ.title.isEmpty ? String(localized: "定期") : occ.title)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(CurrencyCatalog.format(occ.amount, code: occ.currencyCode))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .opacity(0.85)
    }

    /// 表示用タイトル。title が空ならカテゴリ名 (= iOS と同じ `categoryDisplayName`
    /// を使うので、カテゴリも無ければ「カテゴリなし」になる)。
    private func displayTitle(_ e: Expense) -> String {
        if let t = e.title, !t.isEmpty { return t }
        return e.categoryDisplayName
    }

    private func formatYen(_ d: Decimal) -> String {
        CurrencyCatalog.format(d, code: sheet.resolvedDefaultCurrencyCode)
    }
}

// MARK: - Profile Avatar

/// 自分のプロフィールアバター。写真があれば写真、無ければ配色 + 頭文字。
/// 写真は Public DB から取得した photoData を使う (起動時に refreshOwnPublicProfile)。
private struct WatchProfileAvatar: View {
    @ObservedObject private var profile = UserProfileStore.shared
    var size: CGFloat = 28

    var body: some View {
        let name = profile.resolvedDisplayName
        let color = Color(hex: profile.avatarBgColorHex ?? "#5B8DEF") ?? .blue
        #if canImport(UIKit)
        if let data = profile.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            initialAvatar(name: name, color: color)
        }
        #else
        initialAvatar(name: name, color: color)
        #endif
    }

    private func initialAvatar(name: String, color: Color) -> some View {
        ZStack {
            Circle().fill(color.gradient)
            Text(String(name.prefix(1)))
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

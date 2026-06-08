//
//  SheetDetailView.swift
//  Expenso
//

import SwiftUI
import CoreData
import CloudKit
import UIKit
import CustomPicker
#if os(iOS)
import CustomNavigationTitle
#endif

/// 支出の支払い者が指定 profileID と一致するか。
/// 「自分」(selfIDs のいずれか) を選んだ場合は、payerProfileID が selfIDs に
/// 含まれれば一致とみなす（旧 ID でも自分として拾えるように）。
fileprivate func payerMatches(_ pid: String, payerID: String, selfIDs: Set<String>) -> Bool {
    if selfIDs.contains(payerID) {
        return selfIDs.contains(pid)
    }
    return pid == payerID
}

fileprivate func expensePayerMatches(_ exp: Expense, payerID: String, selfIDs: Set<String>) -> Bool {
    payerMatches(exp.payerProfileID ?? "", payerID: payerID, selfIDs: selfIDs)
}

struct SheetDetailView: View {
    @ObservedObject var record: ExpenseSheet
    /// プレビュー表示用。true なら検索バー・ツールバーを描画しない。
    let isPreview: Bool
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
        /// 期間フィルタが有効か (全期間以外なら絞り込み中)。
        var isFiltering: Bool { self != .all }

        /// サマリカードのヘッダー表示 ("2026年11月" / "先月の年月" / "2026年" / "全期間")。
        /// SummaryCard / 検索結果カードの期間ピッカーで共通利用する。
        var headerLabel: String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "ja_JP")
            df.dateFormat = "yyyy年M月"
            switch self {
            case .thisMonth:
                return df.string(from: .now)
            case .lastMonth:
                let last = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
                return df.string(from: last)
            case .thisYear:
                let yf = DateFormatter()
                yf.locale = Locale(identifier: "ja_JP")
                yf.dateFormat = "yyyy年"
                return yf.string(from: .now)
            case .all:
                return "全期間"
            }
        }

        /// 指定日がこの期間に含まれるか。`.all` は常に true。
        func contains(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> Bool {
            guard self != .all else { return true }
            guard let d = date else { return false }
            switch self {
            case .thisMonth:
                return calendar.isDate(d, equalTo: now, toGranularity: .month)
            case .lastMonth:
                guard let lm = calendar.date(byAdding: .month, value: -1, to: now) else { return false }
                return calendar.isDate(d, equalTo: lm, toGranularity: .month)
            case .thisYear:
                return calendar.isDate(d, equalTo: now, toGranularity: .year)
            case .all:
                return true
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

    // 期間フィルタは端末に永続化する (再起動・シート切替後も保持)。
    // 検索専用の searchPeriod は永続化せず従来どおり (検索開始で .all にリセット)。
    @AppStorage("sheetDetailPeriod") private var period: Period = .thisMonth
    /// カテゴリフィルタのピル高さ。固定値にせず Dynamic Type に追従させる。
    @ScaledMetric(relativeTo: .caption) private var filterPillHeight: CGFloat = 28
    @State private var showingAddExpense = false
    @State private var showingCSVImport = false
    @State private var showingShare = false
    @State private var editingExpense: Expense?
    @State private var editingRule: RecurringRule?
    /// 仮想 occurrence をタップした時に詳細へ push する Expense (materialize した未保存行)。
    @State private var detailExpense: Expense?
    /// 仮想 occurrence をタップして materialize した Expense。
    /// 詳細から実際に保存 (commit) されなければ、詳細を閉じた時に破棄する。
    @State private var materializedPending: Expense?
    /// 直近のエディタで実際に保存 (commit) されたか。materializedPending の破棄判定に使う。
    @State private var pendingDidCommit = false
    /// 仮想 occurrence を実支出と同じ ExpenseRowContainer で描くための表示専用 Expense 供給器
    /// (子コンテキスト、never save)。参照型を @State で保持し view identity 間で安定させる。
    @State private var virtualBacking = VirtualRowBacking()
    @State private var showingEditGroup = false
    /// 削除確認の対象支出 (List 単位の 1 つの confirmationDialog で表示する)。
    @State private var pendingDeleteExpense: Expense?
    @State private var searchText: String = ""
    /// 検索バーがフォーカスされているか。
    /// フォーカス直後 (未入力) は全件ではなく 0 件表示にする。
    @FocusState private var searchFocused: Bool
    /// 検索専用の期間。普段の表示の `period` とは独立で、検索開始時は常に全期間。
    @State private var searchPeriod: Period = .all
    @State private var selectedCategory: ExpenseCategory?
    /// 「カテゴリなし」(= category == nil の支出) でフィルタ中か。
    /// `selectedCategory` と相互排他。
    @State private var filterUncategorized: Bool = false
    /// 支払い者で絞り込む時の profileID（membersStrip のタップで設定）。nil = 全員。
    @State private var selectedPayerID: String?
    @State private var exportPaywall: Bool = false
    @State private var lockPaywall: Bool = false
    @State private var showingSetPassword: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var showingLeaveConfirm: Bool = false
    @State private var exportShareItem: ExportShareItem?
    /// ロック状態をツールバーボタンに反映するため observe する。
    @StateObject private var lockManager = SheetLockManager.shared
    @Environment(\.dismiss) private var dismiss
    /// 「視差効果を減らす」(Reduce Motion) が ON ならアニメーションを抑制する。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    init(record: ExpenseSheet, isPreview: Bool = false) {
        self.record = record
        self.isPreview = isPreview
        self._allExpenses = FetchRequest<Expense>(
            // date が同じ時の並びが不安定にならないよう createdAt を tiebreaker に使う。
            sortDescriptors: [
                NSSortDescriptor(keyPath: \Expense.date, ascending: false),
                NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false),
            ],
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

    /// 検索バーがアクティブか (フォーカス中 or クエリ入力済み)。
    /// クエリ入力後にキーボードを閉じても (フォーカスが外れても) 検索状態は維持する。
    private var isSearchActive: Bool {
        searchFocused || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 現在有効な期間。検索中は検索専用 `searchPeriod`、通常時は `period`。
    private var effectivePeriod: Period {
        isSearchActive ? searchPeriod : period
    }

    /// SummaryCard / 期間メニューに渡す期間バインディング。
    /// 検索中は `searchPeriod`、通常時は `period` を読み書きする。
    private var effectivePeriodBinding: Binding<Period> {
        Binding(
            get: { isSearchActive ? searchPeriod : period },
            set: { newValue in
                if isSearchActive { searchPeriod = newValue } else { period = newValue }
            }
        )
    }

    /// 一覧に表示する支出/収入。
    /// 通常時は期間フィルタを適用しない (= 期間ピッカーは SummaryCard の合計にのみ影響)。
    /// 検索中は検索専用の期間 (初期=全期間) で「その期間のみ」に絞り込む。
    /// カテゴリピル・検索・並び順はここで適用する。
    private var filteredExpenses: [Expense] {
        var list = Array(allExpenses)
        if let cat = selectedCategory {
            list = list.filter { $0.category?.objectID == cat.objectID }
        } else if filterUncategorized {
            list = list.filter { $0.category == nil }
        }
        if let payerID = selectedPayerID {
            let selfIDs = UserProfileStore.shared.canonicalSelfIDs(
                forShare: ShareCoordinator.shared.existingShare(for: record))
            list = list.filter { expensePayerMatches($0, payerID: payerID, selfIDs: selfIDs) }
        }
        // 検索中は検索専用の期間で絞り込む。
        if isSearchActive {
            list = list.filter { searchPeriod.contains($0.date) }
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

    /// 一覧に混ぜる仮想 occurrence (完全仮想化フラグ OFF なら空)。
    /// `filteredExpenses` と同じ条件 (カテゴリ/支払者/検索/検索期間) で絞り込む。
    private var filteredVirtuals: [RecurringOccurrence] {
        var list = RecurringOccurrenceService.virtualOccurrences(for: record, includeFuture: false)
        guard !list.isEmpty else { return [] }
        if let cat = selectedCategory {
            let name = cat.name ?? ""
            list = list.filter { $0.categoryRaw == name }
        } else if filterUncategorized {
            list = list.filter { $0.categoryRaw.isEmpty }
        }
        if let payerID = selectedPayerID {
            let selfIDs = UserProfileStore.shared.canonicalSelfIDs(
                forShare: ShareCoordinator.shared.existingShare(for: record))
            list = list.filter { payerMatches($0.payerProfileID ?? "", payerID: payerID, selfIDs: selfIDs) }
        }
        if isSearchActive {
            list = list.filter { searchPeriod.contains($0.date) }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.title.lowercased().contains(q) }
        }
        return list
    }

    var body: some View {
        List {
            Section {
                SummaryCard(
                    record: record,
                    period: effectivePeriodBinding,
                    searchActive: isSearchActive,
                    selectedCategory: selectedCategory,
                    selectedPayerID: selectedPayerID,
                    searchQuery: searchText.trimmingCharacters(in: .whitespaces)
                )
                #if os(iOS)
                // SummaryCard が画面から消えたタイミングでナビバーに
                // タイトルがフェードイン (CustomNavigationTitle)。
                .titleVisibilityAnchor()
                #endif
            }
            .listSectionSeparator(.hidden)

                // Mac と同じく、サマリ下にメンバーストリップを出す。
                if hasAcceptedOtherMembers {
                    Section {
                        membersStrip
                            // 行の左右インセットを 0 にして、横スクロールが画面端まで届くようにする。
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .listSectionSeparator(.hidden)
                }

                // 実支出ゼロでも仮想 occurrence だけのシート (定期ルールのみ) で
                // カテゴリ strip を出す。絞り込める対象 (カテゴリ or カテゴリなし) が
                // あれば表示する (usedCategories/hasUncategorizedExpenses は仮想も含む)。
                if !usedCategories.isEmpty || hasUncategorizedExpenses {
                    categoryPills
                        // 行の左右インセットを 0 にして、横スクロールが画面端まで届くようにする。
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listSectionSeparator(.hidden)
                }

                if allExpenses.isEmpty && filteredVirtuals.isEmpty {
                    emptyStateInitial
                } else if searchFocused && searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 検索フォーカス直後 (未入力) は全件ではなく 0 件 (入力待ち) を表示。
                    emptyStateSearchPrompt
                } else if filteredExpenses.isEmpty && filteredVirtuals.isEmpty {
                    emptyStateFiltered
                } else {
                    sectionedList
                }
        }
        .listStyle(.plain)
        // フィルタ・検索・並び替え・追加で表示集合が変わったら一覧をアニメーション。
        // Reduce Motion 時はアニメーションしない。
        .animation(reduceMotion ? nil : .default,
                   value: filteredExpenses.map { $0.objectID.uriRepresentation().absoluteString } + filteredVirtuals.map(\.id))
        #if os(iOS)
        // SummaryCard が画面外に出たらナビバーにシート名がフェードイン。
        .scrollAwareTitle(record.displayName)
        #endif
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // iOS 26: 検索バーは bottomBar の DefaultToolbarItem に置き、`+` を ToolbarItem で
        // 並列に並べる。ToolbarSpacer で間を空ける。
        // (Liquid Glass デザインの推奨パターン:
        //  https://qiita.com/RS6/items/2f55281499ef7bad96b2)
        // プレビュー時は検索バー・ツールバー（iOS 26 の bottomBar 検索＋追加ボタン含む）を出さない。
        .applyIf(!isPreview) { content in
        content
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("支出、収入を検索"))
        .searchFocused($searchFocused)
        .onChange(of: searchFocused) { _, focused in
            // 新規検索 (フォーカス取得かつ未入力) のたびに期間を全期間から始める。
            // クエリ入力中の再フォーカスでは期間を保持する。
            if focused && searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchPeriod = .all
            }
        }
        .toolbar {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            // iPad は幅に関係なく (Slide Over 等の compact 幅でも) 検索バーが上部へ移動し、
            // bottomBar に `+` だけが残って中央寄せになるため、flexible スペーサーで右端へ寄せる。
            // iPhone は検索バーが bottomBar に残り `+` を右へ押すので fixed のまま。
            if UIDevice.current.userInterfaceIdiom == .pad {
                ToolbarSpacer(.flexible, placement: .bottomBar)
            } else {
                ToolbarSpacer(.fixed, placement: .bottomBar)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .confirm) {
                    showingAddExpense = true
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .tint(record.tint)
            }
            // 「今すぐロック」「共有」は ellipsis の外に独立配置する。
            if lockManager.hasPassword(for: record) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.warning()
                        dismiss()
                    } label: {
                        Image(systemName: "lock.open.fill")
                    }
                    .tint(record.tint)
                    .accessibilityLabel("今すぐロック")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingShare = true
                } label: {
                    Image(systemName: record.isOwnedByCurrentUser ? "person.crop.circle.badge.plus" : "person.2.fill")
                }
                .accessibilityLabel(record.isOwnedByCurrentUser ? "シートを共有" : "共有メンバー")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        SettlementView(record: record)
                            .sheetLockCover(record)
                    } label: {
                        Label("精算", systemImage: "arrow.left.arrow.right.circle")
                    }
                    NavigationLink {
                        StatsView(record: record)
                            .sheetLockCover(record)
                    } label: {
                        Label("統計", systemImage: "chart.pie.fill")
                    }
                    if SheetAIChat.isAvailable {
                        NavigationLink {
                            SheetAIChatView(record: record)
                                .sheetLockCover(record)
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
                            .sheetLockCover(record)
                    } label: {
                        Label("カテゴリを管理", systemImage: "tag.fill")
                    }
                    NavigationLink {
                        VirtualMemberListView(record: record)
                            .sheetLockCover(record)
                    } label: {
                        Label("バーチャルメンバー", systemImage: "person.crop.circle.badge.plus")
                    }
                    // ロック設定はオーナーのみ。参加者 (= 非オーナー) はロック解除画面で
                    // パスワードを入れて閲覧することしかできない。
                    if record.isOwnedByCurrentUser {
                        Button {
                            // 既存のロックの編集 / 解除は Premium 解除後も許可する。
                            // (Premium 無いから外せないバグの修正)。
                            // 新規ロックの追加だけは Premium 必須。
                            if PurchaseManager.shared.isPremium
                                || SheetLockManager.shared.hasPassword(for: record) {
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
                    if RecurringOccurrenceService.featureEnabled {
                        NavigationLink {
                            RecurringListView(record: record)
                                .sheetLockCover(record)
                        } label: {
                            Label("定期項目", systemImage: "repeat")
                        }
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
                    Image(systemName: "ellipsis")
                }
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
            // 仮想 occurrence をタップして materialize した Expense は、エディタで実際に
            // 保存 (commit) された時だけ残す。キャンセル時は破棄する。
            // → 「編集画面を開いただけで expenses に保存される」のを防ぐ。
            // ※ onAppear の ensureSelfMemberExists 等が viewContext を save して保留中の
            //   insert が永続化されることがあるため、temporary-ID ではなく commit 有無で判定する。
            if let m = materializedPending {
                materializedPending = nil
                if !pendingDidCommit {
                    viewContext.delete(m)
                    PersistenceController.shared.save()
                }
            }
            pendingDidCommit = false
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
            }, onCommit: {
                pendingDidCommit = true
            })
        }
        .sheet(item: $editingRule) { rule in
            EditRecurringRuleView(mode: .edit(rule: rule))
        }
        // 仮想 occurrence をタップ → materialize した Expense の詳細へ push (実支出と同じ画面)。
        .navigationDestination(item: $detailExpense) { exp in
            // commit 時は詳細を閉じて一覧へ戻す。これにより「この項目のみ=切り離し」「今後/全て=
            // edit-point 削除」のどちらでも、編集後に解放済み/変化したオブジェクトを描画しない。
            ExpenseDetailView(expense: exp, onCommit: {
                pendingDidCommit = true
                detailExpense = nil
            })
        }
        // 詳細を閉じた時、編集が commit されていなければ materialize した未保存行を破棄する
        // (= 仮想を見ただけ/編集せず戻った場合は expenses に保存しない)。
        .onChange(of: detailExpense) { _, newValue in
            if newValue == nil, let m = materializedPending {
                materializedPending = nil
                if !pendingDidCommit {
                    viewContext.delete(m)
                    PersistenceController.shared.save()
                }
                pendingDidCommit = false
            }
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
            case "stats":
                demoOpenStats = true
            case "chat":
                demoOpenChat = true
            default: break
            }
        }
        .navigationDestination(isPresented: $showRecurringListAutoEdit) {
            RecurringListView(record: record, autoEditRule: recurringListAutoEdit)
                .sheetLockCover(record)
        }
        .navigationDestination(isPresented: $demoOpenStats) {
            StatsView(record: record)
                .sheetLockCover(record)
        }
        .navigationDestination(isPresented: $demoOpenChat) {
            SheetAIChatView(record: record)
                .sheetLockCover(record)
        }
    }

    // MARK: - Components

    private var emptyStateInitial: some View {
        ContentUnavailableView(
            "支出がありません",
            systemImage: "yensign.circle",
            description: Text("右下の + から最初の取引を追加してください。")
        )
        .listSectionSeparator(.hidden)
        .listRowSeparator(.hidden)
    }

    /// 検索フォーカス直後 (未入力) の入力待ち表示。全件は出さない。
    private var emptyStateSearchPrompt: some View {
        ContentUnavailableView(
            "検索ワードを入力",
            systemImage: "magnifyingglass",
            description: Text("支出・収入のタイトルや支払い者で検索できます。")
        )
        .listSectionSeparator(.hidden)
        .listRowSeparator(.hidden)
    }

    /// 期間 (検索中) またはカテゴリで絞り込み中か。
    private var isFilterActive: Bool {
        selectedCategory != nil || filterUncategorized || selectedPayerID != nil
            || (isSearchActive && searchPeriod.isFiltering)
    }

    private var filterDescription: String {
        var parts: [String] = []
        if isSearchActive && searchPeriod.isFiltering { parts.append("期間「\(searchPeriod.label)」") }
        if selectedCategory != nil || filterUncategorized { parts.append("カテゴリ") }
        // メンバー選択は支出の支払い者と収入の受け取り者の両方を絞り込むので
        // 「支払い者」ではなく「メンバー」と表示する。
        if selectedPayerID != nil { parts.append("メンバー") }
        return parts.joined(separator: "・") + "で絞り込まれています。"
    }

    @ViewBuilder
    private var emptyStateFiltered: some View {
        // 期間/カテゴリで絞り込み中に 0 件なら、フィルタ解除を促す (Apple Music 風)。
        // 絞り込みが無いただの 0 件なら通常の検索空表示。
        if isFilterActive {
            let q = searchText.trimmingCharacters(in: .whitespaces)
            ContentUnavailableView {
                Label(q.isEmpty ? "該当する項目なし" : "“\(q)” の検索結果なし",
                      systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(filterDescription)
            } actions: {
                Button("フィルタをオフにする") {
                    selectedCategory = nil
                    filterUncategorized = false
                    selectedPayerID = nil
                    searchPeriod = .all
                }
                .buttonStyle(.plain)
            }
            .listSectionSeparator(.hidden)
            .listRowSeparator(.hidden)
        } else {
            ContentUnavailableView.search(text: searchText)
                .listSectionSeparator(.hidden)
                .listRowSeparator(.hidden)
        }
    }

    private var sectionedList: some View {
            ForEach(groupedByDay(), id: \.key) { section in
                Section {
                        ForEach(section.value) { item in
                            switch item {
                            case .expense(let expense):
                                // 削除確認は各支出行に .confirmationDialog を付ける。
                                // 共有 state (pendingDeleteExpense) を渡しつつ、setter は
                                // 「自分が対象の時だけ nil」にガードして他行との干渉を防ぐ。
                                ExpenseRowContainer(
                                    expense: expense,
                                    pendingDelete: $pendingDeleteExpense,
                                    onEdit: { editingExpense = expense },
                                    onEditRule: expense.generatedFromRuleID != nil
                                        ? { editingRule = expense.relatedRule }
                                        : nil,
                                    onDuplicate: { duplicate(expense) },
                                    onDelete: { deleteExpense(expense) }
                                )
                                // 挿入/削除時の opacity フェードを無くす (残る行の reflow は維持)。
                                .transition(.identity)
                            case .occurrence(let occ):
                                // 仮想 occurrence (未実体化の定期分)。実支出と同じ ExpenseRowContainer で
                                // 描画し、見た目 (シェブロン/レイアウト) もスワイプ/コンテキストメニューも統一する。
                                // 表示は子コンテキストの transient Expense (never save)。操作は materialize
                                // (commit-guard) や skip へ流す:
                                //   タップ/編集 = materialize→詳細 or エディタ (commit しなければ破棄)
                                //   削除 = この回だけ skip (ルールに記録)
                                //   定期項目を編集 = 該当ルールの編集
                                //   複製 = occurrence 値から独立した実支出コピーを作成
                                ExpenseRowContainer(
                                    expense: virtualBacking.displayExpense(for: occ, sheet: record),
                                    pendingDelete: $pendingDeleteExpense,
                                    onEdit: {
                                        pendingDidCommit = false
                                        editingExpense = materialize(occ)
                                    },
                                    onEditRule: { editingRule = ruleForOccurrence(occ) },
                                    onDuplicate: { duplicateOccurrence(occ) },
                                    onDelete: { skipOccurrence(occ) },
                                    onTap: {
                                        // タップで materialize (未保存) して詳細へ push。編集 commit
                                        // しなければ詳細を閉じた時に破棄する (= 見ただけでは保存しない)。
                                        pendingDidCommit = false
                                        detailExpense = materialize(occ)
                                    }
                                )
                                .transition(.identity)
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

    /// Mac の `membersStrip` と同じ、シートに参加しているメンバーのアバター + 名前一覧。
    /// 現在のメンバー (= 自分 + CKShare 受諾済み参加者 + アーカイブされていない
    /// バーチャル) のみ表示する。退室済み参加者やアーカイブ済みバーチャルは
    /// 表示しない (過去の支出には残るが、フィルタには出さない)。
    private var membersStrip: some View {
        let ids = record.acceptedMemberProfileIDs()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ids, id: \.self) { id in
                    let info = record.memberDisplayInfo(for: id)
                    let isSelected = selectedPayerID == id
                    Button {
                        // タップで「その人が支払い者」の絞り込みをトグル。
                        selectedPayerID = isSelected ? nil : id
                    } label: {
                        VStack(spacing: 4) {
                            AvatarView(
                                photoData: info.photoData,
                                displayName: info.name,
                                colorHex: info.colorHex,
                                size: 36
                            )
                            // strokeBorder は枠内に描くので、枠が見切れない。
                            .overlay(
                                Circle().strokeBorder(record.tint, lineWidth: isSelected ? 2.5 : 0)
                            )
                            Text(info.name)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(isSelected ? record.tint : .secondary)
                        }
                        .frame(maxWidth: 80)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// 参加済の他メンバー (= 自分以外で acceptanceStatus == .accepted) が居るか。
    /// CKShare 未ロード時は PP の存在で判定。
    /// 共有していなくてもバーチャルメンバーが居れば「他メンバーあり」扱いにする
    /// (= メンバーフィルタ・支払者表示を出すため)。
    private var hasAcceptedOtherMembers: Bool {
        let profilesAll = (record.participantProfiles as? Set<ParticipantProfile>) ?? []
        let hasVirtual = profilesAll.contains {
            UserProfileStore.isVirtualRecordName($0.recordName ?? "") && !$0.archived
        }
        if hasVirtual { return true }
        if let share = ShareCoordinator.shared.existingShare(for: record) {
            // 「自分」以外で受諾済みの参加者が居るか（オーナーも自分でなければ数える）。
            let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
            return share.participants.contains { p in
                guard p.acceptanceStatus == .accepted else { return false }
                let rn = p.userIdentity.userRecordID?.recordName ?? ""
                guard !rn.isEmpty, !UserProfileStore.isSelfPlaceholderRecordName(rn) else { return false }
                return !selfIDs.contains(rn)
            }
        }
        let myRN = UserProfileStore.shared.userRecordName ?? ""
        return profilesAll.contains { p in
            let rn = p.recordName ?? ""
            return !rn.isEmpty && rn != myRN
        }
    }

    /// カテゴリ絞り込みのチップ列。macOS 26 のメール風に「非選択 = アイコンのみ /
    /// 選択 = カテゴリ色の背景 + ラベルに展開」する (選択切替はアニメーション)。
    private var categoryPills: some View {
        let isAllSelected = selectedCategory == nil && !filterUncategorized
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill(icon: "square.grid.2x2.fill", label: "すべて",
                           color: record.tint, selected: isAllSelected) {
                    selectedCategory = nil
                    filterUncategorized = false
                }

                ForEach(usedCategories, id: \.objectID) { cat in
                    let isSelected = selectedCategory?.objectID == cat.objectID
                    filterPill(icon: cat.displaySymbol, label: cat.displayName,
                               color: cat.tint, selected: isSelected) {
                        if isSelected {
                            selectedCategory = nil
                        } else {
                            selectedCategory = cat
                            filterUncategorized = false
                        }
                    }
                }

                // カテゴリなしの支出が 1 件でもあれば「カテゴリなし」ピルを出す。
                if hasUncategorizedExpenses {
                    filterPill(icon: "tag.slash", label: "カテゴリなし",
                               color: .gray, selected: filterUncategorized) {
                        filterUncategorized.toggle()
                        if filterUncategorized { selectedCategory = nil }
                    }
                }
            }
            .padding(.horizontal, 16)
            .animation(.snappy, value: selectedCategory)
            .animation(.snappy, value: filterUncategorized)
        }
    }

    /// メール風フィルタピル。非選択はアイコンのみ、選択時に color 背景 + ラベルへ展開する。
    /// アイコンのみの時も VoiceOver でラベルを読み上げる。
    @ViewBuilder
    private func filterPill(icon: String, label: String, color: Color,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                if selected {
                    Text(label).lineLimit(1).fixedSize()
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, selected ? 12 : 9)
            // 高さは Dynamic Type に追従させつつ、アイコン (SF Symbol) の高さに依らず揃える。
            .frame(height: filterPillHeight)
            .background(
                Capsule()
                    .fill(selected ? color : Color.platformSecondarySystemFill)
            )
            // 選択中は塗り (color) の上に背景色のテキスト/アイコンを抜き文字で乗せる。
            .foregroundStyle(selected ? Color.platformSystemBackground : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// カテゴリ未設定 (= category == nil) の支出が含まれているか。仮想 occurrence も含める。
    private var hasUncategorizedExpenses: Bool {
        if allExpenses.contains(where: { $0.category == nil && !isPendingMaterialized($0) }) {
            return true
        }
        return RecurringOccurrenceService.virtualOccurrences(for: record, includeFuture: false)
            .contains { $0.categoryRaw.isEmpty }
    }

    /// 仮想 occurrence をタップして materialize した「未 commit」の Expense か。
    /// これは詳細を見ているだけの一時的な実体で、閉じれば破棄される。フィルタ
    /// (カテゴリ chip / 未分類) の母集合から外し、「見ただけでその支出のカテゴリ
    /// フィルタが一時的に出る」のを防ぐ。@FetchRequest は pending 挿入も拾うため必要。
    private func isPendingMaterialized(_ exp: Expense) -> Bool {
        if let m = materializedPending, m === exp { return true }
        return false
    }

    // MARK: - Helpers

    private struct DaySection {
        let key: String
        let dayLabel: String
        let dayNet: Decimal
        let value: [LedgerItem]
    }

    private func groupedByDay() -> [DaySection] {
        let cal = Calendar.current
        // 実 Expense + 仮想 occurrence を union にまとめて日別グループ化する。
        let items: [LedgerItem] = filteredExpenses.map { LedgerItem.expense($0) }
            + filteredVirtuals.map { LedgerItem.occurrence($0) }
        let dict = Dictionary(grouping: items) { item -> Date in
            cal.startOfDay(for: item.date)
        }
        // 今年の日付は「M月d日 (E)」、それ以外は「yyyy年M月d日 (E)」で年を付ける。
        let currentYear = cal.component(.year, from: .now)
        let shortFormatter = DateFormatter()
        shortFormatter.locale = Locale(identifier: "ja_JP")
        shortFormatter.dateFormat = "M月d日 (E)"
        let longFormatter = DateFormatter()
        longFormatter.locale = Locale(identifier: "ja_JP")
        longFormatter.dateFormat = "yyyy年M月d日 (E)"

        let target = record.resolvedDefaultCurrencyCode
        let fx = FXRatesService.shared

        let sections = dict.map { (day, dayItems) -> DaySection in
            let year = cal.component(.year, from: day)
            let label = (year == currentYear ? shortFormatter : longFormatter).string(from: day)
            var net: Decimal = 0
            for it in dayItems {
                let amt = fx.convert(it.amountDecimal, from: it.currencyCode, to: target) ?? it.amountDecimal
                net += (it.kind == .income) ? amt : -amt
            }
            // 日内の並び順は一覧の並びに合わせる (実支出は時刻あり、仮想は 0:00)。
            let sorted = dayItems.sorted { a, b in
                switch (sortField, sortAscending) {
                case (.date, true):    return a.date < b.date
                case (.date, false):   return a.date > b.date
                case (.amount, true):  return a.amountDecimal < b.amountDecimal
                case (.amount, false): return a.amountDecimal > b.amountDecimal
                }
            }
            let key = ISO8601DateFormatter().string(from: day)
            return DaySection(key: key, dayLabel: label, dayNet: net, value: sorted)
        }
        return sections.sorted { $0.key > $1.key }
    }

    /// 仮想 occurrence の元になった RecurringRule を引く。
    private func ruleForOccurrence(_ occ: RecurringOccurrence) -> RecurringRule? {
        (record.recurringRules as? Set<RecurringRule>)?.first { $0.id == occ.ruleID }
    }

    /// 仮想 occurrence を実 Expense として実体化する (override 化)。
    /// `(generatedFromRuleID, scheduledDate)` を持つので virtualOccurrences 側で
    /// 以後この日付の仮想は出さなくなる。編集はこの実 Expense に対して既存フローで行う。
    /// 定期 occurrence なので FX スナップショットは取らない (現行レートで精算)。
    @MainActor
    private func materialize(_ occ: RecurringOccurrence) -> Expense {
        let e = Expense(context: viewContext)
        let store = record.objectID.persistentStore
        if let store { viewContext.assign(e, to: store) }
        e.title = occ.title.isEmpty ? nil : occ.title
        e.amount = NSDecimalNumber(decimal: occ.amount)
        e.kindRaw = occ.kind.rawValue
        e.currencyCode = occ.currencyCode
        e.categoryRaw = occ.categoryRaw.isEmpty ? nil : occ.categoryRaw
        e.payerProfileID = occ.payerProfileID
        e.beneficiaryProfileIDs = occ.beneficiaryProfileIDs
        e.note = ""
        e.date = occ.date
        e.scheduledDate = occ.date
        e.createdAt = .now
        e.sheet = record
        e.generatedFromRuleID = occ.ruleID
        if !occ.categoryRaw.isEmpty,
           let cats = record.categories as? Set<ExpenseCategory>,
           let cat = cats.first(where: { $0.name == occ.categoryRaw }),
           cat.objectID.persistentStore == store {
            e.category = cat
        }
        // ここでは保存しない (= 編集画面を開いただけで expenses に保存されないように)。
        // エディタで実際に保存された時のみ永続化される。キャンセル時は onDismiss で破棄。
        materializedPending = e
        return e
    }

    private var usedCategories: [ExpenseCategory] {
        var seen: Set<NSManagedObjectID> = []
        var result: [ExpenseCategory] = []
        func add(_ cat: ExpenseCategory?) {
            guard let cat, !seen.contains(cat.objectID) else { return }
            seen.insert(cat.objectID)
            result.append(cat)
        }
        for exp in allExpenses where !isPendingMaterialized(exp) {
            add(exp.category)
        }
        // 仮想 occurrence のカテゴリも含める (実支出に無く仮想にしか無いカテゴリも絞り込めるように)。
        let cats = (record.categories as? Set<ExpenseCategory>) ?? []
        for occ in RecurringOccurrenceService.virtualOccurrences(for: record, includeFuture: false)
        where !occ.categoryRaw.isEmpty {
            add(cats.first { $0.name == occ.categoryRaw })
        }
        return result.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// CSV / PDF エクスポートのエントリ。Premium (または共有シート) で gate して、
    /// 通れば一時ファイルを作って `ShareSheet` で共有する。
    private func startExport(_ kind: ExportKind) {
        guard PurchaseManager.hasPremiumAccess(to: record) else {
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

    /// 指定 expense を削除する。確認ダイアログ経由でのみ呼ばれる。
    @MainActor
    private func deleteExpense(_ expense: Expense) {
        // 定期由来の occurrence (生成/override/過去凍結) を削除する場合、完全仮想化では
        // 行を消すだけだと仮想で復活してしまうので、ルール側に skip を記録してから削除する。
        if RecurringOccurrenceService.virtualizationEnabled,
           let ruleID = expense.generatedFromRuleID,
           let rule = (record.recurringRules as? Set<RecurringRule>)?.first(where: { $0.id == ruleID }),
           let day = expense.scheduledDate ?? expense.date {
            rule.addSkippedDay(day)
        }
        viewContext.delete(expense)
        PersistenceController.shared.save()
        Haptics.warning()
    }

    /// 仮想 occurrence を「この回だけ削除 (skip)」する。ルールに記録し、以後仮想表示しない。
    private func skipOccurrence(_ occ: RecurringOccurrence) {
        guard let rule = ruleForOccurrence(occ) else { return }
        rule.addSkippedDay(occ.date)
        PersistenceController.shared.save()
        Haptics.warning()
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
        // 複製は割り勘を引き継がない (支払者のみの負担にする)。
        copy.beneficiaryProfileIDs = expense.payerProfileID
        copy.date = .now
        copy.note = expense.note
        copy.createdAt = .now

        // 3) 関係 (同一ストア内のみ)
        copy.sheet = parentSheet
        if let cat = expense.category,
           cat.objectID.persistentStore == parentStore {
            copy.category = cat
        }
        // FX スナップショット (複製時の current FX を凍結)
        copy.captureFXSnapshot()
        pc.save()
        Haptics.success()
    }

    /// 仮想 occurrence を独立した実支出としてコピーする (複製)。occurrence の値から新規 Expense を
    /// 作り、定期との紐付け (generatedFromRuleID) は持たせない。元の occurrence は仮想のまま残る。
    @MainActor
    private func duplicateOccurrence(_ occ: RecurringOccurrence) {
        let pc = PersistenceController.shared
        let copy = Expense(context: viewContext)
        let parentStore = record.objectID.persistentStore
        if let store = parentStore { viewContext.assign(copy, to: store) }
        copy.title = occ.title.isEmpty ? nil : occ.title
        copy.amount = NSDecimalNumber(decimal: occ.amount)
        copy.kindRaw = occ.kind.rawValue
        copy.currencyCode = occ.currencyCode
        copy.categoryRaw = occ.categoryRaw.isEmpty ? nil : occ.categoryRaw
        copy.paidBy = nil
        copy.payerProfileID = occ.payerProfileID
        // 複製は割り勘を引き継がない (支払者のみの負担)。
        copy.beneficiaryProfileIDs = occ.payerProfileID
        copy.date = .now
        copy.note = ""
        copy.createdAt = .now
        copy.sheet = record
        if !occ.categoryRaw.isEmpty,
           let cats = record.categories as? Set<ExpenseCategory>,
           let cat = cats.first(where: { $0.name == occ.categoryRaw }),
           cat.objectID.persistentStore == parentStore {
            copy.category = cat
        }
        // FX スナップショット (複製時の current FX を凍結)
        copy.captureFXSnapshot()
        pc.save()
        Haptics.success()
    }
}

// MARK: - Summary Card

private struct SummaryCard: View {
    @ObservedObject var record: ExpenseSheet
    @Binding var period: SheetDetailView.Period
    /// 検索バーがアクティブ (フォーカス中 or 入力済み) か。
    /// アクティブ かつ クエリ未入力なら合計は 0 (= 行リストの「0 件」と一致させる)。
    let searchActive: Bool
    let selectedCategory: ExpenseCategory?
    let selectedPayerID: String?
    /// 親 view (SheetDetailView) の searchText (trimmed)。空でなければ
    /// 集計を検索ヒットに絞る + ヘッダーに件数を表示する。
    let searchQuery: String
    @ObservedObject private var fx = FXRatesService.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Reduce Motion 時は数値ロール (numericText) とアニメーションを止める。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 子 Expense の編集 (amount 変更等) は ExpenseSheet の objectWillChange を発火させないため、
    /// `record.expenses` 経由で集計すると view が再描画されない。
    /// @FetchRequest を直接観測することで、expense 単位の変更でも合計表示が即時更新される。
    @FetchRequest private var expenses: FetchedResults<Expense>

    init(
        record: ExpenseSheet,
        period: Binding<SheetDetailView.Period>,
        searchActive: Bool = false,
        selectedCategory: ExpenseCategory? = nil,
        selectedPayerID: String? = nil,
        searchQuery: String = ""
    ) {
        self.record = record
        self._period = period
        self.searchActive = searchActive
        self.selectedCategory = selectedCategory
        self.selectedPayerID = selectedPayerID
        self.searchQuery = searchQuery
        self._expenses = FetchRequest<Expense>(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \Expense.date, ascending: false),
                NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false),
            ],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    /// 集計を検索ヒットに絞っているか (= 件数表示やメトリクス非表示の判定)。
    private var isSearching: Bool { searchActive }

    private var code: String { record.resolvedDefaultCurrencyCode }

    private func totals() -> (expense: Decimal, income: Decimal, missing: Set<String>, hitCount: Int) {
        // 検索フォーカス中でクエリ未入力なら、行リストの「0 件」と合わせて合計も 0。
        if searchActive && searchQuery.isEmpty {
            return (0, 0, [], 0)
        }
        // 期間ピッカーは常に合計に反映する (検索中も「その期間のみ」集計)。
        let categoryID = selectedCategory?.objectID
        let target = code
        let q = searchQuery.lowercased()
        let selfIDs: Set<String> = selectedPayerID == nil ? [] :
            UserProfileStore.shared.canonicalSelfIDs(forShare: ShareCoordinator.shared.existingShare(for: record))
        var expenseSum: Decimal = 0
        var incomeSum: Decimal = 0
        var missing: Set<String> = []
        var hitCount = 0
        for e in expenses where period.contains(e.date) {
            if let categoryID, e.category?.objectID != categoryID { continue }
            if let payerID = selectedPayerID, !expensePayerMatches(e, payerID: payerID, selfIDs: selfIDs) { continue }
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
        // 仮想 occurrence (完全仮想化 ON 時のみ非空) も同条件で合計に反映する。
        for occ in RecurringOccurrenceService.virtualOccurrences(for: record, includeFuture: false)
            where period.contains(occ.date) {
            if let cat = selectedCategory, occ.categoryRaw != (cat.name ?? "") { continue }
            if let payerID = selectedPayerID,
               !payerMatches(occ.payerProfileID ?? "", payerID: payerID, selfIDs: selfIDs) { continue }
            if !q.isEmpty, !occ.title.lowercased().contains(q) { continue }
            hitCount += 1
            guard let converted = fx.convert(occ.amount, from: occ.currencyCode, to: target) else {
                missing.insert(occ.currencyCode)
                continue
            }
            switch occ.kind {
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
            && selectedCategory == nil && selectedPayerID == nil && budget != nil
        VStack(alignment: .leading, spacing: 12) {
            // 上段: シートアイコン + 名前 (Mac の summaryHero と同じ)
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(record.tint.gradient)
                    Image(systemName: record.symbol ?? "person.2.fill")
                        .foregroundStyle(.white)
                        // 固定サイズ (Dynamic Type で拡大しない) にして 40×40 の枠に収める。
                        .font(.system(size: 20, weight: .semibold))
                }
                .frame(width: 40, height: 40)
                // 検索中はアイコン右下端に虫眼鏡バッジ。overlay(.bottomTrailing) で
                // AX サイズが変わっても常に角に固定する。円は primary 色。
                .overlay(alignment: .bottomTrailing) {
                    if searchActive {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.platformSystemBackground)
                            .padding(4)
                            .background(Circle().fill(Color.primary))
                            .overlay(Circle().stroke(Color.platformSystemBackground, lineWidth: 1.5))
                            .offset(x: 4, y: 4)
                    }
                }
                Text(record.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }

            // 期間ピッカー + カテゴリ pill (検索中も期間を変更できるよう常に表示)
            HStack(spacing: 8) {
                periodMenuLabel
                Spacer()
                if isSearching {
                    Text("\(t.hitCount)件")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // 大型の収支 (収入 − 支出)。色分けはしない (primary)。Mac と同じ rounded font
            Text(signedAmount(net))
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(reduceMotion ? .identity : .numericText(value: doubleValue(net)))
                .animation(reduceMotion ? nil : .snappy, value: net)

            // 支出合計の直下に「+収入 | -支出」のサマリ行 (左寄せ)
            incomeExpenseSummaryRow(income: t.income, expense: t.expense)

            // メトリクス (残予算)。収支はヘッドライン (大きい金額) で表示
            metricsRow(income: t.income, expense: t.expense, net: net, budget: budget,
                       showRemaining: showBudgetMetrics)

            // 月予算プログレスバー
            if showBudgetMetrics, let budget {
                cleanBudgetBar(spent: t.expense, budget: budget)
            }

            // 為替レート未取得の警告のみ表示 (「為替: … 基準」の常時表示はしない)
            if !t.missing.isEmpty {
                Label("\(t.missing.sorted().joined(separator: ", ")) のレート未取得", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(record.tint.opacity(0.12))
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
            Spacer()
        }
    }

    /// "2026年11月 · Tento" 形式のメニュー (= 期間切替トリガ)。
    /// シート名はサブテキストとして同じ行に出す。
    /// iOS 26 で UIButton ベースの Menu はソースが隠れる morph 挙動になったので、
    /// iOS は UIControl ベースの `PeriodMenuControl` を使ってソースを残したまま展開。
    @ViewBuilder
    private var periodMenuLabel: some View {
        #if os(iOS)
        PeriodMenuControl(
            period: $period,
            periodLabel: periodHeaderLabel
        )
        .fixedSize()
        #else
        legacyPeriodMenuLabel
        #endif
    }

    /// iOS 以外向け (= 旧 SwiftUI Menu 版)。
    private var legacyPeriodMenuLabel: some View {
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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 期間のヘッダー表示 ("2026年11月" / "先月" / "全期間" / "カスタム")
    private var periodHeaderLabel: String { period.headerLabel }

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
                .contentTransition(reduceMotion ? .identity : .numericText(value: doubleValue(expense)))
                .animation(reduceMotion ? nil : .snappy, value: expense)
            Text(expenseCaption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// メトリクス。残予算のみ表示 (今月 + 予算設定時のみ)。
    /// 収支はヘッドライン (大きい金額) 側で表示する。
    @ViewBuilder
    private func metricsRow(income: Decimal, expense: Decimal, net: Decimal, budget: Decimal?, showRemaining: Bool) -> some View {
        if showRemaining {
            let remaining = (budget ?? 0) - expense
            metricColumn(
                label: "残予算",
                value: CurrencyCatalog.format(remaining, code: code),
                dotStyle: .filled(remaining < 0 ? .red : .primary),
                valueColor: remaining < 0 ? .red : .primary
            )
        }
    }

    /// 収支の符号付き表記 ("+¥1,000" / "-¥500" / "¥0")。
    private func signedAmount(_ v: Decimal) -> String {
        let sign = v > 0 ? "+" : (v < 0 ? "-" : "")
        return sign + CurrencyCatalog.format(v.magnitude, code: code)
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
                    Spacer()
                }
            }
        } else {
            HStack {
                leadingPill
                Spacer()
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

    /// 「+収入 | -支出」のサマリ行。AX サイズでは横一列に収まらないので、
    /// `AnyLayout` で縦積みに切替 (WWDC24「Get started with Dynamic Type」推奨パターン)。
    /// 縦積み時は区切りの "|" を省く。
    @ViewBuilder
    private func incomeExpenseSummaryRow(income: Decimal, expense: Decimal) -> some View {
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            Text("+ \(CurrencyCatalog.format(income, code: code))")
                .contentTransition(reduceMotion ? .identity : .numericText(value: doubleValue(income)))
            if !dynamicTypeSize.isAccessibilitySize {
                Text("|")
                    .foregroundStyle(.tertiary)
            }
            Text("- \(CurrencyCatalog.format(expense, code: code))")
                .contentTransition(reduceMotion ? .identity : .numericText(value: doubleValue(expense)))
        }
        .font(.subheadline.monospacedDigit().weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy, value: income)
        .animation(reduceMotion ? nil : .snappy, value: expense)
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
                        .fill(Color.platformTertiarySystemBackground)
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

// MARK: - Expense Row Container

/// 1 行ぶんの支出行 + スワイプ/コンテキストメニュー + 削除確認ダイアログ。
/// 削除確認の `isPresented` を **行ごとのローカル @State** で持つことで、
/// 親の共有 state を複数行が監視して干渉する問題 (= 表示直後に閉じる) を防ぐ。
private struct ExpenseRowContainer: View {
    @ObservedObject var expense: Expense
    /// 削除確認の対象 (親と共有)。各行はこの値が自分かどうかで提示判定する。
    @Binding var pendingDelete: Expense?
    let onEdit: () -> Void
    let onEditRule: (() -> Void)?
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    /// 仮想 occurrence 行で使う。指定すると NavigationLink ではなく Button になり、
    /// タップで materialize→詳細遷移 (commit-guard) のフローへ流す (PR #273)。見た目は
    /// NavigationLink と同じになるよう開示シェブロンを手動付与する。nil なら従来どおり
    /// NavigationLink で詳細へ push する (実支出行)。
    var onTap: (() -> Void)? = nil

    /// この行が削除確認の対象か。
    private var isThisRowPending: Bool {
        pendingDelete?.objectID == expense.objectID
    }

    /// タップ部分。実支出は NavigationLink、仮想は Button+シェブロン (見た目は同一)。
    @ViewBuilder
    private var tappableRow: some View {
        if let onTap {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    ExpenseRowView(expense: expense)
                    // 実支出行 (NavigationLink) と同じ開示シェブロンを手動付与する。
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // タップで編集ではなく詳細画面へ push。編集は詳細画面のツールバーから。
            NavigationLink {
                // ロックは ExpenseDetailView 側で overlay 方式 (lockOverlay) で重ねる。
                // ここで fullScreenCover 版 (sheetLockCover) を使うと、詳細から開く
                // 編集シートと競合して編集画面が閉じてしまうため使わない。
                ExpenseDetailView(expense: expense)
            } label: {
                ExpenseRowView(expense: expense)
            }
        }
    }

    var body: some View {
        tappableRow
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // role: .destructive にすると確認前に行削除アニメが走るので付けない。
            // 見た目の赤は .tint(.red) で維持。
            Button {
                pendingDelete = expense
            } label: {
                Label("削除", systemImage: "trash")
            }
            .tint(.red)
            Button {
                onDuplicate()
            } label: {
                Label("複製", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("編集", systemImage: "pencil")
            }
            if let onEditRule {
                Button(action: onEditRule) {
                    Label("定期項目を編集", systemImage: "repeat")
                }
            }
            Button(action: onDuplicate) {
                Label("複製", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                pendingDelete = expense
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
        // 支出ごとに .confirmationDialog を付ける。
        // setter は「自分が対象の時だけ nil にする」ガード付きにして、
        // 他行の confirmationDialog が共有 state を打ち消して即閉じるのを防ぐ。
        .confirmationDialog(
            "この支出を削除しますか？",
            isPresented: Binding(
                get: { isThisRowPending },
                set: { newVal in
                    if !newVal && isThisRowPending {
                        pendingDelete = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: expense
        ) { exp in
            Button("削除", role: .destructive) {
                onDelete()
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingDelete = nil
            }
        } message: { exp in
            Text("「\(exp.displayTitle.isEmpty ? exp.categoryDisplayName : exp.displayTitle)」を削除します。元に戻せません。")
        }
    }
}

// MARK: - Virtual Occurrence Display Backing (完全仮想化)

/// 仮想 occurrence を**実支出と同じ `ExpenseRowContainer`/`ExpenseRowView` で描画する**ための
/// 表示専用 Expense 供給器。occurrence は値型なので、行を描くには `Expense` インスタンスが要る。
///
/// ここでは viewContext の**子コンテキスト** (parent=viewContext) に Expense を作る。子は
/// **絶対に save しない**ので永続化されず、`ensureSelfMemberExists` 等の副次 save にも巻き込まれない
/// (= 仮想化の「occurrence を保存しない」前提を壊さない)。sheet/category は親 (record) と同じ
/// objectID を子で参照するので、`ExpenseRowView` の共有判定・支払者アバター・通貨・repeat アイコンが
/// そのまま正しく描ける。タップ/編集は実体化 (materialize, commit-guard) へ流すので、この表示用
/// Expense 自体は編集されない。
///
/// occurrence の内容 (金額/カテゴリ/支払者/タイトル等) を署名キーにしてキャッシュするので、
/// ルール変更で値が変われば新しい行に作り直され、stale を防ぐ。
@MainActor
final class VirtualRowBacking {
    private var context: NSManagedObjectContext?
    private var cache: [String: Expense] = [:]

    func displayExpense(for occ: RecurringOccurrence, sheet: ExpenseSheet) -> Expense {
        let ctx = ensureContext(parent: sheet.managedObjectContext)
        let key = signature(occ)
        if let cached = cache[key] { return cached }
        // 暴走防止: 長期スクロール等でキャッシュが膨らんだら一旦クリアする。
        if cache.count > 400 {
            cache.values.forEach { ctx.delete($0) }
            cache.removeAll()
        }
        let e = Expense(context: ctx)
        if let childSheet = try? ctx.existingObject(with: sheet.objectID) as? ExpenseSheet {
            e.sheet = childSheet
            if !occ.categoryRaw.isEmpty,
               let cats = childSheet.categories as? Set<ExpenseCategory>,
               let cat = cats.first(where: { $0.name == occ.categoryRaw }) {
                e.category = cat
            }
        }
        e.title = occ.title.isEmpty ? nil : occ.title
        e.amount = NSDecimalNumber(decimal: occ.amount)
        e.kindRaw = occ.kind.rawValue
        e.currencyCode = occ.currencyCode
        e.categoryRaw = occ.categoryRaw.isEmpty ? nil : occ.categoryRaw
        e.payerProfileID = occ.payerProfileID
        e.beneficiaryProfileIDs = occ.beneficiaryProfileIDs
        e.note = ""
        e.date = occ.date
        e.scheduledDate = occ.date
        e.generatedFromRuleID = occ.ruleID   // → ExpenseRowView が repeat アイコンを出す
        cache[key] = e
        return e
    }

    private func ensureContext(parent: NSManagedObjectContext?) -> NSManagedObjectContext {
        if let context { return context }
        let ctx = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        ctx.parent = parent
        // 親 (viewContext) の変更 (共有ロード・メンバー名変更等) を子の sheet に反映させる。
        ctx.automaticallyMergesChangesFromParent = true
        context = ctx
        return ctx
    }

    private func signature(_ o: RecurringOccurrence) -> String {
        "\(o.id)|\(o.amount)|\(o.categoryRaw)|\(o.payerProfileID ?? "")|\(o.beneficiaryProfileIDs)|\(o.title)|\(o.kind.rawValue)|\(o.currencyCode)"
    }
}

// MARK: - Expense Row

private struct ExpenseRowView: View {
    @ObservedObject var expense: Expense
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Public DB のプロフィールキャッシュ。fetch 完了で再描画して
    /// `displayPaidBy` がカスタム名 (例: "Mac") を反映できるようにする。
    @ObservedObject private var pub = PublicProfileSync.shared
    /// 自分の displayName 変更でも再描画させる (= Public DB 同期で local が更新された時)。
    @ObservedObject private var profileStore = UserProfileStore.shared

    /// 個人専用シート (= 参加済の他メンバーが居ない) かどうか。
    /// CKShare ロード済なら `acceptanceStatus == .accepted` の他メンバーが居るかで判定。
    /// 未ロード時のみ PP フォールバック。
    /// 共有していなくても (アーカイブされていない) バーチャルメンバーが居れば
    /// solo ではない扱いにして、支払者表示を出す。
    private var isSoloSheet: Bool {
        guard let sheet = expense.sheet else { return true }
        let profilesAll = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
        let hasVirtual = profilesAll.contains {
            UserProfileStore.isVirtualRecordName($0.recordName ?? "") && !$0.archived
        }
        if hasVirtual { return false }
        if let share = ShareCoordinator.shared.existingShare(for: sheet) {
            // 「自分」以外で受諾済みの参加者が居るか（オーナーも自分でなければ数える）。
            let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
            let hasAcceptedOthers = share.participants.contains { p in
                guard p.acceptanceStatus == .accepted else { return false }
                let rn = p.userIdentity.userRecordID?.recordName ?? ""
                guard !rn.isEmpty, !UserProfileStore.isSelfPlaceholderRecordName(rn) else { return false }
                return !selfIDs.contains(rn)
            }
            return !hasAcceptedOthers
        }
        let myRN = UserProfileStore.shared.userRecordName ?? ""
        return !profilesAll.contains { p in
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
    /// 共通コンポーネント CategoryPayerIconView に委譲。
    private var categoryIconWithPayer: some View {
        CategoryPayerIconView(expense: expense, size: 38, avatarSize: 18)
    }

    @ViewBuilder
    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 主タイトル位置にカテゴリ名を表示
            Text(expense.categoryDisplayName)
                .font(.body)
                .foregroundStyle(.primary)
            // サブタイトル: 入力タイトルと支払者を縦に積む。
            // (アバターはアイコン右下に重ねるのでここでは出さない)
            let titleText = expense.displayTitle
            let rawName = expense.displayPaidBy
            let payerText = (isSoloSheet && payerIsSelf) ? "" : rawName
            if !titleText.isEmpty {
                Text(titleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !payerText.isEmpty {
                Text(payerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

private extension View {
    /// 条件が真のときだけ modifier 群を適用する（プレビューで検索/ツールバーを外す用途）。
    @ViewBuilder
    func applyIf<V: View>(_ condition: Bool, _ transform: (Self) -> V) -> some View {
        if condition { transform(self) } else { self }
    }
}

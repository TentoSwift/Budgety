//
//  SheetListView.swift
//  Expenso
//

import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

/// 検索のスコープ。検索バー下の Picker で切り替える。
private enum SearchScope: String, CaseIterable, Identifiable {
    case sheets = "シート"
    case expenses = "支出・収入"
    var id: String { rawValue }
}

/// シート行のコンテキストメニューから開くサブ画面（モーダル提示）。
/// `path` (= シート詳細への push) を壊さないよう、これらは sheet で出す。
private enum SheetSubScreen: Identifiable {
    case settlement(ExpenseSheet)
    case stats(ExpenseSheet)
    case categories(ExpenseSheet)

    var id: String {
        let uri = sheet.objectID.uriRepresentation().absoluteString
        switch self {
        case .settlement: return "settle-\(uri)"
        case .stats: return "stats-\(uri)"
        case .categories: return "cat-\(uri)"
        }
    }

    private var sheet: ExpenseSheet {
        switch self {
        case .settlement(let s), .stats(let s), .categories(let s): return s
        }
    }
}

struct SheetListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var showingAddSheet = false
    @State private var showingSettings = false
    @State private var showingPaywall = false
    @State private var showSyncWaitingAlert = false
    @State private var showOfflineAlert = false
    @State private var path: [NSManagedObjectID] = []
    @State private var didRestorePath = false
    @State private var searchText: String = ""
    /// 検索バーがフォーカスされているか。未入力でもフォーカスで結果を出す。
    @FocusState private var searchFocused: Bool
    /// 検索スコープ (シート名 / 支出・収入)。
    @State private var searchScope: SearchScope = .expenses
    /// 検索結果の合計を表示する通貨 (既定はアプリ既定通貨、カードのメニューで変更可)。
    @State private var searchTotalCurrency: String = CurrencyCatalog.defaultCode
    /// 検索の期間フィルタ。既定は全期間 (= 絞り込みなし)。
    @State private var searchPeriod: SheetDetailView.Period = .all
    /// 検索結果からタップした支出 (= 全シート横断検索のヒット) を編集する。
    @State private var editingSearchExpense: Expense?
    /// 検索結果から解錠しようとしているロック中シート。
    @State private var unlockingSheet: ExpenseSheet?
    /// 行の長押しメニューから開くロック設定シート。
    @State private var lockingSheet: ExpenseSheet?
    /// 行の長押しメニューから開くサブ画面（精算/統計/カテゴリ）。
    @State private var subScreen: SheetSubScreen?
    /// コンテキストメニュー表示中のシート。その行を一時的に隠す（プレビューと二重に見せない）。
    @State private var menuActiveSheetID: NSManagedObjectID?
    /// 検索結果のシート別合計を FX 更新時に再計算するため observe する。
    @ObservedObject private var fx = FXRatesService.shared
    /// シートの解錠状態に追従して検索結果を再計算するため observe する。
    @ObservedObject private var lockManager = SheetLockManager.shared
    @AppStorage("lastOpenedSheetURI") private var lastOpenedSheetURI: String = ""

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// 検索バーがアクティブか (フォーカス中 or クエリ入力済み)。
    /// 入力後にキーボードを閉じても検索結果は維持する。
    private var isSearchActive: Bool {
        searchFocused || !trimmedQuery.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isSearchActive {
                    // フォーカス中は (未入力でも) 全シート横断の検索結果を表示する。
                    searchResultsList
                } else if sheets.isEmpty {
                    ContentUnavailableView {
                        Label("シートがありません", systemImage: "person.2")
                    } description: {
                        VStack(spacing: 8) {
                            Text("シートを作成して、家族や友人と支出を共有しましょう。")
                            iCloudStatusBanner()
                        }
                    } actions: {
                        Button {
                            tryShowAddSheet()
                        } label: {
                            Label("シートを作成", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(sheets) { sheet in
                            sheetListRow(sheet)
                        }
                        // 一覧からの削除は廃止。削除はシート詳細画面メニュー (オーナー限定)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Budgety")
            .navigationDestination(for: NSManagedObjectID.self) { id in
                if let sheet = try? viewContext.existingObject(with: id) as? ExpenseSheet {
                    LockedSheetGate(record: sheet) {
                        SheetDetailView(record: sheet)
                    }
                }
            }
            // SheetDetailView と同じく、検索バーは bottomBar の DefaultToolbarItem に置き、
            // `+` を ToolbarItem で並列に並べる。検索すると全シートから支出を横断検索。
            .searchable(text: $searchText, placement: .toolbar, prompt: Text("シート・支出を検索"))
            .searchFocused($searchFocused)
            .searchScopes($searchScope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .onChange(of: searchFocused) { _, focused in
                // 新規検索 (フォーカス取得かつ未入力) のたびに期間を全期間から始める。
                if focused && trimmedQuery.isEmpty { searchPeriod = .all }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // SettingsView 自身が NavigationStack を持つため、ここを
                    // NavigationLink で push すると nested NavigationStack に
                    // なって 1 回目の push が即座に pop される。
                    // sheet 提示なら SettingsView の内側 NavigationStack が
                    // 独立したコンテキストになり問題なく動く。
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .confirm) {
                        tryShowAddSheet()
                    } label: {
                        Label("シートを追加", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddSheetView()
            }
            .sheet(item: $editingSearchExpense) { expense in
                AddExpenseView(expense: expense)
            }
            .sheet(item: $unlockingSheet) { sheet in
                NavigationStack {
                    SheetLockView(
                        record: sheet,
                        // 解錠すると lockManager の更新で検索結果に含まれる。
                        onUnlock: { unlockingSheet = nil },
                        onCancel: { unlockingSheet = nil }
                    )
                }
            }
            .sheet(item: $lockingSheet) { sheet in
                NavigationStack {
                    SetSheetPasswordView(record: sheet)
                }
            }
            .sheet(item: $subScreen) { screen in
                NavigationStack {
                    subScreenContent(screen)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("閉じる") { subScreen = nil }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .alert("同期完了を待っています", isPresented: $showSyncWaitingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("iCloud から既存のシートを取得中です。少し待ってからもう一度お試しください。")
            }
            .alert("インターネット接続が必要です", isPresented: $showOfflineAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("シートの新規作成には iCloud との同期が必要です。Wi-Fi またはモバイル通信に接続してから再度お試しください。")
            }
            .onAppear {
                applyDemoLaunch()
                restoreLastOpenedSheetIfNeeded()
            }
            .onChange(of: sheets.count) { _, _ in
                restoreLastOpenedSheetIfNeeded()
            }
            .onChange(of: path) { oldPath, newPath in
                // 末尾のシート URI を覚えておき、次回起動時に復元する
                if let last = newPath.last {
                    lastOpenedSheetURI = last.uriRepresentation().absoluteString
                } else {
                    lastOpenedSheetURI = ""
                }
                // path から外れた (= 一覧に戻った) シートは次回入る時にパスワード再要求。
                // 精算/詳細などの子画面 push は label ベースで path を変えないため、
                // ここは「シートそのものを離脱した時」だけ発火する。
                let removed = Set(oldPath).subtracting(newPath)
                for id in removed {
                    if let sheet = try? viewContext.existingObject(with: id) as? ExpenseSheet,
                       lockManager.hasPassword(for: sheet) {
                        lockManager.lock(sheet)
                    }
                }
            }
        }
    }

    // MARK: - 全シート横断検索

    /// 名前がクエリにマッチするシート (= 「シート」セクションに出す)。
    /// クエリが空 (フォーカスのみ) のときは 0 件。
    private var matchedSheets: [ExpenseSheet] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        return sheets.filter { $0.displayName.lowercased().contains(q) }
    }

    /// ロック中 (パスワードあり & 未解錠) のシート。
    /// 中身は検索対象外なので、解除導線を出すために列挙する。
    private var lockedSheets: [ExpenseSheet] {
        sheets.filter { lockManager.hasPassword(for: $0) && !lockManager.isUnlocked($0) }
    }

    /// 検索ヒットをシートごとにまとめた1グループ。
    /// `net` はヒット項目だけの合計 (シート既定通貨に FX 換算; 収入 +, 支出 -)。
    private struct ExpenseMatchGroup: Identifiable {
        let sheet: ExpenseSheet
        let expenses: [Expense]
        let net: Decimal
        let currency: String
        var id: NSManagedObjectID { sheet.objectID }
    }

    /// 支出/収入がクエリにマッチするものを、所属シートごとにまとめる
    /// (= 「支出・収入」をシート見出しの下に並べる)。
    /// ロック中 (パスワードあり & 未解錠) のシートは中身を出さない。
    private var expenseMatchGroups: [ExpenseMatchGroup] {
        // クエリが空 (フォーカスのみ) のときは 0 件。
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        let lock = SheetLockManager.shared
        let fx = FXRatesService.shared
        var groups: [ExpenseMatchGroup] = []
        for sheet in sheets {
            if lock.hasPassword(for: sheet) && !lock.isUnlocked(sheet) { continue }
            guard let exps = sheet.expenses as? Set<Expense> else { continue }
            let matched = exps
                .filter { searchPeriod.contains($0.date) && matchesExpense($0, query: q) }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            guard !matched.isEmpty else { continue }
            let target = sheet.resolvedDefaultCurrencyCode
            var net: Decimal = 0
            for e in matched {
                let amt = fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal
                net += (e.kind == .income) ? amt : -amt
            }
            groups.append(ExpenseMatchGroup(sheet: sheet, expenses: matched, net: net, currency: target))
        }
        return groups
    }

    /// 支出 1 件が (シート名以外の) クエリにマッチするか。
    private func matchesExpense(_ e: Expense, query q: String) -> Bool {
        let fields: [String] = [
            e.displayTitle.lowercased(),
            e.categoryDisplayName.lowercased(),
            e.displayPaidBy.lowercased(),
            e.formattedSignedAmount.lowercased(),
            (e.note ?? "").lowercased()
        ]
        return fields.contains { $0.contains(q) }
    }

    // MARK: - Context Menu (シート行の長押し)

    /// シート一覧の行を長押しした時のコンテキストメニュー。
    /// ロック中（未解錠）のシートは中身を保護するため、精算/統計/カテゴリは出さない。
    @ViewBuilder
    private func sheetContextMenu(for sheet: ExpenseSheet) -> some View {
        if lockManager.isUnlocked(sheet) {
            Button { subScreen = .settlement(sheet) } label: {
                Label("精算", systemImage: "arrow.left.arrow.right.circle")
            }
            Button { subScreen = .stats(sheet) } label: {
                Label("統計", systemImage: "chart.pie.fill")
            }
            Button { subScreen = .categories(sheet) } label: {
                Label("カテゴリを管理", systemImage: "tag.fill")
            }
        }
        if lockMenuApplicable(for: sheet) {
            Divider()
            sheetLockMenu(for: sheet)
        }
    }

    @ViewBuilder
    private func sheetLockMenu(for sheet: ExpenseSheet) -> some View {
        if lockManager.hasPassword(for: sheet) {
            if lockManager.isUnlocked(sheet) {
                Button {
                    lockManager.lock(sheet)
                    Haptics.warning()
                } label: {
                    Label("今すぐロック", systemImage: "lock.fill")
                }
            }
            if sheet.isOwnedByCurrentUser {
                Button { presentLockSetup(sheet) } label: {
                    Label("ロック設定", systemImage: "lock.fill")
                }
            }
        } else if sheet.isOwnedByCurrentUser {
            Button { presentLockSetup(sheet) } label: {
                Label("シートをロック", systemImage: "lock")
            }
        }
    }

    /// ロック関連項目を出す価値があるか（空セクション＋Divider を避ける）。
    private func lockMenuApplicable(for sheet: ExpenseSheet) -> Bool {
        if sheet.isOwnedByCurrentUser { return true }
        // 非オーナーは「今すぐロック」(= パスワード有 & 解錠済み) の時だけ。
        return lockManager.hasPassword(for: sheet) && lockManager.isUnlocked(sheet)
    }

    /// プレミアム加入者ならロック設定を開く。未加入なら Paywall。
    private func presentLockSetup(_ sheet: ExpenseSheet) {
        if PurchaseManager.shared.isPremium {
            lockingSheet = sheet
        } else {
            showingPaywall = true
            Haptics.warning()
        }
    }

    /// 長押しメニューから開くサブ画面の中身。
    @ViewBuilder
    private func subScreenContent(_ screen: SheetSubScreen) -> some View {
        switch screen {
        case .settlement(let s): SettlementView(record: s)
        case .stats(let s): StatsView(record: s)
        case .categories(let s): CategoryListView(record: s)
        }
    }

    /// シート一覧の 1 行。
    /// iOS/visionOS では UIContextMenuInteraction ブリッジを使い、プレビューの
    /// タップでも詳細へ遷移できるようにする（NavigationLink は使わず path に積む）。
    /// それ以外のプラットフォームは従来どおり NavigationLink + .contextMenu。
    @ViewBuilder
    private func sheetListRow(_ sheet: ExpenseSheet) -> some View {
        #if canImport(UIKit) && !os(watchOS)
        SheetRowView(record: sheet, showsDisclosure: true)
            // コンテキストメニュー表示中はこの行を隠し、閉じたら戻す。
            .opacity(menuActiveSheetID == sheet.objectID ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: menuActiveSheetID)
            .contentShape(Rectangle())
            .overlay {
                SheetRowInteraction(
                    onOpen: { openSheet(sheet) },
                    makeMenu: { makeRowMenu(for: sheet) },
                    preview: rowPreview(for: sheet),
                    onMenuActiveChange: { active in
                        menuActiveSheetID = active ? sheet.objectID : nil
                    }
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openSheet(sheet) }
        #else
        NavigationLink(value: sheet.objectID) {
            SheetRowView(record: sheet)
        }
        .contextMenu {
            sheetContextMenu(for: sheet)
        }
        #endif
    }

    /// 行のタップ／プレビュータップで詳細へ遷移（path に積む = 復元ロジックと整合）。
    /// 既に遷移済み（path が非空）なら二重 push しない（遷移直前の誤タップ対策）。
    private func openSheet(_ sheet: ExpenseSheet) {
        guard path.isEmpty else { return }
        path.append(sheet.objectID)
    }

    #if canImport(UIKit) && !os(watchOS)
    /// UIKit の長押しメニュー。SwiftUI 版 sheetContextMenu と同じ構成。
    private func makeRowMenu(for sheet: ExpenseSheet) -> UIMenu {
        var top: [UIMenuElement] = []
        if lockManager.isUnlocked(sheet) {
            top.append(UIAction(title: "精算",
                                image: UIImage(systemName: "arrow.left.arrow.right.circle")) { _ in
                subScreen = .settlement(sheet)
            })
            top.append(UIAction(title: "統計",
                                image: UIImage(systemName: "chart.pie.fill")) { _ in
                subScreen = .stats(sheet)
            })
            top.append(UIAction(title: "カテゴリを管理",
                                image: UIImage(systemName: "tag.fill")) { _ in
                subScreen = .categories(sheet)
            })
        }

        var lock: [UIMenuElement] = []
        if lockManager.hasPassword(for: sheet) {
            if lockManager.isUnlocked(sheet) {
                lock.append(UIAction(title: "今すぐロック",
                                     image: UIImage(systemName: "lock.fill")) { _ in
                    lockManager.lock(sheet)
                    Haptics.warning()
                })
            }
            if sheet.isOwnedByCurrentUser {
                lock.append(UIAction(title: "ロック設定",
                                     image: UIImage(systemName: "lock.fill")) { _ in
                    presentLockSetup(sheet)
                })
            }
        } else if sheet.isOwnedByCurrentUser {
            lock.append(UIAction(title: "シートをロック",
                                 image: UIImage(systemName: "lock")) { _ in
                presentLockSetup(sheet)
            })
        }

        var children = top
        if !lock.isEmpty {
            children.append(UIMenu(title: "", options: .displayInline, children: lock))
        }
        return UIMenu(title: "", children: children)
    }

    /// 長押し時のプレビュー。解錠済み（またはロック無し）は詳細画面
    /// (SheetDetailView) をそのまま表示し、ロック中（未解錠）は中身を保護して
    /// 「ロックされています」表示にする。
    private func rowPreview(for sheet: ExpenseSheet) -> AnyView {
        if lockManager.hasPassword(for: sheet) && !lockManager.isUnlocked(sheet) {
            return AnyView(
                VStack(spacing: 16) {
                    SheetIconView(record: sheet, size: 60)
                    Text(sheet.displayName)
                        .font(.headline)
                    Label("このシートはロックされています", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .padding(.horizontal, 24)
            )
        }
        // 詳細画面の中身をプレビュー表示。isPreview=true で検索バー・ツールバーを
        // 描画しないので、本文（サマリ＋一覧）だけが出る。
        return AnyView(
            SheetDetailView(record: sheet, isPreview: true)
                .environment(\.managedObjectContext, viewContext)
        )
    }
    #endif

    @ViewBuilder
    private var searchResultsList: some View {
        switch searchScope {
        case .sheets:
            sheetSearchList
        case .expenses:
            expenseSearchList
        }
    }

    /// スコープ「シート」: シート名ヒットのみ表示。
    @ViewBuilder
    private var sheetSearchList: some View {
        let matched = matchedSheets
        if matched.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List {
                Section("シート") {
                    ForEach(matched, id: \.objectID) { sheet in
                        NavigationLink(value: sheet.objectID) {
                            SheetRowView(record: sheet)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// 全グループ横断の総合計を、指定通貨に換算して集計する。
    private func grandTotal(of groups: [ExpenseMatchGroup], target: String)
        -> (expense: Decimal, income: Decimal, currency: String, mixed: Bool, count: Int) {
        let fx = FXRatesService.shared
        var expenseSum: Decimal = 0
        var incomeSum: Decimal = 0
        var currencies = Set<String>()
        var count = 0
        for group in groups {
            for e in group.expenses {
                count += 1
                currencies.insert(e.resolvedCurrencyCode)
                let amt = fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal
                if e.kind == .income { incomeSum += amt } else { expenseSum += amt }
            }
        }
        return (expenseSum, incomeSum, target, currencies.count > 1, count)
    }

    /// スコープ「支出・収入」: シートごとにセクション分け (シート見出し → その中の項目)。
    /// 見出しには SheetDetailView の日付ヘッダと同じく合計 (net pill) を出す。
    @ViewBuilder
    private var expenseSearchList: some View {
        let groups = expenseMatchGroups
        // 合計は 0 件でも (¥0 で) 出すため、常に算出して SummaryCard を表示する。
        let total = grandTotal(of: groups, target: searchTotalCurrency)
        List {
            // 検索結果全体の合計を SheetDetailView の SummaryCard 風に表示 (常に表示)
            Section {
                SearchTotalCard(
                    expense: total.expense,
                    income: total.income,
                    currency: $searchTotalCurrency,
                    period: $searchPeriod,
                    count: total.count,
                    query: trimmedQuery,
                    mixed: total.mixed
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if groups.isEmpty {
                // 0 件でも合計カードは残しつつ、下に「該当なし」を表示する。
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: searchPeriod.isFiltering ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(trimmedQuery.isEmpty ? "検索ワードを入力してください" : "“\(trimmedQuery)” の検索結果なし")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if searchPeriod.isFiltering {
                                Text("期間「\(searchPeriod.label)」で絞り込まれています。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("フィルタをオフにする") {
                                    searchPeriod = .all
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 32)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.expenses, id: \.objectID) { expense in
                            Button {
                                editingSearchExpense = expense
                            } label: {
                                SearchResultRow(expense: expense, showSheetName: false)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        SearchSheetHeader(
                            title: group.sheet.displayName,
                            net: group.net,
                            currency: group.currency,
                            tint: group.sheet.tint
                        )
                    }
                }
            }
            // ロック中シートは中身を検索対象外にしている。解除導線を出す
            // (マッチの有無は漏らさず、解除すれば検索に含まれる)。
            if !lockedSheets.isEmpty {
                Section {
                    ForEach(lockedSheets, id: \.objectID) { sheet in
                        Button {
                            unlockingSheet = sheet
                        } label: {
                            HStack(spacing: 12) {
                                SheetIconView(record: sheet, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sheet.displayName)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("ロック中 · 解除して検索に含める")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Label("ロック中のシート", systemImage: "lock.fill")
                }
            }
        }
        .listStyle(.plain)
    }

    /// 前回開いていたシートを起動時に自動で開く。
    /// `sheets` が空 (= CloudKit 初回 import 未完了) の段階では何もせず、
    /// 後から sheets が更新された時点 (`onChange(of: sheets.count)`) に再試行する。
    /// 一度成功したら以後は走らないように `didRestorePath` でガード。
    private func restoreLastOpenedSheetIfNeeded() {
        guard !didRestorePath else { return }
        guard !lastOpenedSheetURI.isEmpty, sheets.first != nil else { return }
        guard let coord = viewContext.persistentStoreCoordinator,
              let url = URL(string: lastOpenedSheetURI),
              let objectID = coord.managedObjectID(forURIRepresentation: url),
              let _ = try? viewContext.existingObject(with: objectID) as? ExpenseSheet
        else {
            // URI 不正 / シートが削除済 → 復元失敗だが以後再試行しない
            didRestorePath = true
            return
        }
        path = [objectID]
        didRestorePath = true
    }

    /// 新しいシートを追加しようとした時のゲート。3 値で分岐:
    /// - `.allowed`: そのまま追加画面を出す
    /// - `.waitingForSync`: CloudKit 初回 import 完了待ち → アラートで「同期待ち」を案内
    /// - `.overLimit`: Free 上限到達 → Paywall を提示
    private func tryShowAddSheet() {
        switch PurchaseManager.sheetCreationGate() {
        case .allowed:
            showingAddSheet = true
        case .waitingForSync:
            showSyncWaitingAlert = true
            Haptics.warning()
        case .offline:
            showOfflineAlert = true
            Haptics.warning()
        case .overLimit:
            showingPaywall = true
            Haptics.warning()
        }
    }

    private func applyDemoLaunch() {
        let demo = ProcessInfo.processInfo.environment["EXPENSO_DEMO"]
        switch demo {
        case "addGroup":
            showingAddSheet = true
        case "detail", "addExpense", "share", "editGroup", "editExpense", "calendar", "templates", "stats", "chat":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let first = sheets.first { path = [first.objectID] }
            }
        case "detailGreen":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if sheets.count > 1 { path = [sheets[1].objectID] }
            }
        default:
            break
        }
    }
}

/// 検索結果全体の合計カード。SheetDetailView の SummaryCard と同じレイアウト
/// (アイコン + 見出し → 大きい支出合計 → 「+収入 | -支出」)。
private struct SearchTotalCard: View {
    let expense: Decimal
    let income: Decimal
    /// 表示通貨。カード右上のメニューで変更できる。
    @Binding var currency: String
    /// 期間フィルタ。カードのメニューで変更できる。
    @Binding var period: SheetDetailView.Period
    let count: Int
    let query: String
    let mixed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 上段: 検索アイコン + 見出し + 通貨メニュー
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white)
                        .font(.callout.weight(.semibold))
                }
                .frame(width: 40, height: 40)
                Text("検索結果")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                currencyMenu
            }

            // 検索クエリ件数 pill + 期間メニュー
            HStack(spacing: 8) {
                Text(query.isEmpty ? "すべて · \(count)件" : "「\(query)」 · \(count)件")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                periodMenu
                Spacer()
            }

            // 大型の支出合計 (SummaryCard と同じ rounded font)
            Text(CurrencyCatalog.format(expense, code: currency))
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            // 「+収入 | -支出」行 (左寄せ)
            HStack(spacing: 12) {
                Text("+ \(CurrencyCatalog.format(income, code: currency))")
                Text("|").foregroundStyle(.tertiary)
                Text("- \(CurrencyCatalog.format(expense, code: currency))")
            }
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if mixed {
                Label("通貨が混在するため \(currency) に換算した概算です。", systemImage: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
    }

    /// 表示通貨を切り替えるメニュー。
    private var currencyMenu: some View {
        Menu {
            Picker("通貨", selection: $currency) {
                ForEach(CurrencyCatalog.all) { opt in
                    Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currency)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
    }

    /// 期間を切り替えるメニュー。絞り込み中 (全期間以外) は色付きで強調。
    private var periodMenu: some View {
        Menu {
            Picker("期間", selection: $period) {
                ForEach(SheetDetailView.Period.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: period.isFiltering
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "calendar")
                    .font(.caption2)
                Text(period.label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(period.isFiltering ? 0.28 : 0.15)))
            .foregroundStyle(Color.accentColor)
        }
    }
}

/// 検索結果のシート別セクション見出し。シート名 + ヒット合計 (net pill)。
/// SheetDetailView の DateHeaderView と同じスタイル。
private struct SearchSheetHeader: View {
    let title: String
    let net: Decimal
    let currency: String
    let tint: Color
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: "tray.full")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                HStack { Spacer(); netPill }
            }
        } else {
            HStack {
                Label(title, systemImage: "tray.full")
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

/// 全シート横断検索のヒット行。カテゴリアイコン + タイトル/カテゴリ +
/// 所属シート名 + 金額 を表示する。
private struct SearchResultRow: View {
    @ObservedObject var expense: Expense
    /// シート見出しの下に出す時 (= シート別セクション) は所属シート名を省略する。
    var showSheetName: Bool = true
    @ObservedObject private var pub = PublicProfileSync.shared

    var body: some View {
        HStack(spacing: 12) {
            CategoryPayerIconView(expense: expense, size: 38, avatarSize: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if showSheetName, let sheet = expense.sheet {
                        Text(sheet.displayName)
                        if expense.date != nil { Text("·") }
                    }
                    if let d = expense.date {
                        Text(d, format: .dateTime.year().month().day())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(expense.formattedSignedAmount)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}

private struct SheetRowView: View {
    @ObservedObject var record: ExpenseSheet
    /// UIKit ブリッジ経由の行は NavigationLink が無いので、自前で
    /// ディスクロージャ (>) を表示してタップ可能なことを示す。
    var showsDisclosure: Bool = false
    @StateObject private var lockManager = SheetLockManager.shared

    var body: some View {
        HStack(spacing: 14) {
            SheetIconView(record: record, size: 44)
            Text(record.displayName)
                .font(.headline)
            Spacer()
            if lockManager.hasPassword(for: record) {
                Image(systemName: lockManager.isUnlocked(record) ? "lock.open.fill" : "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// ロック対象シートの開封ゲート。未解錠なら SheetLockView を出し、
/// 解錠後/最初からロック無しなら子コンテンツ (SheetDetailView) を表示。
/// シートから離脱 (= 一覧に戻る) した時の再ロックは SheetListView 側で
/// `path` の変化を見て行う（ここで `.onDisappear` を使うと、精算/詳細など
/// 子画面を push した時にも発火して即再ロックされてしまうため）。
private struct LockedSheetGate<Content: View>: View {
    @ObservedObject var record: ExpenseSheet
    let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @StateObject private var lockManager = SheetLockManager.shared

    var body: some View {
        Group {
            if lockManager.isUnlocked(record) {
                content()
            } else {
                SheetLockView(
                    record: record,
                    onUnlock: { /* state 更新で自動で content に切替 */ },
                    onCancel: { dismiss() }
                )
            }
        }
    }
}

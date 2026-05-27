//
//  BudgetyMacContentView.swift
//  Budgety For macOS
//
//  iOS 版 SheetListView 相当。NavigationSplitView の sidebar にシート一覧、
//  detail に選択中のシートの支出ビュー。
//

import SwiftUI
import CoreData

struct BudgetyMacContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)
        ],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var selectedSheet: ExpenseSheet?
    @State private var showingAddSheet: Bool = false
    @State private var showSettingsView: Bool = false
    @State private var showingProfileEdit: Bool = false
    @State private var showingPaywall: Bool = false
    @State private var showSyncWaitingAlert: Bool = false
    @State private var showOfflineAlert: Bool = false
    @State private var showNotSignedInAlert: Bool = false
    /// サイドバーの横断検索クエリ。空でなければ detail に検索結果を出す。
    @State private var searchText: String = ""
    /// 検索結果から解錠しようとしているロック中シート (インライン解錠モーダル)。
    @State private var unlockingSheet: ExpenseSheet?
    /// 検索結果の合計を表示する通貨 (既定はアプリ既定通貨、カードのメニューで変更可)。
    @State private var searchTotalCurrency: String = CurrencyCatalog.defaultCode
    @StateObject private var lockManager = SheetLockManager.shared
    @ObservedObject private var fx = FXRatesService.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Reduce Motion 時は数値ロールを止める。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if !trimmedQuery.isEmpty {
                // 横断検索中は全シートの検索結果を detail に表示。
                searchResultsDetail
            } else if let sheet = selectedSheet {
                if lockManager.isUnlocked(sheet) {
                    BudgetyMacSheetView(sheet: sheet)
                } else {
                    // ロック中はパスワード入力画面を detail に表示。
                    // macOS は物理キーボードで入力できる MacSheetLockView を使う。
                    // 解錠すると lockManager の変化で自動的にシート本体へ切り替わる。
                    MacSheetLockView(
                        record: sheet,
                        onUnlock: { },
                        onCancel: { selectedSheet = nil }
                    )
                }
            } else {
                ContentUnavailableView {
                    Label("シートを選択", systemImage: "rectangle.stack")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            MacAddSheetView()
        }
        .sheet(isPresented: $showSettingsView) {
            BudgetyMacSettingsView()
        }
        .sheet(isPresented: $showingProfileEdit) {
            ProfileEditView()
        }
        .sheet(isPresented: $showingPaywall) {
            MacModalSheet { PaywallView() }
        }
        .sheet(item: $unlockingSheet) { sheet in
            // 検索結果からロック中シートを解錠するモーダル。解錠すると
            // lockManager の更新で検索結果に含まれる (検索からは離れない)。
            MacSheetLockView(
                record: sheet,
                onUnlock: { unlockingSheet = nil },
                onCancel: { unlockingSheet = nil }
            )
            .frame(width: 420, height: 460)
        }
        .alert("同期完了を待っています", isPresented: $showSyncWaitingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iCloud から既存のシートを取得中です。少し待ってからもう一度お試しください。")
        }
        .alert("インターネット接続が必要です", isPresented: $showOfflineAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("シートの新規作成には iCloud との同期が必要です。インターネットに接続してから再度お試しください。")
        }
        .alert("iCloud にサインインしてください", isPresented: $showNotSignedInAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("シートの作成には iCloud へのサインインが必要です。システム設定の Apple アカウントから iCloud にサインインしてください。")
        }
        .onAppear {
            if selectedSheet == nil { selectedSheet = sheets.first }
        }
        .onChange(of: selectedSheet) { old, _ in
            // 別シートへ移動したら、離れたシートを再ロックする。
            if let old, lockManager.hasPassword(for: old) {
                lockManager.lock(old)
            }
            // サイドバーでシートを選んだら検索を終了して、そのシートを表示する。
            if !trimmedQuery.isEmpty { searchText = "" }
        }
        .onChange(of: scenePhase) { _, phase in
            // アプリがバックグラウンド (非表示) になったら全シートを再ロック。
            if phase == .background { lockManager.lockAll() }
            // 前面化時に iCloud サインイン状態を再取得。
            if phase == .active { PersistenceController.shared.refreshAccountStatus() }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSheet) {
            if sheets.isEmpty {
                Section {
                    Label("シートがありません", systemImage: "tray")
                        .foregroundStyle(.secondary)
                }
            } else {
                let activeSheets = sheets.filter { !$0.archived }
                let archivedSheets = sheets.filter { $0.archived }
                ForEach(activeSheets) { sheet in
                    NavigationLink(value: sheet) {
                        sheetRow(sheet)
                    }
                    .tag(sheet)
                }
                if !archivedSheets.isEmpty {
                    Section("アーカイブ済み") {
                        ForEach(archivedSheets) { sheet in
                            NavigationLink(value: sheet) {
                                sheetRow(sheet)
                            }
                            .tag(sheet)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("シート・支出を検索"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            profileFooter
        }
        .toolbar {
            ToolbarItem {

            }
            ToolbarItem {
                Button {
                    tryShowAddSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .help("シートを追加")
            }
        }
        // 列幅の制約は列ルートの最外で適用しないと max が効かず、
        // サイドバーを無限に広げられてしまう (.searchable などより後に置く)。
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
    }

    /// Free 上限・同期状態を確認してから新規シート作成ダイアログを出す (iOS と同じゲート)。
    /// 無料プランは自分が作成したシートを `FreeTierLimits.ownedSheets` 個までに制限する。
    private func tryShowAddSheet() {
        switch PurchaseManager.sheetCreationGate() {
        case .allowed:
            showingAddSheet = true
        case .notSignedIn:
            showNotSignedInAlert = true
            Haptics.warning()
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

    /// Apple Music の sidebar footer 風プロフィール行。タップで ProfileEditView を開く。
    private var profileFooter: some View {
        Button {
            showingProfileEdit = true
        } label: {
            HStack(spacing: 10) {
                AvatarView(
                    photoData: profile.photoData,
                    displayName: profile.resolvedDisplayName,
                    colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                    size: 28
                )
                Text(profile.resolvedDisplayName)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("プロフィールを編集")
        .background(.bar)
    }

    private func sheetRow(_ sheet: ExpenseSheet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(sheet.tint.gradient)
                    .frame(width: 36, height: 36)
                Image(systemName: sheet.symbol ?? "person.2.fill")
                    .foregroundStyle(.white)
                    .font(.callout.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sheet.displayName).font(.body.weight(.medium))
                Text(monthlyLabel(for: sheet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if lockManager.hasPassword(for: sheet) {
                    // 解錠中 (このセッションでパスワード入力済み) は開いた鍵を表示。
                    Image(systemName: lockManager.isUnlocked(sheet) ? "lock.open.fill" : "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if sheet.isOwnedByCurrentUser == false {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func monthlyLabel(for sheet: ExpenseSheet) -> String {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let monthlyTotal = ((sheet.expenses as? Set<Expense>) ?? [])
            .filter { e in
                guard let d = e.date, e.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: d)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        return "今月 \(CurrencyCatalog.format(monthlyTotal, code: sheet.resolvedDefaultCurrencyCode))"
    }

    // MARK: - 全シート横断検索

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

    /// 名前がクエリにマッチするシート。
    private var matchedSheetsForSearch: [ExpenseSheet] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        return sheets.filter { $0.displayName.lowercased().contains(q) }
    }

    /// ロック中 (パスワードあり & 未解錠) のシート。中身は検索対象外。
    private var lockedSheetsForSearch: [ExpenseSheet] {
        sheets.filter { lockManager.hasPassword(for: $0) && !lockManager.isUnlocked($0) }
    }

    private struct MacExpenseMatchGroup: Identifiable {
        let sheet: ExpenseSheet
        let expenses: [Expense]
        let net: Decimal
        let currency: String
        var id: NSManagedObjectID { sheet.objectID }
    }

    /// 支出/収入がクエリにマッチするものを所属シートごとにまとめる (ロック中は除外)。
    private var expenseMatchGroups: [MacExpenseMatchGroup] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        var groups: [MacExpenseMatchGroup] = []
        for sheet in sheets {
            if lockManager.hasPassword(for: sheet) && !lockManager.isUnlocked(sheet) { continue }
            guard let exps = sheet.expenses as? Set<Expense> else { continue }
            let matched = exps
                .filter { matchesExpense($0, query: q) }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            guard !matched.isEmpty else { continue }
            let target = sheet.resolvedDefaultCurrencyCode
            var net: Decimal = 0
            for e in matched {
                let amt = fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal
                net += (e.kind == .income) ? amt : -amt
            }
            groups.append(MacExpenseMatchGroup(sheet: sheet, expenses: matched, net: net, currency: target))
        }
        return groups
    }

    private var totalMatchCount: Int {
        expenseMatchGroups.reduce(0) { $0 + $1.expenses.count }
    }

    private func openFromSearch(_ sheet: ExpenseSheet) {
        selectedSheet = sheet
        searchText = ""
    }

    private func netString(_ net: Decimal, code: String) -> String {
        let sign = net > 0 ? "+" : (net < 0 ? "-" : "")
        return sign + CurrencyCatalog.format(net.magnitude, code: code)
    }

    /// 全シート横断のヒット合計を target 通貨に換算して集計する。
    private func grandTotal(of groups: [MacExpenseMatchGroup], target: String)
        -> (expense: Decimal, income: Decimal, mixed: Bool, count: Int) {
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
        return (expenseSum, incomeSum, currencies.count > 1, count)
    }

    /// iOS の SearchTotalCard 相当: 検索ヒットの合計を表示するカード。
    @ViewBuilder
    private func searchSummaryCard(_ groups: [MacExpenseMatchGroup]) -> some View {
        let total = grandTotal(of: groups, target: searchTotalCurrency)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white)
                        .font(.system(size: 18, weight: .semibold))
                }
                .frame(width: 40, height: 40)
                Text("検索結果").font(.title3.weight(.semibold))
                Spacer()
                searchCurrencyMenu
            }
            Text(trimmedQuery.isEmpty ? "\(total.count)件" : "「\(trimmedQuery)」 · \(total.count)件")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(CurrencyCatalog.format(total.expense, code: searchTotalCurrency))
                .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(reduceMotion ? .identity : .numericText(value: NSDecimalNumber(decimal: total.expense).doubleValue))
                .animation(reduceMotion ? nil : .snappy, value: total.expense)
            HStack(spacing: 12) {
                Text("+ \(CurrencyCatalog.format(total.income, code: searchTotalCurrency))")
                Text("|").foregroundStyle(.tertiary)
                Text("- \(CurrencyCatalog.format(total.expense, code: searchTotalCurrency))")
            }
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            if total.mixed {
                Label("複数通貨を \(searchTotalCurrency) に換算して合計しています",
                      systemImage: "arrow.left.arrow.right")
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

    /// 合計の表示通貨を切り替えるメニュー。
    private var searchCurrencyMenu: some View {
        Menu {
            Picker("通貨", selection: $searchTotalCurrency) {
                ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                    Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(searchTotalCurrency)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultCard<H: View, C: View>(
        @ViewBuilder header: () -> H,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header().font(.subheadline.weight(.semibold))
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                )
        }
    }

    private func sheetHitRow(_ sheet: ExpenseSheet) -> some View {
        HStack(spacing: 12) {
            SheetIconView(record: sheet, size: 32)
            Text(sheet.displayName).font(.body)
            Spacer()
            if lockManager.hasPassword(for: sheet) {
                Image(systemName: lockManager.isUnlocked(sheet) ? "lock.open.fill" : "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func searchExpenseRow(_ e: Expense) -> some View {
        HStack(spacing: 12) {
            CategoryIconView(expense: e, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.displayTitle.isEmpty ? e.categoryDisplayName : e.displayTitle)
                    .font(.body).foregroundStyle(.primary).lineLimit(1)
                if let d = e.date {
                    Text(d, format: .dateTime.year().month().day())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(e.formattedSignedAmount)
                .font(.callout.monospacedDigit()).foregroundStyle(.primary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var searchResultsDetail: some View {
        let groups = expenseMatchGroups
        let matched = matchedSheetsForSearch
        let locked = lockedSheetsForSearch
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 検索ヒットの合計カード (iOS の SearchTotalCard 相当)。常に表示。
                searchSummaryCard(groups)

                if groups.isEmpty && matched.isEmpty && locked.isEmpty {
                    Text(trimmedQuery.isEmpty
                         ? "検索ワードを入力してください"
                         : "「\(trimmedQuery)」に一致する項目がありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }

                // シート名ヒット
                if !matched.isEmpty {
                    resultCard {
                        Label("シート", systemImage: "rectangle.stack.fill")
                    } content: {
                        ForEach(Array(matched.enumerated()), id: \.element.objectID) { idx, sheet in
                            Button { openFromSearch(sheet) } label: { sheetHitRow(sheet) }
                                .buttonStyle(.plain)
                            if idx < matched.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }

                // 支出ヒット (シート別)
                ForEach(groups) { group in
                    resultCard {
                        HStack {
                            Label(group.sheet.displayName, systemImage: "tray.full")
                                .foregroundStyle(group.sheet.tint)
                            Spacer()
                            Text(netString(group.net, code: group.currency))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } content: {
                        ForEach(Array(group.expenses.enumerated()), id: \.element.objectID) { idx, e in
                            Button { openFromSearch(group.sheet) } label: { searchExpenseRow(e) }
                                .buttonStyle(.plain)
                            if idx < group.expenses.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }

                // ロック中シート (解除導線)
                if !locked.isEmpty {
                    resultCard {
                        Label("ロック中のシート", systemImage: "lock.fill")
                    } content: {
                        ForEach(Array(locked.enumerated()), id: \.element.objectID) { idx, sheet in
                            // インラインの解錠モーダルを出す。検索からは離れないので
                            // 複数シートを続けて解錠できる (selectedSheet を変えないため
                            // 直前に解錠したシートが再ロックされない)。
                            Button { unlockingSheet = sheet } label: {
                                HStack(spacing: 12) {
                                    SheetIconView(record: sheet, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sheet.displayName).font(.body).foregroundStyle(.primary)
                                        Text("ロック中 · 解除して検索に含める")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if idx < locked.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Add Sheet

struct MacAddSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @State private var name: String = ""
    @State private var colorHex: String = "#5B8DEF"
    @State private var symbol: String = "person.2.fill"
    @State private var currencyCode: String = CurrencyCatalog.defaultCode

    var body: some View {
        MacSheetFormDialog(
            title: "新規シート",
            name: $name,
            colorHex: $colorHex,
            symbol: $symbol,
            currencyCode: $currencyCode,
            primaryActionLabel: "OK",
            onCancel: { dismiss() },
            onSave: { save() }
        )
    }

    private func save() {
        let sheet = ExpenseSheet(context: viewContext)
        sheet.name = name.trimmingCharacters(in: .whitespaces)
        sheet.colorHex = colorHex
        sheet.symbol = symbol
        sheet.defaultCurrencyCode = currencyCode
        sheet.createdAt = .now
        PersistenceController.seedDefaultCategories(for: sheet, in: viewContext)
        PersistenceController.shared.save()
        Task { @MainActor in
            await UserProfileStore.shared.ensureUserRecordNameLoaded()
            UserProfileStore.shared.ensureSelfMemberExists(in: viewContext)
            UserProfileStore.shared.ensureProfile(in: sheet, ctx: viewContext)
        }
        dismiss()
    }
}

// MARK: - Edit Sheet (Mac)

/// Mac 用シート編集ダイアログ。リマインダー風のコンパクトなレイアウト。
struct MacEditSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var record: ExpenseSheet

    @State private var name: String = ""
    @State private var colorHex: String = "#5B8DEF"
    @State private var symbol: String = "person.2.fill"
    @State private var currencyCode: String = CurrencyCatalog.defaultCode
    /// 編集ドラフト。「保存」を押すまで record には書かない。
    @State private var archivedDraft: Bool = false
    @State private var didLoad: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    /// バーチャルメンバー管理シート表示。
    @State private var showingMembers: Bool = false

    var body: some View {
        MacSheetFormDialog(
            title: "シートを編集",
            name: $name,
            colorHex: $colorHex,
            symbol: $symbol,
            currencyCode: $currencyCode,
            archiveBinding: $archivedDraft,
            manageMembersAction: { showingMembers = true },
            primaryActionLabel: "保存",
            destructiveAction: { showingDeleteConfirm = true },
            onCancel: { dismiss() },
            onSave: { save() }
        )
        .onAppear { loadOnce() }
        .confirmationDialog(
            "「\(name)」を削除しますか？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                viewContext.delete(record)
                PersistenceController.shared.save()
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("配下の支出・カテゴリ・送金記録もすべて削除されます。")
        }
        .sheet(isPresented: $showingMembers) {
            NavigationStack {
                VirtualMemberListView(record: record)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { showingMembers = false }
                        }
                    }
            }
            .frame(minWidth: 480, minHeight: 480)
        }
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        name = record.displayName
        colorHex = record.colorHex ?? "#5B8DEF"
        symbol = record.symbol ?? "person.2.fill"
        currencyCode = record.resolvedDefaultCurrencyCode
        archivedDraft = record.archived
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        record.name = trimmed
        record.colorHex = colorHex
        record.symbol = symbol
        record.defaultCurrencyCode = currencyCode
        if record.archived != archivedDraft { record.archived = archivedDraft }
        PersistenceController.shared.save()
        dismiss()
    }
}

// MARK: - Shared dialog

/// リマインダー風の縦コンパクトなシート設定ダイアログ。Add / Edit 両方で使う。
private struct MacSheetFormDialog: View {
    let title: String
    @Binding var name: String
    @Binding var colorHex: String
    @Binding var symbol: String
    @Binding var currencyCode: String
    /// nil でない時のみアーカイブ Toggle 行を出す (= Edit のみ)。
    /// Add 時はシートがまだ存在しないので非表示。
    var archiveBinding: Binding<Bool>? = nil
    /// nil でない時のみ「メンバー管理」ボタンを出す (= Edit のみ)。
    /// バーチャルメンバーの追加 / 編集 / 削除を行う別シートを開く。
    var manageMembersAction: (() -> Void)? = nil
    let primaryActionLabel: String
    var destructiveAction: (() -> Void)? = nil
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var showingSymbolPicker: Bool = false
    @State private var showingPaywall: Bool = false
    @StateObject private var pm = PurchaseManager.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// AX サイズなら column を縦に積む。
    private var useStackedLayout: Bool {
        dynamicTypeSize >= .accessibility1
    }

    /// テキストサイズに応じてラベル列の幅を計算 (= ラベルが折り返さないように)
    private var labelColumnWidth: CGFloat {
        switch dynamicTypeSize {
        case .accessibility5, .accessibility4: return 140
        case .accessibility3, .accessibility2: return 120
        case .accessibility1, .xxxLarge:       return 100
        default:                               return 80
        }
    }

    /// リマインダー準拠の 12 色パレット。
    private let palette: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#5B8DEF",
        "#5856D6", "#FF2D55", "#AF52DE", "#A2845E", "#8E8E93", "#FFB1C8"
    ]

    /// 現在選択中のカラー (フォールバックはアクセントカラー)。
    private var selectedColor: Color {
        Color(hex: colorHex) ?? .accentColor
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ヘッダ (タブ風タイトル)
                HStack {
                    Spacer()
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selectedColor))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.bottom, 14)

                // フォーム
                VStack(spacing: 16) {
                    // 名前
                    formRow(label: "名前:") {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // カラー + アイコン (AX サイズなら縦並び)
                    colorAndIconRow

                    Divider().padding(.top, 4)

                    // 既定通貨
                    formRow(label: "既定通貨:") {
                        Picker("", selection: $currencyCode) {
                            ForEach(CurrencyCatalog.all) { opt in
                                Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320, alignment: .leading)
                        Spacer(minLength: 0)
                    }

                    if let manageMembersAction {
                        Divider().padding(.top, 4)
                        formRow(label: "メンバー:") {
                            Button {
                                manageMembersAction()
                            } label: {
                                Label("バーチャルメンバーを管理", systemImage: "person.2")
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    if let archiveBinding {
                        Divider().padding(.top, 4)
                        formRow(label: "アーカイブ:") {
                            Toggle(isOn: archiveBinding) {
                                Text("このシートをアーカイブ")
                            }
                            .toggleStyle(.switch)
                            Spacer(minLength: 0)
                        }
                    }

                    Divider().padding(.top, 4)

                    // ボタン
                    HStack {
                        if let destructiveAction {
                            Button {
                                destructiveAction()
                            } label: {
                                Text("削除")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        Spacer()
                        Button("キャンセル") { onCancel() }
                        Button(primaryActionLabel) { onSave() }
                            .keyboardShortcut(.return)
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            }
        }
        .scrollIndicators(.never)
        .frame(width: 560)
        .frame(minHeight: 280, maxHeight: 720)
    }

    /// label が AX サイズで折り返す前提のラベル付き行。狭い時は縦並び。
    @ViewBuilder
    private func formRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if useStackedLayout {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                content()
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .frame(width: labelColumnWidth, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    /// カラー + アイコン 行。AX サイズでは縦に積む。
    @ViewBuilder
    private var colorAndIconRow: some View {
        if useStackedLayout {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("カラー:")
                    colorGrid
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("アイコン:")
                    symbolPickerButton
                }
            }
        } else {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text("カラー:")
                            .frame(width: labelColumnWidth, alignment: .trailing)
                        colorGrid
                    }
                }
                Divider().frame(height: 60)
                HStack(spacing: 10) {
                    Text("アイコン:")
                    symbolPickerButton
                }
            }
        }
    }

    private var colorGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(28), spacing: 10), count: 6)
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(palette, id: \.self) { hex in
                let isOn = (hex == colorHex)
                Circle()
                    .fill(Color(hex: hex) ?? .blue)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if isOn {
                            Circle()
                                .stroke(Color(hex: hex) ?? .blue, lineWidth: 2)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { colorHex = hex }
            }
        }
    }

    private var symbolPickerButton: some View {
        Button {
            showingSymbolPicker.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(selectedColor)
                    .frame(width: 44, height: 44)
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSymbolPicker, arrowEdge: .top) {
            symbolGrid
        }
    }

    private var symbolGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SheetSymbols.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(section.symbols, id: \.self) { sym in
                                symbolButton(sym)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .frame(width: 320, height: 360)
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }

    @ViewBuilder
    private func symbolButton(_ sym: String) -> some View {
        let isSelected = (symbol == sym)
        let isLocked = SheetSymbols.isPremiumSymbol(sym) && !pm.isPremium
        Button {
            if isLocked {
                showingPaywall = true
            } else {
                symbol = sym
                showingSymbolPicker = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected
                          ? AnyShapeStyle(selectedColor)
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 36, height: 36)
                if isSelected {
                    Circle()
                        .stroke(selectedColor, lineWidth: 2)
                        .frame(width: 40, height: 40)
                }
                Image(systemName: sym)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .opacity(isLocked ? 0.45 : 1)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 13, y: 13)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct BudgetyMacSettingsView: View {
    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pm = PurchaseManager.shared
    @State private var shareURLText: String = ""
    @State private var acceptInProgress: Bool = false
    @State private var acceptMessage: String?
    @State private var showingPaywall: Bool = false
    @State private var showingProfileEdit: Bool = false
    @State private var showingClaudeIntegration: Bool = false

    var body: some View {
        Form {
            Section("プロフィール") {
                Button {
                    showingProfileEdit = true
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(
                            photoData: profile.photoData,
                            displayName: profile.resolvedDisplayName,
                            colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                            size: 40
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.resolvedDisplayName)
                                .foregroundStyle(.primary)
                            Text("名前・写真・背景色を編集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            Section("Premium") {
                HStack(spacing: 12) {
                    Image(systemName: pm.isPremium ? "crown.fill" : "crown")
                        .foregroundStyle(pm.isPremium ? .yellow : .secondary)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(pm.isPremium ? "Premium 加入中" : "無料プラン")
                            .font(.body.weight(.medium))
                        Text(pm.isPremium
                             ? "すべての機能をご利用いただけます。"
                             : "Premium にすると共有招待やカテゴリ追加など追加機能が解放されます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if pm.isPremium {
                    Link("サブスクリプションを管理",
                         destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                } else {
                    Button {
                        showingPaywall = true
                    } label: {
                        Label("Premium にアップグレード", systemImage: "crown.fill")
                    }
                    Button {
                        Task { await pm.restore() }
                    } label: {
                        if pm.isProcessing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("復元中…")
                            }
                        } else {
                            Label("購入を復元", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(pm.isProcessing)
                }
            }

            Section {
                TextField("https://www.icloud.com/share/...", text: $shareURLText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        Task { await acceptURL() }
                    } label: {
                        if acceptInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("URL を貼り付けて参加")
                        }
                    }
                    .disabled(shareURLText.isEmpty || acceptInProgress)
                    Spacer()
                }
                if let acceptMessage {
                    Text(acceptMessage)
                        .font(.caption)
                        .foregroundStyle(acceptMessage.contains("失敗") ? .red : .secondary)
                }
            } header: {
                Text("共有シートに参加")
            } footer: {
                Text("メールで届いた共有リンク (https://www.icloud.com/share/... または cloudkit-... など) を貼り付けて参加できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    showingClaudeIntegration = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple.gradient)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude と連携")
                                .foregroundStyle(.primary)
                            Text("自然言語で支出を記録")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            Section("バージョン") {
                LabeledContent("Budgety", value: "1.0")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPaywall) {
            MacModalSheet { PaywallView() }
        }
        .sheet(isPresented: $showingProfileEdit) {
            ProfileEditView()
        }
        .sheet(isPresented: $showingClaudeIntegration) {
            MacModalSheet {
                ClaudeIntegrationView()
                    .padding()
            }
        }
    }

    @MainActor
    private func acceptURL() async {
        let trimmed = shareURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            acceptMessage = "URL の形式が正しくありません"
            return
        }
        acceptInProgress = true
        defer { acceptInProgress = false }
        do {
            // AppDelegate を取り出してメソッド経由で受諾
            if let delegate = NSApp.delegate as? BudgetyMacAppDelegate {
                try await delegate.acceptShareURL(url)
                acceptMessage = "受諾を実行しました (シートが現れるまで数秒)"
                shareURLText = ""
            } else {
                acceptMessage = "AppDelegate が見つかりません"
            }
        } catch {
            acceptMessage = "失敗: \(error.localizedDescription)"
        }
    }
}

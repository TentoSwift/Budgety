//
//  BudgetyMacSheetView.swift
//  Budgety For macOS
//
//  iOS 版 SheetDetailView 相当 (macOS 用ミニマル実装)。
//  - ヒーロー: 月合計
//  - 日付グルーピングの支出一覧
//  - ツールバー: 追加ボタン
//

import SwiftUI
import CoreData
import CloudKit
import UniformTypeIdentifiers

/// 支出の支払い者が指定 profileID と一致するか。「自分」(selfIDs のいずれか) を
/// 選んだ場合は、payerProfileID が selfIDs に含まれれば一致とみなす (旧 ID 対応)。
fileprivate func macExpensePayerMatches(_ exp: Expense, payerID: String, selfIDs: Set<String>) -> Bool {
    let pid = exp.payerProfileID ?? ""
    if selfIDs.contains(payerID) {
        return selfIDs.contains(pid)
    }
    return pid == payerID
}

struct BudgetyMacSheetView: View {
    @ObservedObject var sheet: ExpenseSheet
    @Environment(\.managedObjectContext) private var viewContext
    /// Reduce Motion 時は数値ロール・一覧アニメーションを止める。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pub = PublicProfileSync.shared
    /// FX レート更新で月合計 / 日合計を再計算するために observe する。
    @ObservedObject private var fx = FXRatesService.shared

    @State private var showingAdd: Bool = false
    @State private var editingExpense: Expense?
    @State private var showingSettlement = false
    @State private var showingCategories = false
    @State private var showingRecurring = false
    @State private var showingEditSheet = false
    @State private var showingAIChat = false
    @State private var showingCSVImport = false
    @State private var showingStats = false
    @State private var showingShare = false
    /// サマリーヒーローが画面外までスクロールしたか。
    /// true のときだけツールバーのタイトルにシート名を出す (= iOS の fade 風)。
    @State private var isScrolledPastHero = false

    @StateObject private var lockManager = SheetLockManager.shared
    @State private var showingSetPassword = false
    @State private var showingLockPaywall = false

    // エクスポート (CSV / PDF)。Premium 機能。
    @State private var showingExportPaywall = false
    @State private var showingExporter = false
    @State private var exportDocument: ExportFileDocument?
    @State private var exportContentType: UTType = .commaSeparatedText
    @State private var exportFilename = "Budgety"

    // フィルタ
    @State private var searchText: String = ""
    @State private var selectedCategory: ExpenseCategory?
    @State private var selectedPayerID: String?
    @State private var period: Period = .thisMonth

    /// 集計・一覧の対象期間 (iOS の SheetDetailView.Period 相当)。
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

    private var allExpenses: [Expense] {
        ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// カテゴリ・支払い者・検索クエリで絞り込む (期間は含めない)。
    /// 期間ピッカーは合計にのみ反映する仕様なので、期間の適用は呼び出し側で行う。
    private func applyNonPeriodFilters(_ input: [Expense]) -> [Expense] {
        var list = input
        if let cat = selectedCategory {
            list = list.filter { $0.category?.objectID == cat.objectID }
        }
        if let payerID = selectedPayerID {
            let selfIDs = UserProfileStore.shared.canonicalSelfIDs(
                forShare: ShareCoordinator.shared.existingShare(for: sheet))
            list = list.filter { macExpensePayerMatches($0, payerID: payerID, selfIDs: selfIDs) }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayTitle.lowercased().contains(q)
                    || $0.categoryDisplayName.lowercased().contains(q)
                    || $0.displayPaidBy.lowercased().contains(q)
                    || ($0.note ?? "").lowercased().contains(q)
            }
        }
        return list
    }

    /// サマリー合計用の支出。期間ピッカーで選んだ期間 + カテゴリ・支払い者・検索を適用。
    /// 期間は「合計のみ」に反映するため、こちらは常に period で絞り込む。
    private var summaryExpenses: [Expense] {
        applyNonPeriodFilters(allExpenses.filter { period.contains($0.date) })
    }

    /// 一覧表示用の支出。通常時は期間を適用せず全期間を表示する
    /// (期間ピッカーは合計のみに反映)。検索中のみ期間も適用する (iOS の挙動に合わせる)。
    private var listExpenses: [Expense] {
        let base = applyNonPeriodFilters(allExpenses)
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return isSearching ? base.filter { period.contains($0.date) } : base
    }

    /// 絞り込みが有効か。
    private var isFiltering: Bool {
        selectedCategory != nil || selectedPayerID != nil
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 支出があるカテゴリ一覧 (フィルタ用、sortOrder 順)。
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

    private var groupedByDate: [(date: Date, items: [Expense])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: listExpenses) { exp -> Date in
            cal.startOfDay(for: exp.date ?? .now)
        }
        return dict.map { (date: $0.key, items: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private var monthlyTotal: Decimal {
        monthlyTotals.expense
    }

    /// 今月の支出 / 収入 合計 (シート既定通貨に FX 換算済み)。
    private var monthlyTotals: (expense: Decimal, income: Decimal) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: .now)
        let target = sheet.resolvedDefaultCurrencyCode
        let fx = FXRatesService.shared
        var expense: Decimal = 0
        var income: Decimal = 0
        for e in allExpenses {
            guard let d = e.date else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            guard c.year == comps.year && c.month == comps.month else { continue }
            // 通貨が違えば FX 換算。失敗 (レート未取得) は加算しない。
            let from = e.resolvedCurrencyCode
            let converted: Decimal?
            if from == target {
                converted = e.amountDecimal
            } else {
                converted = fx.convert(e.amountDecimal, from: from, to: target)
            }
            guard let amount = converted else { continue }
            if e.kind == .expense { expense += amount }
            else if e.kind == .income { income += amount }
        }
        return (expense, income)
    }

    /// 月予算残額。予算未設定なら nil。
    private var monthlyRemainingBudget: Decimal? {
        guard let budget = sheet.monthlyBudgetDecimal, budget > 0 else { return nil }
        return budget - monthlyTotal
    }

    /// サマリー合計 (summaryExpenses をシート既定通貨に FX 換算)。
    /// 期間ピッカー + 検索/カテゴリ/支払い者を反映する (一覧とは別に期間を適用)。
    private var filteredTotals: (expense: Decimal, income: Decimal) {
        let target = sheet.resolvedDefaultCurrencyCode
        let fx = FXRatesService.shared
        var expense: Decimal = 0
        var income: Decimal = 0
        for e in summaryExpenses {
            let from = e.resolvedCurrencyCode
            let converted = (from == target) ? e.amountDecimal : fx.convert(e.amountDecimal, from: from, to: target)
            guard let amount = converted else { continue }
            if e.kind == .expense { expense += amount }
            else if e.kind == .income { income += amount }
        }
        return (expense, income)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryHero
                // 参加者が自分だけ (solo) のときはメンバー表示を出さない。
                if currentMemberIDs.count > 1 {
                    membersStrip
                }
                if !usedCategories.isEmpty {
                    categoryPills
                }
                expensesList
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("支出・収入を検索"))
        // 別シートへ切り替わったらフィルタ (検索・カテゴリ・支払者) を解除する。
        // detail の BudgetyMacSheetView は位置が同じため再生成されず @State が残るので、
        // sheet の変化を検知して明示的にクリアする。
        .onChange(of: sheet.objectID) { _, _ in
            clearFilters()
        }
        // スクロール量を直接監視 (macOS 15+/26 で確実に動く)。
        // ヒーローの高さぶん (約 140pt) スクロールしたら「通り過ぎた」とみなす。
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, offsetY in
            let scrolledPast = offsetY > 120
            if scrolledPast != isScrolledPastHero {
                withAnimation(.easeIn(duration: 0.15)) {
                    isScrolledPastHero = scrolledPast
                }
            }
        }
        // スクロール前は空文字、ヒーローを通り過ぎたらシート名を三項演算子で代入。
        .navigationTitle(isScrolledPastHero ? sheet.displayName : "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("支出を追加", systemImage: "plus")
                }
                .help("支出を追加")
            }
            ToolbarItem {
                Menu {
                    Button { showingSettlement = true } label: {
                        Label("精算", systemImage: "yensign.circle")
                    }
                    Button { showingStats = true } label: {
                        Label("統計", systemImage: "chart.bar.xaxis")
                    }
                    Button { showingAIChat = true } label: {
                        Label("AI チャット", systemImage: "sparkles")
                    }
                    Divider()
                    Button { showingCategories = true } label: {
                        Label("カテゴリ管理", systemImage: "square.grid.2x2")
                    }
                    Button { showingRecurring = true } label: {
                        Label("繰り返し項目", systemImage: "repeat")
                    }
                    Divider()
                    Button { showingShare = true } label: {
                        Label("シートを共有", systemImage: "person.crop.circle.badge.plus")
                    }
                    Button { startExport(.csv) } label: {
                        Label("CSV にエクスポート", systemImage: "doc.text")
                    }
                    Button { startExport(.pdf) } label: {
                        Label("PDF レポート", systemImage: "doc.richtext")
                    }
                    Button { showingCSVImport = true } label: {
                        Label("CSV インポート", systemImage: "tray.and.arrow.down")
                    }
                    Button { showingEditSheet = true } label: {
                        Label("シートを編集", systemImage: "pencil")
                    }
                    Divider()
                    if lockManager.hasPassword(for: sheet) {
                        Button { lockManager.lock(sheet) } label: {
                            Label("今すぐロック", systemImage: "lock.fill")
                        }
                        if sheet.isOwnedByCurrentUser {
                            Button { presentLockSetup() } label: {
                                Label("ロック設定を変更", systemImage: "key.fill")
                            }
                        }
                    } else if sheet.isOwnedByCurrentUser {
                        Button { presentLockSetup() } label: {
                            Label("シートをロック", systemImage: "lock")
                        }
                    }
                } label: {
                    Label("その他", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("その他")
            }
        }
        .sheet(isPresented: $showingAdd) {
            MacAddExpenseView(sheet: sheet, expense: nil)
        }
        .sheet(item: $editingExpense) { e in
            MacAddExpenseView(sheet: sheet, expense: e)
        }
        .sheet(isPresented: $showingSettlement) {
            MacModalSheet { SettlementView(record: sheet) }
        }
        .sheet(isPresented: $showingCategories) {
            MacModalSheet { CategoryListView(record: sheet) }
        }
        .sheet(isPresented: $showingRecurring) {
            MacModalSheet { RecurringListView(record: sheet) }
        }
        .sheet(isPresented: $showingEditSheet) {
            MacEditSheetView(record: sheet)
        }
        .sheet(isPresented: $showingAIChat) {
            MacModalSheet { SheetAIChatView(record: sheet) }
        }
        .sheet(isPresented: $showingCSVImport) {
            MacModalSheet { CSVImportView(sheet: sheet) }
        }
        .sheet(isPresented: $showingStats) {
            MacModalSheet { StatsView(record: sheet) }
        }
        .sheet(isPresented: $showingShare) {
            MacShareSheetView(sheet: sheet)
        }
        .sheet(isPresented: $showingSetPassword) {
            MacModalSheet { SetSheetPasswordView(record: sheet) }
        }
        .sheet(isPresented: $showingLockPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showingExportPaywall) {
            PaywallView()
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .success = result { Haptics.success() }
        }
    }

    /// Premium ならロック設定画面を、未加入なら Paywall を開く。
    /// (ロックは Premium 機能。オーナー判定は SetSheetPasswordView 側でも行う)
    private func presentLockSetup() {
        if PurchaseManager.shared.isPremium {
            showingSetPassword = true
        } else {
            showingLockPaywall = true
        }
    }

    private func clearFilters() {
        searchText = ""
        selectedCategory = nil
        selectedPayerID = nil
    }

    private enum ExportFormat { case csv, pdf }

    /// CSV / PDF エクスポート。Premium (または共有シート参加) で gate し、
    /// 通れば `.fileExporter` (保存パネル) を出す。
    private func startExport(_ format: ExportFormat) {
        guard PurchaseManager.hasPremiumAccess(to: sheet) else {
            showingExportPaywall = true
            Haptics.warning()
            return
        }
        let safe = sheet.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined()
        switch format {
        case .csv:
            exportDocument = ExportFileDocument(data: SheetExporter.makeCSV(for: sheet), type: .commaSeparatedText)
            exportContentType = .commaSeparatedText
            exportFilename = "Budgety-\(safe).csv"
        case .pdf:
            guard let url = SheetExporter.writePDF(for: sheet),
                  let data = try? Data(contentsOf: url) else {
                Haptics.warning()
                return
            }
            exportDocument = ExportFileDocument(data: data, type: .pdf)
            exportContentType = .pdf
            exportFilename = "Budgety-\(safe).pdf"
        }
        showingExporter = true
        Haptics.success()
    }

    /// 期間ピッカー (今月 / 先月 / 今年 / 全期間)。合計 (サマリー) のみに反映し、
    /// 一覧は通常時は全期間を表示する (検索中のみ一覧にも反映)。
    private var periodMenu: some View {
        Menu {
            Picker("期間", selection: $period) {
                ForEach(Period.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(period.label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var summaryHero: some View {
        let filtering = isFiltering
        // 期間 + 検索/カテゴリ/支払い者の絞り込みを反映した合計。
        let t = filteredTotals
        let code = sheet.resolvedDefaultCurrencyCode
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(sheet.tint.gradient)
                        Image(systemName: sheet.symbol ?? "person.2.fill")
                            .foregroundStyle(.white)
                            .font(.callout.weight(.semibold))
                    }
                    .frame(width: 40, height: 40)
                    // 検索/フィルタ中はアイコン右下に虫眼鏡バッジ (iOS の SummaryCard と同じ)
                    if filtering {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.platformSystemBackground)
                            .padding(4)
                            .background(Circle().fill(Color.primary))
                            .overlay(Circle().stroke(Color.platformSystemBackground, lineWidth: 1.5))
                            .offset(x: 4, y: 4)
                    }
                }
                Text(sheet.displayName).font(.title3.weight(.semibold))
                Spacer()
                if filtering {
                    Text("\(listExpenses.count)件")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            periodMenu
            Text(CurrencyCatalog.format(t.expense, code: code))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(value: NSDecimalNumber(decimal: t.expense).doubleValue))
                .animation(reduceMotion ? nil : .snappy, value: t.expense)

            // 合計の下に「+収入 | -支出」のサマリ行 (左寄せ)
            HStack(spacing: 12) {
                Text("+ \(CurrencyCatalog.format(t.income, code: code))")
                Text("|").foregroundStyle(.tertiary)
                Text("- \(CurrencyCatalog.format(t.expense, code: code))")
            }
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 残予算 (今月 + 予算設定時 + 非フィルタ時のみ)
            if period == .thisMonth, !filtering, let remaining = monthlyRemainingBudget {
                HStack(spacing: 6) {
                    Circle()
                        .fill(remaining < 0 ? Color.red : Color.primary)
                        .frame(width: 8, height: 8)
                    Text("残予算")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(CurrencyCatalog.format(remaining, code: code))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(remaining < 0 ? .red : .primary)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(sheet.tint.opacity(0.12))
        )
    }

    /// シートの参加者一覧 (Apple ID 名 + アバター)。
    /// 名前が "メンバー" になっていれば PP/CKShare がまだ来ていない or
    /// エンタイトルメントの効果が及んでいない可能性あり。
    /// 「今いるメンバー」= 自分 + CKShare で受諾済みの参加者のみ。
    /// 招待中 (.pending) や解除済みの ParticipantProfile は除外する。
    /// CKShare 未ロード時 (solo / 取得前) は allMemberProfileIDs にフォールバック。
    private var currentMemberIDs: [String] {
        // 自分 + 受諾済み参加者 + バーチャルメンバー。
        // acceptedMemberProfileIDs は CKShare 未ロード時は PP にフォールバックしつつ、
        // CKShare に出ないバーチャルメンバーも含める。
        sheet.acceptedMemberProfileIDs()
    }

    private var membersStrip: some View {
        let ids = currentMemberIDs
        return HStack(spacing: 12) {
            ForEach(ids, id: \.self) { id in
                let info = sheet.memberDisplayInfo(for: id)
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
                        .overlay(
                            Circle().strokeBorder(sheet.tint, lineWidth: isSelected ? 2.5 : 0)
                        )
                        Text(info.name)
                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(isSelected ? sheet.tint : .secondary)
                    }
                    .frame(maxWidth: 80)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "フィルタを解除" : "\(info.name) の支出で絞り込む")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    /// カテゴリ絞り込みのチップ列 (すべて + 使用中カテゴリ)。
    private var categoryPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedCategory = nil
                } label: {
                    Text("すべて")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selectedCategory == nil ? sheet.tint : Color.gray.opacity(0.2)))
                        .foregroundStyle(selectedCategory == nil ? .white : .primary)
                }
                .buttonStyle(.plain)

                ForEach(usedCategories, id: \.objectID) { cat in
                    let isSelected = selectedCategory?.objectID == cat.objectID
                    Button {
                        selectedCategory = isSelected ? nil : cat
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: cat.displaySymbol)
                            Text(cat.displayName)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isSelected ? cat.tint : Color.gray.opacity(0.2)))
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var expensesList: some View {
        VStack(spacing: 16) {
            if groupedByDate.isEmpty {
                if isFiltering {
                    ContentUnavailableView {
                        Label("該当する支出がありません", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("検索条件やフィルタを変更してください。")
                    } actions: {
                        Button("フィルタをクリア") { clearFilters() }
                    }
                    .padding(.vertical, 40)
                } else {
                    ContentUnavailableView {
                        Label("支出がありません", systemImage: "list.bullet")
                    }
                    .padding(.vertical, 40)
                }
            }
            ForEach(groupedByDate, id: \.date) { group in
                VStack(spacing: 0) {
                    HStack {
                        Text(dayHeader(group.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(daySigned(group.items, code: sheet.resolvedDefaultCurrencyCode))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    VStack(spacing: 0) {
                        ForEach(group.items, id: \.objectID) { e in
                            Button {
                                editingExpense = e
                            } label: {
                                expenseRow(e)
                            }
                            .buttonStyle(.plain)
                            if e.objectID != group.items.last?.objectID {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.quaternary.opacity(0.5))
                    )
                }
            }
        }
        // フィルタ・検索・並び替え・追加で表示集合が変わったら一覧をアニメーション。
        // Reduce Motion 時はアニメーションしない。
        .animation(reduceMotion ? nil : .default, value: listExpenses.map(\.objectID))
    }

    private func expenseRow(_ e: Expense) -> some View {
        HStack(spacing: 12) {
            categoryIconWithPayer(e)
            VStack(alignment: .leading, spacing: 2) {
                // 主タイトル位置にカテゴリ名を表示
                Text(e.categoryDisplayName).font(.body)
                // サブタイトル: 入力タイトル · 支払者
                // (支払者アバターはアイコン右下に重ねるのでここでは出さない)
                // 参加者が自分だけ (他メンバー未参加) のシートでは支払者は常に
                // 自分なので冗長。表示しない。
                let title = e.displayTitle
                let payer = hasAcceptedOtherParticipants ? e.displayPaidBy : ""
                if !title.isEmpty || !payer.isEmpty {
                    HStack(spacing: 4) {
                        if !title.isEmpty {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                        }
                        if !title.isEmpty && !payer.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                        }
                        if !payer.isEmpty {
                            Text(payer).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Text(e.formattedSignedAmount)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// カテゴリアイコン + 支払者アバター (右下) を重ねる。
    /// 個人専用シート (= 参加済みの他メンバーが居ない) では UI ノイズを避けるため
    /// アバターを出さない。
    @ViewBuilder
    private func categoryIconWithPayer(_ e: Expense) -> some View {
        let payerName = e.displayPaidBy
        let pid = e.payerProfileID ?? ""
        let showAvatar = !payerName.isEmpty && !pid.isEmpty && hasAcceptedOtherParticipants
        ZStack(alignment: .bottomTrailing) {
            CategoryIconView(expense: e, size: 32)
            if showAvatar {
                let info = sheet.memberDisplayInfo(for: pid)
                AvatarView(
                    photoData: info.photoData,
                    displayName: info.name,
                    colorHex: info.colorHex,
                    size: 16
                )
                .overlay(
                    Circle().stroke(Color.platformSystemBackground, lineWidth: 2)
                )
                .offset(x: 4, y: 4)
            }
        }
    }

    /// このシートに自分以外のメンバー (受諾済み参加者 or バーチャルメンバー) が居るか。
    private var hasAcceptedOtherParticipants: Bool {
        sheet.acceptedMemberProfileIDs().count > 1
    }

    private func dayHeader(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy年M月d日 (E)"
        return df.string(from: d)
    }

    private func daySigned(_ items: [Expense], code: String) -> String {
        let fx = FXRatesService.shared
        var total: Decimal = 0
        for e in items {
            let from = e.resolvedCurrencyCode
            let converted: Decimal?
            if from == code {
                converted = e.amountDecimal
            } else {
                converted = fx.convert(e.amountDecimal, from: from, to: code)
            }
            guard let amount = converted else { continue }
            total += (e.kind == .income ? amount : -amount)
        }
        let sign = total >= 0 ? "+" : ""
        return sign + CurrencyCatalog.format(total, code: code)
    }
}

// MARK: - エクスポート用 FileDocument

/// CSV / PDF データを `.fileExporter` (保存パネル) で書き出すための簡易ドキュメント。
struct ExportFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .pdf] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText, .pdf] }

    var data: Data
    var type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Mac モーダル共通ラッパー

/// Mac で sheet を出した時に、iOS の swipe-down に相当する閉じるボタンを
/// 強制的に出すための wrapper。NavigationStack で包んで cancellation
/// placement に xmark を置く。
struct MacModalSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .accessibilityLabel("閉じる")
                        }
                    }
                }
        }
        .frame(minWidth: 600, minHeight: 600)
    }
}

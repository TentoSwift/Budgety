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
                Text(lockManager.isUnlocked(sheet) ? monthlyLabel(for: sheet) : "ロック中")
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
        return "今月 " + CurrencyCatalog.format(total, code: sheet.resolvedDefaultCurrencyCode)
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
                    // 全支出を表示する (旧: prefix(6) で最近 6 件のみだった)。
                    // List + Section なので watchOS でもスクロールで降りていける。
                    ForEach(Array(expenses), id: \.objectID) { expense in
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
                    Text("支出")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .listStyle(.plain)
        .containerBackground(sheet.tint.gradient, for: .navigation)
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
                Text("今月")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(formatYen(monthTotal))
                .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy, value: monthTotal)
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
                // Dynamic Type で巨大化しないよう固定サイズに。
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(
                    // 未分類は灰色。カテゴリ背景はグラデーションに。
                    Circle().fill((Color(hex: e.category?.colorHex ?? "#8E8E93") ?? .gray).gradient)
                )
            // タイトルと金額を縦並びに (狭い画面で折り返しが起きないよう)。
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(e))
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(formatYen(e.amountDecimal))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
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

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

struct BudgetyMacSheetView: View {
    @ObservedObject var sheet: ExpenseSheet
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var pub = PublicProfileSync.shared

    @State private var showingAdd: Bool = false
    @State private var editingExpense: Expense?
    @State private var showingSettlement = false
    @State private var showingCategories = false
    @State private var showingRecurring = false
    @State private var showingTemplates = false
    @State private var showingEditSheet = false
    @State private var showingAIChat = false
    @State private var showingCSVImport = false
    @State private var showingStats = false

    private var allExpenses: [Expense] {
        ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var groupedByDate: [(date: Date, items: [Expense])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: allExpenses) { exp -> Date in
            cal.startOfDay(for: exp.date ?? .now)
        }
        return dict.map { (date: $0.key, items: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private var monthlyTotal: Decimal {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: .now)
        return allExpenses
            .filter { e in
                guard let d = e.date, e.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: d)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryHero
                membersStrip
                expensesList
            }
            .padding(20)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(sheet.displayName)
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
                    Button { showingTemplates = true } label: {
                        Label("テンプレート", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button { showingCSVImport = true } label: {
                        Label("CSV インポート", systemImage: "tray.and.arrow.down")
                    }
                    Button { showingEditSheet = true } label: {
                        Label("シートを編集", systemImage: "pencil")
                    }
                } label: {
                    Label("その他", systemImage: "ellipsis.circle")
                }
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
        .sheet(isPresented: $showingTemplates) {
            MacModalSheet { TemplateListView(record: sheet) }
        }
        .sheet(isPresented: $showingEditSheet) {
            // EditSheetView 自身が cancel/save の toolbar を持つので wrapper 不要
            NavigationStack { EditSheetView(record: sheet) }
                .frame(minWidth: 600, minHeight: 600)
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
    }

    private var summaryHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: sheet.symbol ?? "person.2.fill")
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Circle().fill(sheet.tint.gradient))
                Text(sheet.displayName).font(.title3.weight(.semibold))
                Spacer()
                if sheet.isOwnedByCurrentUser == false {
                    Image(systemName: "person.2.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
            Text("今月")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(CurrencyCatalog.format(monthlyTotal, code: sheet.resolvedDefaultCurrencyCode))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
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
    private var membersStrip: some View {
        let ids = sheet.allMemberProfileIDs()
        return HStack(spacing: 12) {
            ForEach(ids, id: \.self) { id in
                let info = sheet.memberDisplayInfo(for: id)
                VStack(spacing: 4) {
                    AvatarView(
                        photoData: info.photoData,
                        displayName: info.name,
                        colorHex: info.colorHex,
                        size: 36
                    )
                    Text(info.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 80)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private var expensesList: some View {
        VStack(spacing: 16) {
            if groupedByDate.isEmpty {
                ContentUnavailableView {
                    Label("支出がありません", systemImage: "list.bullet")
                } 
                .padding(.vertical, 40)
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
    }

    private func expenseRow(_ e: Expense) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(e.categoryTint.opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: e.categorySymbol)
                    .foregroundStyle(e.categoryTint)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(e.displayTitle).font(.body)
                let payer = e.displayPaidBy
                if !payer.isEmpty {
                    HStack(spacing: 4) {
                        if let pid = e.payerProfileID, !pid.isEmpty {
                            let info = sheet.memberDisplayInfo(for: pid)
                            AvatarView(
                                photoData: info.photoData,
                                displayName: info.name,
                                colorHex: info.colorHex,
                                size: 16
                            )
                        }
                        Text(payer).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(e.formattedSignedAmount)
                .font(.callout.monospacedDigit())
                .foregroundStyle(e.kind == .income ? .green : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func dayHeader(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy年M月d日 (E)"
        return df.string(from: d)
    }

    private func daySigned(_ items: [Expense], code: String) -> String {
        let total = items.reduce(Decimal(0)) { acc, e in
            acc + (e.kind == .income ? e.amountDecimal : -e.amountDecimal)
        }
        let sign = total >= 0 ? "+" : ""
        return sign + CurrencyCatalog.format(total, code: code)
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

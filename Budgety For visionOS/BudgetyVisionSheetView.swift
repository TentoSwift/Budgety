//
//  BudgetyVisionSheetView.swift
//  Budgety For visionOS
//
//  iOS 版 SheetDetailView 相当。
//  - 上部: 今月の合計ヒーロー
//  - 中央: 日付ごとにグループした支出一覧
//  - 下部: 追加ボタン
//

import SwiftUI
import CoreData

struct BudgetyVisionSheetView: View {
    @ObservedObject var sheet: ExpenseSheet
    @Environment(\.managedObjectContext) private var viewContext

    @State private var showingAdd: Bool = false
    @State private var editingExpense: Expense?

    private var allExpenses: [Expense] {
        ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// ルールから算出した仮想 occurrence (完全仮想化フラグ OFF なら空)。
    private var allVirtuals: [RecurringOccurrence] {
        RecurringOccurrenceService.virtualOccurrences(for: sheet, includeFuture: false)
    }

    private var groupedByDate: [(date: Date, items: [LedgerItem])] {
        let cal = Calendar.current
        let items: [LedgerItem] = allExpenses.map { LedgerItem.expense($0) }
            + allVirtuals.map { LedgerItem.occurrence($0) }
        let dict = Dictionary(grouping: items) { item -> Date in
            cal.startOfDay(for: item.date)
        }
        return dict
            .map { (date: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    private var monthlyTotal: Decimal {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: .now)
        let expenseSum = allExpenses
            .filter { e in
                guard let d = e.date, e.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: d)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let virtualSum = allVirtuals
            .filter { occ in
                guard occ.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: occ.date)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amount }
        return expenseSum + virtualSum
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 24) {
                    summaryHero
                    expensesList
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 120)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
            addFloatingButton
        }
        .navigationTitle(sheet.displayName)
        .sheet(isPresented: $showingAdd) {
            VisionAddExpenseView(sheet: sheet, expense: nil)
        }
        .sheet(item: $editingExpense) { e in
            VisionAddExpenseView(sheet: sheet, expense: e)
        }
    }

    // MARK: - Sections

    private var summaryHero: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: sheet.symbol ?? "person.2.fill")
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(sheet.tint.gradient))
                Text(sheet.displayName).font(.title3.weight(.semibold))
                Spacer()
                if sheet.isOwnedByCurrentUser == false {
                    Label("受信中", systemImage: "tray.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.blue.opacity(0.15)))
                        .foregroundStyle(.blue)
                } else if hasParticipants {
                    Label("共有中", systemImage: "person.2.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.green.opacity(0.15)))
                        .foregroundStyle(.green)
                }
            }
            HStack {
                Text("今月")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(sheet.tint.opacity(0.2)))
                Spacer()
            }
            HStack {
                Text(CurrencyCatalog.format(monthlyTotal, code: sheet.resolvedDefaultCurrencyCode))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(sheet.tint.opacity(0.12))
        )
    }

    private var hasParticipants: Bool {
        guard let pps = sheet.participantProfiles as? Set<ParticipantProfile> else { return false }
        return pps.count >= 2  // 自分 + 他 1 人以上
    }

    private var expensesList: some View {
        VStack(spacing: 16) {
            if groupedByDate.isEmpty {
                ContentUnavailableView {
                    Label("支出がありません", systemImage: "list.bullet")
                } description: {
                    Text("右下の + ボタンから最初の支出を追加してください。")
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    VStack(spacing: 0) {
                        ForEach(group.items) { item in
                            switch item {
                            case .expense(let e):
                                Button {
                                    editingExpense = e
                                } label: {
                                    expenseRow(e)
                                }
                                .buttonStyle(.plain)
                            case .occurrence(let occ):
                                // visionOS には定期管理 UI が無いので表示のみ。
                                virtualRow(occ)
                            }
                            if item.id != group.items.last?.id {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.regularMaterial)
                    )
                }
            }
        }
    }

    private func expenseRow(_ e: Expense) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(e.categoryTint.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: e.categorySymbol)
                    .foregroundStyle(e.categoryTint)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(e.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                let payer = e.displayPaidBy
                if !payer.isEmpty {
                    Text(payer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(e.formattedSignedAmount)
                .font(.callout.monospacedDigit())
                .foregroundStyle(e.kind == .income ? .green : .primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var addFloatingButton: some View {
        Button {
            showingAdd = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .controlSize(.extraLarge)
        .padding(.bottom, 28)
    }

    // MARK: - Helpers

    private func dayHeader(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy年M月d日 (E)"
        return df.string(from: d)
    }

    private func daySigned(_ items: [LedgerItem], code: String) -> String {
        let total = items.reduce(Decimal(0)) { acc, it in
            acc + (it.kind == .income ? it.amountDecimal : -it.amountDecimal)
        }
        let sign = total >= 0 ? "+" : ""
        return sign + CurrencyCatalog.format(total, code: code)
    }

    /// 仮想 occurrence の行 (visionOS, 表示のみ・控えめ)。
    private func virtualRow(_ occ: RecurringOccurrence) -> some View {
        let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let category = occ.categoryRaw.isEmpty ? nil : cats.first { $0.name == occ.categoryRaw }
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.gray.opacity(0.2)).frame(width: 36, height: 36)
                Image(systemName: "repeat").foregroundStyle(.gray).font(.callout)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(occ.title.isEmpty ? (category?.displayName ?? "定期項目") : occ.title)
                    .font(.body).foregroundStyle(.primary)
                Text(category?.displayName ?? (occ.categoryRaw.isEmpty ? "定期" : occ.categoryRaw))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(CurrencyCatalog.format(occ.amount, code: occ.currencyCode))
                .font(.callout.monospacedDigit())
                .foregroundStyle(occ.kind == .income ? .green : .primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(0.85)
        .contentShape(Rectangle())
    }
}

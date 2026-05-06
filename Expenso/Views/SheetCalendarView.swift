//
//  SheetCalendarView.swift
//  Expenso
//
//  シートの月別カレンダー: 各日の net 合計と件数を一覧表示。
//  日をタップすると、その日の支出/収入リストが下に出る。
//

import SwiftUI
import CoreData

struct SheetCalendarView: View {
    @ObservedObject var record: ExpenseSheet
    @ObservedObject private var fx = FXRatesService.shared

    @FetchRequest private var expenses: FetchedResults<Expense>

    @State private var anchorMonth: Date = Calendar.current.startOfDay(for: .now)
    @State private var selectedDay: Date?
    @State private var editingExpense: Expense?

    init(record: ExpenseSheet) {
        self.record = record
        self._expenses = FetchRequest<Expense>(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
            predicate: NSPredicate(format: "sheet == %@", record),
            animation: .default
        )
    }

    private var calendar: Calendar { Calendar.current }
    private var code: String { record.resolvedDefaultCurrencyCode }

    /// 表示中の月の最初の日 (0:00)
    private var monthStart: Date {
        let comps = calendar.dateComponents([.year, .month], from: anchorMonth)
        return calendar.date(from: comps) ?? anchorMonth
    }

    /// 表示する 6 週分 (= 42 セル) の日付配列。月初の前後を含む。
    private var calendarCells: [Date] {
        let firstWeekday = calendar.firstWeekday  // 1=Sunday
        let monthFirstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (monthFirstWeekday - firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) else {
            return []
        }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// 当月の Expense 配列
    private var monthExpenses: [Expense] {
        expenses.filter { e in
            guard let d = e.date else { return false }
            return calendar.isDate(d, equalTo: anchorMonth, toGranularity: .month)
        }
    }

    /// 日 (startOfDay) → その日の (net 換算済み, 件数)
    private var dailyTotals: [Date: (net: Decimal, count: Int)] {
        var result: [Date: (net: Decimal, count: Int)] = [:]
        let target = code
        for e in monthExpenses {
            guard let d = e.date else { continue }
            let key = calendar.startOfDay(for: d)
            let from = e.resolvedCurrencyCode
            let amt = fx.convert(e.amountDecimal, from: from, to: target) ?? e.amountDecimal
            let signed: Decimal = (e.kind == .income) ? amt : -amt
            let prev = result[key] ?? (0, 0)
            result[key] = (prev.net + signed, prev.count + 1)
        }
        return result
    }

    /// 月合計
    private var monthTotals: (expense: Decimal, income: Decimal) {
        var exp: Decimal = 0
        var inc: Decimal = 0
        let target = code
        for e in monthExpenses {
            let from = e.resolvedCurrencyCode
            let amt = fx.convert(e.amountDecimal, from: from, to: target) ?? e.amountDecimal
            switch e.kind {
            case .expense: exp += amt
            case .income:  inc += amt
            }
        }
        return (exp, inc)
    }

    private var selectedDayExpenses: [Expense] {
        guard let day = selectedDay else { return [] }
        return expenses.filter { e in
            guard let d = e.date else { return false }
            return calendar.isDate(d, inSameDayAs: day)
        }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                monthHeader
                weekdayRow
                grid
                if selectedDay != nil {
                    selectedDaySection
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("カレンダー")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingExpense) { exp in
            AddExpenseView(expense: exp)
        }
    }

    // MARK: - Month header

    private var monthHeader: some View {
        HStack {
            Button {
                shift(months: -1)
            } label: {
                Image(systemName: "chevron.left").padding(8)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(monthLabel)
                    .font(.headline)
                let totals = monthTotals
                HStack(spacing: 12) {
                    Label(CurrencyCatalog.format(totals.expense, code: code), systemImage: "minus.circle")
                        .foregroundStyle(.red)
                    Label(CurrencyCatalog.format(totals.income, code: code), systemImage: "plus.circle")
                        .foregroundStyle(.green)
                }
                .font(.caption2.monospacedDigit())
            }
            Spacer()
            Button {
                shift(months: 1)
            } label: {
                Image(systemName: "chevron.right").padding(8)
            }
        }
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年 M月"
        return f.string(from: monthStart)
    }

    // MARK: - Weekday row

    private var weekdayRow: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        // calendar.firstWeekday に合わせて並び替え
        let first = calendar.firstWeekday - 1
        let ordered = (0..<7).map { symbols[(first + $0) % 7] }
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { idx, sym in
                Text(sym)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(weekdayColor(at: idx))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekdayColor(at idx: Int) -> Color {
        // 日曜は赤、土曜は青
        let weekday = ((calendar.firstWeekday - 1) + idx) % 7  // 0=Sunday
        switch weekday {
        case 0: return .red
        case 6: return .blue
        default: return .secondary
        }
    }

    // MARK: - Grid

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(calendarCells, id: \.self) { day in
                cell(day: day)
            }
        }
    }

    @ViewBuilder
    private func cell(day: Date) -> some View {
        let key = calendar.startOfDay(for: day)
        let total = dailyTotals[key]
        let inMonth = calendar.isDate(day, equalTo: anchorMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let dayNum = calendar.component(.day, from: day)
        let weekday = calendar.component(.weekday, from: day)  // 1=Sun

        Button {
            if isSelected { selectedDay = nil } else { selectedDay = day }
        } label: {
            VStack(spacing: 2) {
                Text("\(dayNum)")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .foregroundStyle(textColor(weekday: weekday, inMonth: inMonth, isSelected: isSelected))
                if let total {
                    Text(shortAmount(total.net))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(total.net >= 0 ? Color.green : Color.red)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Text(" ").font(.system(size: 9))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cellBackground(isSelected: isSelected, isToday: isToday, hasData: total != nil))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isToday && !isSelected ? record.tint : .clear, lineWidth: 1.5)
            )
            .opacity(inMonth ? 1.0 : 0.35)
        }
        .buttonStyle(.plain)
    }

    private func textColor(weekday: Int, inMonth: Bool, isSelected: Bool) -> Color {
        if isSelected { return .white }
        guard inMonth else { return .secondary }
        switch weekday {
        case 1: return .red
        case 7: return .blue
        default: return .primary
        }
    }

    private func cellBackground(isSelected: Bool, isToday: Bool, hasData: Bool) -> Color {
        if isSelected { return record.tint }
        if hasData { return record.tint.opacity(0.08) }
        return .clear
    }

    /// 「+12k」「-345」のような短縮表記。当該通貨の小数桁を尊重。
    private func shortAmount(_ value: Decimal) -> String {
        let abs = (value < 0) ? -value : value
        let sign = (value < 0) ? "-" : (value > 0 ? "+" : "")
        let isInteger = ["JPY", "KRW", "VND", "IDR"].contains(code)
        let absDouble = NSDecimalNumber(decimal: abs).doubleValue
        if absDouble >= 1_000_000 {
            return "\(sign)\(format(absDouble / 1_000_000))M"
        } else if absDouble >= 10_000 {
            return "\(sign)\(format(absDouble / 1_000))k"
        } else if isInteger {
            return "\(sign)\(Int(absDouble))"
        } else {
            return "\(sign)\(format(absDouble))"
        }
    }

    private func format(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(d))"
        }
        return String(format: "%.1f", d)
    }

    private func shift(months: Int) {
        if let new = calendar.date(byAdding: .month, value: months, to: anchorMonth) {
            anchorMonth = new
            selectedDay = nil
        }
    }

    // MARK: - Selected day section

    @ViewBuilder
    private var selectedDaySection: some View {
        let exps = selectedDayExpenses
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedDayLabel).font(.headline)
                Spacer()
                Button("閉じる") { selectedDay = nil }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if exps.isEmpty {
                Text("この日は支出も収入もありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(exps.enumerated()), id: \.element.objectID) { idx, exp in
                        Button {
                            editingExpense = exp
                        } label: {
                            calendarExpenseRow(exp)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if idx < exps.count - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
        }
    }

    private var selectedDayLabel: String {
        guard let day = selectedDay else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 (E)"
        return f.string(from: day)
    }

    @ViewBuilder
    private func calendarExpenseRow(_ exp: Expense) -> some View {
        HStack(spacing: 12) {
            CategoryIconView(expense: exp, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(exp.displayTitle.isEmpty ? exp.categoryDisplayName : exp.displayTitle)
                    .font(.subheadline)
                let payer = exp.displayPaidBy
                if !payer.isEmpty {
                    Text(payer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(exp.formattedSignedAmount)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(exp.kind == .income ? .green : .primary)
        }
    }
}

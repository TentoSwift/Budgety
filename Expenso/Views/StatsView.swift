//
//  StatsView.swift
//  Expenso
//

import SwiftUI
import CoreData
import Charts

struct StatsView: View {
    @ObservedObject var record: ExpenseSheet

    @State private var selectedMonth: Date = .now
    @State private var selectedKind: TransactionKind = .expense

    private var allExpenses: [Expense] {
        ((record.expenses as? Set<Expense>) ?? []).sorted {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
    }

    private var filteredExpenses: [Expense] {
        allExpenses.filter { $0.kind == selectedKind }
    }

    private var monthlyExpenses: [Expense] {
        let calendar = Calendar.current
        return filteredExpenses.filter {
            calendar.isDate($0.date ?? .distantPast, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    private var primaryCurrencyCode: String {
        record.resolvedDefaultCurrencyCode
    }

    /// 全ての支出を primary currency に換算して合計する。FX レート未取得時は元の値で加算する。
    private func sumInPrimary(_ list: [Expense]) -> Decimal {
        let fx = FXRatesService.shared
        let target = primaryCurrencyCode
        return list.reduce(Decimal(0)) { acc, e in
            acc + (fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal)
        }
    }

    private var totalAmount: Decimal {
        sumInPrimary(monthlyExpenses)
    }

    private var previousMonthTotal: Decimal {
        let cal = Calendar.current
        guard let prev = cal.date(byAdding: .month, value: -1, to: selectedMonth) else { return 0 }
        let list = filteredExpenses.filter {
            cal.isDate($0.date ?? .distantPast, equalTo: prev, toGranularity: .month)
        }
        return sumInPrimary(list)
    }

    private var monthOverMonthDiff: Decimal {
        totalAmount - previousMonthTotal
    }

    private var monthOverMonthPercent: Double? {
        let prev = NSDecimalNumber(decimal: previousMonthTotal).doubleValue
        guard prev > 0 else { return nil }
        let cur = NSDecimalNumber(decimal: totalAmount).doubleValue
        return ((cur - prev) / prev) * 100
    }

    private struct PayerSummary: Identifiable {
        let name: String
        let colorHex: String
        let photoData: Data?
        let tint: Color
        let total: Decimal
        let count: Int
        var id: String { name }
    }

    private var byPayer: [PayerSummary] {
        let fx = FXRatesService.shared
        let target = primaryCurrencyCode
        let grouped = Dictionary(grouping: monthlyExpenses) { exp -> String in
            exp.paidBy?.isEmpty == false ? exp.paidBy! : "未指定"
        }
        return grouped.map { (name, list) in
            let resolved = list.first?.resolvedPayer
            let total = list.reduce(Decimal(0)) { acc, e in
                acc + (fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal)
            }
            return PayerSummary(
                name: name,
                colorHex: resolved?.displayColorHex ?? "#8E8E93",
                photoData: resolved?.photoData,
                tint: resolved?.tint ?? .secondary,
                total: total,
                count: list.count
            )
        }
        .sorted { $0.total > $1.total }
    }

    private var byCategory: [CategorySummary] {
        let fx = FXRatesService.shared
        let target = primaryCurrencyCode
        let dict = Dictionary(grouping: monthlyExpenses) { $0.categoryDisplayName }
        return dict.map { (key, value) in
            let total = value.reduce(Decimal(0)) { acc, e in
                acc + (fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal)
            }
            return CategorySummary(
                name: key,
                tint: value.first?.categoryTint ?? .gray,
                symbol: value.first?.categorySymbol ?? "ellipsis.circle",
                total: total,
                count: value.count
            )
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        statsScroll
            .navigationTitle("\(record.displayName) の統計")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var statsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                kindPicker
                monthPicker
                summaryCard
                if !byCategory.isEmpty {
                    dailyChartSection
                    chartSection
                    breakdownSection
                    if shouldShowPayerBreakdown { payerBreakdownSection }
                } else {
                    ContentUnavailableView(
                        "この月のデータはありません",
                        systemImage: "chart.pie",
                        description: Text("支出を追加すると統計が表示されます。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding()
        }
    }

    private var kindPicker: some View {
        Picker("種別", selection: $selectedKind) {
            ForEach(TransactionKind.allCases) { k in
                Label(k.label, systemImage: k.symbol).tag(k)
            }
        }
        .pickerStyle(.segmented)
    }

    private var dailyTotals: [(date: Date, total: Decimal)] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: selectedMonth) else { return [] }
        let dict = Dictionary(grouping: monthlyExpenses) { exp -> Date in
            cal.startOfDay(for: exp.date ?? .now)
        }
        var result: [(Date, Decimal)] = []
        var d = interval.start
        while d < interval.end {
            let total = (dict[d] ?? []).reduce(Decimal(0)) { $0 + $1.amountDecimal }
            result.append((d, total))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? interval.end
        }
        return result
    }

    private var dailyChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日別")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Chart(dailyTotals, id: \.date) { item in
                BarMark(
                    x: .value("日", item.date, unit: .day),
                    y: .value("金額", NSDecimalNumber(decimal: item.total).doubleValue)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                }
            }
            .frame(height: 140)
        }
    }

    @ViewBuilder
    private func pill(text: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? color.opacity(0.18) : Color(.secondarySystemBackground))
                )
                .overlay(
                    Capsule().stroke(isSelected ? color : .clear, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? color : .primary)
        }
        .buttonStyle(.plain)
    }

    private var monthPicker: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left").padding(8)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(monthLabel)
                    .font(.headline)
                if let relative = relativeMonthLabel {
                    Text(relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right").padding(8)
            }
            .disabled(isFutureMonth)
            .opacity(isFutureMonth ? 0.3 : 1.0)
        }
    }

    private var isFutureMonth: Bool {
        let cal = Calendar.current
        return cal.compare(selectedMonth, to: .now, toGranularity: .month) == .orderedSame
    }

    private var relativeMonthLabel: String? {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.month], from: cal.startOfMonth(for: selectedMonth), to: cal.startOfMonth(for: now))
        guard let diff = comps.month else { return nil }
        switch diff {
        case 0: return "今月"
        case 1: return "先月"
        case -1: return "来月"
        case 2...: return "\(diff)ヶ月前"
        case ..<(-1): return "\(-diff)ヶ月後"
        default: return nil
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("月の合計")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if previousMonthTotal > 0 {
                    momBadge
                }
            }
            Text(CurrencyCatalog.format(totalAmount, code: primaryCurrencyCode))
                .font(.largeTitle.bold().monospacedDigit())
            HStack(spacing: 8) {
                Text("\(monthlyExpenses.count) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if previousMonthTotal > 0 {
                    Text("先月: \(CurrencyCatalog.format(previousMonthTotal, code: primaryCurrencyCode))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.thinMaterial)
        }
    }

    @ViewBuilder
    private var momBadge: some View {
        let diff = monthOverMonthDiff
        let isUp = diff > 0
        let isFlat = diff == 0
        let color: Color = isFlat ? .secondary : (isUp ? .red : .green)
        let icon = isFlat ? "minus" : (isUp ? "arrow.up.right" : "arrow.down.right")
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            if let pct = monthOverMonthPercent {
                Text(String(format: "%+.1f%%", pct))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var chartSection: some View {
        Chart(byCategory) { item in
            SectorMark(
                angle: .value("金額", NSDecimalNumber(decimal: item.total).doubleValue),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(by: .value("カテゴリ", item.name))
        }
        .chartForegroundStyleScale(
            domain: byCategory.map(\.name),
            range: byCategory.map(\.tint)
        )
        .chartLegend(position: .bottom, alignment: .center, spacing: 8)
        .frame(height: 240)
    }

    private var shouldShowPayerBreakdown: Bool {
        let nonEmpty = byPayer.filter { $0.name != "未指定" }
        return nonEmpty.count >= 2
    }

    private var payerBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("支払者別")
                .font(.headline)
            ForEach(byPayer) { item in
                HStack {
                    AvatarView(
                        photoData: item.photoData,
                        displayName: item.name,
                        colorHex: item.colorHex,
                        size: 28
                    )
                    Text(item.name)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CurrencyCatalog.format(item.total, code: primaryCurrencyCode))
                            .monospacedDigit()
                            .font(.subheadline)
                        Text("\(item.count) 件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("カテゴリ別内訳")
                .font(.headline)
            ForEach(byCategory) { item in
                HStack {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.tint)
                        .frame(width: 28)
                    Text(item.name)
                    Spacer()
                    Text(CurrencyCatalog.format(item.total, code: primaryCurrencyCode))
                        .monospacedDigit()
                        .font(.subheadline)
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private func shiftMonth(by value: Int) {
        if let new = Calendar.current.date(byAdding: .month, value: value, to: selectedMonth) {
            selectedMonth = new
        }
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年 M月"
        return f.string(from: selectedMonth)
    }
}

private struct CategorySummary: Identifiable {
    let name: String
    let tint: Color
    let symbol: String
    let total: Decimal
    let count: Int
    var id: String { name }
}

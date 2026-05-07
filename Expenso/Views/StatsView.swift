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
    @State private var insights: [ResolvedInsight]?
    @State private var isGeneratingInsights: Bool = false
    @State private var insightsError: String?

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
        let member: Member?
        let participantProfile: ParticipantProfile?
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
            let resolvedMember = list.first?.resolvedPayer
            let resolvedPP = list.first?.resolvedParticipantProfile
            let total = list.reduce(Decimal(0)) { acc, e in
                acc + (fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal)
            }
            return PayerSummary(
                name: name,
                member: resolvedMember,
                participantProfile: resolvedPP,
                colorHex: resolvedMember?.displayColorHex ?? resolvedPP?.colorHex ?? "#8E8E93",
                photoData: resolvedMember?.photoData ?? resolvedPP?.photoData,
                tint: resolvedMember?.tint ?? .secondary,
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
                    insightsSection
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
        .task(id: insightsKey) {
            await regenerateInsights()
        }
    }

    /// 月 + 種別 + データ件数で識別。月変更や種別切替で再生成。
    private var insightsKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMM"
        return "\(f.string(from: selectedMonth))-\(selectedKind.rawValue)-\(monthlyExpenses.count)"
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

    // MARK: - Insights (FoundationModels)

    @ViewBuilder
    private var insightsSection: some View {
        // FoundationModels が利用できない端末ではセクションごと隠す
        if StatsInsightsGenerator.isAvailable {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("今月の気づき", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isGeneratingInsights {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await regenerateInsights(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGeneratingInsights)
                }

                if let insights, !insights.isEmpty {
                    // ストリーミング中もこの分岐に入って、生成済みカードから順に出す
                    VStack(spacing: 8) {
                        ForEach(insights) { insight in
                            insightCard(insight)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                } else if isGeneratingInsights {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("分析中…").foregroundStyle(.secondary).font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                } else if let err = insightsError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func insightCard(_ insight: ResolvedInsight) -> some View {
        let (icon, tint): (String, Color) = {
            switch insight.severity {
            case .positive: return ("checkmark.circle.fill", .green)
            case .warning:  return ("exclamationmark.triangle.fill", .orange)
            case .info:     return ("lightbulb.fill", Color.accentColor)
            }
        }()
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title.asAttributedMarkdown)
                    .font(.subheadline.weight(.semibold))
                Text(insight.body.asAttributedMarkdown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        )
    }

    /// 統計データから context を組み立てて LLM を呼ぶ。
    /// ストリーミングで部分応答を受け取り、出来たものから順に画面に表示する。
    /// - Parameter force: `true` ならすでに insights があっても再生成する (refresh ボタン用)。
    @MainActor
    private func regenerateInsights(force: Bool = false) async {
        guard StatsInsightsGenerator.isAvailable else {
            insights = nil
            return
        }
        guard !monthlyExpenses.isEmpty else {
            insights = nil
            return
        }
        if !force, isGeneratingInsights { return }

        isGeneratingInsights = true
        insightsError = nil
        insights = nil

        let context = buildInsightsContext()
        let result = await StatsInsightsGenerator.generate(context: context) { partial in
            // partial が来るたびに UI を更新 (= ストリーミング表示)
            withAnimation(.easeOut(duration: 0.15)) {
                insights = partial.isEmpty ? nil : partial
            }
        }
        isGeneratingInsights = false
        if let result, !result.isEmpty {
            insights = result
        } else if insights == nil {
            insightsError = "気づきを生成できませんでした"
        }
    }

    private func buildInsightsContext() -> StatsInsightsGenerator.Context {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月"
        let monthLabel = f.string(from: selectedMonth)

        let prevMonth = cal.date(byAdding: .month, value: -1, to: selectedMonth) ?? selectedMonth
        let prevExpenses = filteredExpenses.filter {
            cal.isDate($0.date ?? .distantPast, equalTo: prevMonth, toGranularity: .month)
        }
        let prevByCategory: [String: Decimal] = {
            let fx = FXRatesService.shared
            let target = primaryCurrencyCode
            return Dictionary(grouping: prevExpenses) { $0.categoryDisplayName }
                .mapValues { list in
                    list.reduce(Decimal(0)) { acc, e in
                        acc + (fx.convert(e.amountDecimal, from: e.resolvedCurrencyCode, to: target) ?? e.amountDecimal)
                    }
                }
        }()

        let categoryRows: [StatsInsightsGenerator.Context.CategoryRow] = byCategory.map { c in
            StatsInsightsGenerator.Context.CategoryRow(
                name: c.name,
                amount: c.total,
                count: c.count,
                prevAmount: prevByCategory[c.name]
            )
        }

        let payerRows: [StatsInsightsGenerator.Context.PayerRow] = byPayer.map { p in
            StatsInsightsGenerator.Context.PayerRow(name: p.name, amount: p.total, count: p.count)
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ja_JP")
        dayFormatter.dateFormat = "yyyy/MM/dd"
        let topDays: [StatsInsightsGenerator.Context.DayRow] = dailyTotals
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .prefix(3)
            .map { row in
                let count = monthlyExpenses.filter {
                    cal.isDate($0.date ?? .distantPast, inSameDayAs: row.date)
                }.count
                return StatsInsightsGenerator.Context.DayRow(
                    dateLabel: dayFormatter.string(from: row.date),
                    amount: row.total,
                    count: count
                )
            }

        return StatsInsightsGenerator.Context(
            monthLabel: monthLabel,
            kindLabel: selectedKind.label,
            currencyCode: primaryCurrencyCode,
            totalAmount: totalAmount,
            totalCount: monthlyExpenses.count,
            previousMonthTotal: previousMonthTotal,
            previousMonthCount: prevExpenses.count,
            categoryRows: categoryRows,
            payerRows: payerRows,
            topDays: topDays
        )
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
            Text("\(selectedKind.partyLabel)別")
                .font(.headline)
            ForEach(byPayer) { item in
                HStack {
                    PayerAvatar(
                        member: item.member,
                        participantProfile: item.participantProfile,
                        fallbackName: item.name,
                        fallbackColorHex: item.colorHex,
                        fallbackPhoto: item.photoData,
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
                HStack(spacing: 10) {
                    CategoryIconView(symbol: item.symbol, tint: item.tint, size: 28)
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

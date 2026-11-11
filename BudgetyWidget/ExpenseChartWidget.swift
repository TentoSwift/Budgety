import Charts
import SwiftUI
import WidgetKit

struct ExpenseChartWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSheetStore.chartKind, intent: SelectWidgetSheet.self,
                               provider: SheetWidgetProvider()) { entry in
            ExpenseChartWidgetView(entry: entry)
        }
        .configurationDisplayName("支出グラフ")
        .description("選んだシートの今月の支出を日別の棒グラフで表示します。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ExpenseChartWidgetView: View {
    let entry: SheetWidgetEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch entry.content {
            case let .spending(sheet):
                let tint = Color(hex: sheet.colorHex ?? "#5B8DEF") ?? .indigo
                Label {
                    Text(verbatim: sheet.name)
                } icon: {
                    SheetSymbolIcon(symbol: sheet.symbol ?? "person.2.fill", tint: tint, size: 21,
                                    cutsOutSymbol: renderingMode != .fullColor)
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

                if let amounts = sheet.dailyExpenses {
                    Text(sheet.monthStart, format: .dateTime.year().month(.wide))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(sheet.expense, format: .currency(code: sheet.currency))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)

                    if amounts.contains(where: { $0 != 0 }) {
                        DailyExpenseChart(amounts: amounts, month: sheet.monthStart,
                                          currency: sheet.currency, tint: tint)
                    } else {
                        Spacer(minLength: 0)
                        if !sheet.missingRates {
                            Text("今月の支出はありません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if sheet.missingRates {
                        Text("為替レート未取得の明細を除く")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Spacer(minLength: 0)
                    Text("Budgetyを開いて更新してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .selectSheet, .unavailable, .needsRefresh:
                Label("支出グラフ", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer(minLength: 0)
                if case .needsRefresh = entry.content {
                    Text("Budgetyを開いて更新してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("ウィジェットを編集してシートを選んでください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive()
        .widgetURL(entry.sheetURL)
        .containerBackground(.background, for: .widget)
    }
}

private struct DailyExpenseChart: View {
    let amounts: [Decimal]
    let month: Date
    let currency: String
    let tint: Color

    @Environment(\.calendar) private var calendar

    var body: some View {
        GeometryReader { geometry in
            chart(showsValueAxis: geometry.size.width >= 200)
        }
    }

    private func chart(showsValueAxis: Bool) -> some View {
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let days = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? amounts.count
        return Chart(amounts.indices, id: \.self) { index in
            let date = calendar.date(byAdding: .day, value: index, to: monthStart) ?? monthStart
            let amount = amounts[index]
            let day = Double(index + 1)
            // Explicit calendar-day bounds keep the bar width stable on a continuous axis.
            RectangleMark(
                xStart: .value("日", day - 0.39), xEnd: .value("日", day + 0.39),
                yStart: .value("支出", 0.0), yEnd: .value("支出", NSDecimalNumber(decimal: amount).doubleValue)
            )
            .foregroundStyle(tint)
            .cornerRadius(2)
            .accessibilityLabel(Text(date, format: .dateTime.month().day()))
            .accessibilityValue(Text(amount, format: .currency(code: currency)))
        }
        .chartXScale(domain: 0.5...(Double(days) + 0.5))
        .chartXAxis {
            AxisMarks(values: [1.0, Double(days / 2), Double(days)]) { axis in
                let anchors: [UnitPoint] = [.topLeading, .top, .topTrailing]
                AxisValueLabel(centered: false, anchor: anchors[axis.index], collisionResolution: .disabled) {
                    if let day = axis.as(Double.self) {
                        Text(Int(day), format: .number).foregroundStyle(Color.secondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            if showsValueAxis, let maximum = amounts.max(), maximum > 0 {
                AxisMarks(position: .trailing, values: [NSDecimalNumber(decimal: maximum).doubleValue]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        Text(maximum, format: .currency(code: currency))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 0.5)
            }
        }
        .accessibilityLabel("日別の支出")
    }
}

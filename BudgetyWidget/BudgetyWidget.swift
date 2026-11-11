import AppIntents
import SwiftUI
import WidgetKit

struct WidgetSheetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "シート"
    static let defaultQuery = WidgetSheetQuery()

    let id: String
    let name: String

    init(_ sheet: WidgetSheetSnapshot) {
        id = sheet.id
        name = sheet.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WidgetSheetQuery: EntityQuery {
    func suggestedEntities() async throws -> [WidgetSheetEntity] {
        WidgetSheetStore.read().map(WidgetSheetEntity.init)
    }

    func entities(for identifiers: [String]) async throws -> [WidgetSheetEntity] {
        let sheets = WidgetSheetStore.read()
        return identifiers.compactMap { id in
            sheets.first { $0.id == id }.map(WidgetSheetEntity.init)
        }
    }
}

struct SelectWidgetSheet: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "シートを選択"

    @Parameter(title: "シート")
    var sheet: WidgetSheetEntity?
}

enum SheetWidgetContent {
    case spending(WidgetSheetSnapshot)
    case selectSheet
    case unavailable
    case needsRefresh(String)
}

struct SheetWidgetEntry: TimelineEntry {
    let date: Date
    let content: SheetWidgetContent

    var sheetURL: URL? {
        switch content {
        case .spending(let sheet): WidgetSheetLink.url(for: sheet.id)
        case .needsRefresh(let id): WidgetSheetLink.url(for: id)
        case .selectSheet, .unavailable: nil
        }
    }
}

struct SheetWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SheetWidgetEntry {
        let calendar = Calendar.current
        let now = Date.now
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let sampleDaily: [Decimal] = [1200, 0, 740, 3800, 0, 560, 0, 2500]
        let count = calendar.ordinality(of: .day, in: .month, for: now) ?? 1
        let chart = (0..<count).map { sampleDaily[$0 % sampleDaily.count] }
        let previous = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let rows = [
            WidgetExpenseRow(date: now, title: String(localized: "ランチ"), category: String(localized: "食費"),
                             symbol: "fork.knife", colorHex: "#F4784B", amount: 1200, currency: "JPY"),
            WidgetExpenseRow(date: previous, title: String(localized: "電車"), category: String(localized: "交通費"),
                             symbol: "tram.fill", colorHex: "#42A8D0", amount: 740, currency: "JPY")
        ]
        let sample = WidgetSheetSnapshot(id: "preview", name: String(localized: "家計"), symbol: "house.fill",
                                         colorHex: "#AF52DE", monthStart: start, expense: chart.reduce(0, +), income: 98000,
                                         currency: "JPY", missingRates: false, dailyExpenses: chart,
                                         recentExpenses: rows, recentExpenseCount: 2)
        return SheetWidgetEntry(date: now, content: .spending(sample))
    }

    func snapshot(for configuration: SelectWidgetSheet, in context: Context) async -> SheetWidgetEntry {
        if context.isPreview && configuration.sheet == nil { return placeholder(in: context) }
        return entries(for: configuration.sheet?.id, at: .now).first!
    }

    func timeline(for configuration: SelectWidgetSheet, in context: Context) async -> Timeline<SheetWidgetEntry> {
        let now = Date.now
        return Timeline(entries: entries(for: configuration.sheet?.id, at: now), policy: .after(now.addingTimeInterval(3600)))
    }

    func entries(for id: String?, at date: Date, sheets: [WidgetSheetSnapshot] = WidgetSheetStore.read(),
                 calendar: Calendar = .current) -> [SheetWidgetEntry] {
        guard let id else { return [SheetWidgetEntry(date: date, content: .selectSheet)] }
        guard let sheet = sheets.first(where: { $0.id == id }) else {
            return [SheetWidgetEntry(date: date, content: .unavailable)]
        }
        let current = sheet.displayed(at: date, calendar: calendar)
        var entries = [SheetWidgetEntry(date: date, content: current.map(SheetWidgetContent.spending) ?? .needsRefresh(id))]
        guard current != nil else { return entries }
        let lastDay = sheet.ledger?.lastDisplayDay ?? calendar.startOfDay(for: date)
        var day = calendar.startOfDay(for: date)
        while let next = calendar.date(byAdding: .day, value: 1, to: day), next.compare(lastDay) != .orderedDescending {
            guard let projected = sheet.displayed(at: next, calendar: calendar) else { break }
            entries.append(SheetWidgetEntry(date: next, content: .spending(projected)))
            day = next
        }
        let expires = sheet.ledger == nil ? calendar.dateInterval(of: .month, for: date)?.end
                                         : calendar.date(byAdding: .day, value: 1, to: lastDay)
        if let expires { entries.append(SheetWidgetEntry(date: expires, content: .needsRefresh(id))) }
        return entries
    }

}

private struct SheetWidgetView: View {
    let entry: SheetWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch entry.content {
            case let .spending(sheet):
                Label {
                    Text(verbatim: sheet.name)
                } icon: {
                    SheetSymbolIcon(symbol: sheet.symbol ?? "person.2.fill",
                                    tint: Color(hex: sheet.colorHex ?? "#5B8DEF") ?? .indigo,
                                    size: 24, cutsOutSymbol: renderingMode != .fullColor)
                        .accessibilityHidden(true)
                }
                    .font(.headline)
                    .lineLimit(1)
                if family == .systemLarge {
                    LargeSheetWidgetContent(sheet: sheet)
                } else {
                    Spacer(minLength: 0)
                    Text("今月の支出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(sheet.expense, format: .currency(code: sheet.currency))
                        .font(.title.bold())
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                }
                if sheet.missingRates {
                    Text("為替レート未取得の明細を除く")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .selectSheet, .unavailable:
                Label("今月の支出", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("ウィジェットを編集してシートを選んでください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .needsRefresh:
                Text("今月の支出").font(.headline)
                Spacer(minLength: 0)
                Text("Budgetyを開いて更新してください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(entry.sheetURL)
        .privacySensitive()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }
}

struct BudgetySheetWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSheetStore.kind, intent: SelectWidgetSheet.self, provider: SheetWidgetProvider()) { entry in
            SheetWidgetView(entry: entry)
        }
        .configurationDisplayName("今月の支出")
        .description("選んだシートの今月の収支と直近の支出を表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}


@main
struct BudgetyWidgets: WidgetBundle {
    var body: some Widget {
        BudgetySheetWidget()
        ExpenseChartWidget()
    }
}

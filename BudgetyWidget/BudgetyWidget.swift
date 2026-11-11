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

private enum SheetWidgetContent {
    case spending(WidgetSheetSnapshot)
    case selectSheet
    case unavailable
    case needsRefresh
}

private struct SheetWidgetEntry: TimelineEntry {
    let date: Date
    let content: SheetWidgetContent
}

private struct SheetWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SheetWidgetEntry {
        let sample = WidgetSheetSnapshot(id: "preview", name: String(localized: "家計"), symbol: "house.fill",
                                         colorHex: "#AF52DE", monthStart: .now, expense: 28400, income: 0,
                                         currency: "JPY", missingRates: false)
        return SheetWidgetEntry(date: .now, content: .spending(sample))
    }

    func snapshot(for configuration: SelectWidgetSheet, in context: Context) async -> SheetWidgetEntry {
        if context.isPreview && configuration.sheet == nil { return placeholder(in: context) }
        return entry(for: configuration, at: .now)
    }

    func timeline(for configuration: SelectWidgetSheet, in context: Context) async -> Timeline<SheetWidgetEntry> {
        let now = Date.now
        let current = entry(for: configuration, at: now)
        var entries = [current]
        if case .spending = current.content,
           let nextMonth = Calendar.current.dateInterval(of: .month, for: now)?.end {
            // Stop labeling last month's amount as current even if WidgetKit delays the refresh.
            entries.append(SheetWidgetEntry(date: nextMonth, content: .needsRefresh))
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600)))
    }

    private func entry(for configuration: SelectWidgetSheet, at date: Date) -> SheetWidgetEntry {
        guard let id = configuration.sheet?.id else {
            return SheetWidgetEntry(date: date, content: .selectSheet)
        }
        guard let sheet = WidgetSheetStore.read().first(where: { $0.id == id }) else {
            return SheetWidgetEntry(date: date, content: .unavailable)
        }
        guard Calendar.current.isDate(sheet.monthStart, equalTo: date, toGranularity: .month) else {
            return SheetWidgetEntry(date: date, content: .needsRefresh)
        }
        return SheetWidgetEntry(date: date, content: .spending(sheet))
    }
}

private struct SheetWidgetView: View {
    let entry: SheetWidgetEntry
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
                Spacer(minLength: 0)
                Text("今月の支出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sheet.expense, format: .currency(code: sheet.currency))
                    .font(.title.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
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
        .privacySensitive()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }
}

@main
struct BudgetySheetWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSheetStore.kind, intent: SelectWidgetSheet.self, provider: SheetWidgetProvider()) { entry in
            SheetWidgetView(entry: entry)
        }
        .configurationDisplayName("今月の支出")
        .description("選んだシートの今月の支出を表示します。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

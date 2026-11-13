#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import SwiftUI
import Foundation

/// Store the read request, never financial results. Every redraw rechecks access and recomputes.
@available(iOS 27.3, macOS 27.3, *)
struct SiriReadReportSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "予算・予定・立て替えの結果を表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "シート識別子") var sheetID: String
    @Parameter(title: "表示種別") var mode: String
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "検索期間") var period: SiriExpensePeriod?
    @Parameter(title: "カテゴリ") var category: String?
    @Parameter(title: "支払通貨") var source: String?
    @Parameter(title: "表示通貨") var target: String?
    @Parameter(title: "名前") var name: String?
    @Parameter(title: "開始日") var start: Date?
    @Parameter(title: "終了日") var end: Date?
    @Parameter(title: "表示件数") var limit: Int?
    @Parameter(title: "すべての予定を表示") var showAll: Bool?
    @Parameter(title: "次回のみ") var next: Bool?
    @Parameter(title: "種別") var kind: TransactionKind?
    @Parameter(title: "頻度") var frequency: RecurrenceFrequency?
    @Parameter(title: "メンバー") var member: SiriSheetMemberEntity?
    init() {}
    init(budget: SiriBudgetStatusIntent, sheetID: String) {
        self.init(); self.sheetID = sheetID; mode = "budget"
        month = budget.month ?? .now; category = budget.categoryName; source = budget.sourceCurrency; target = budget.targetCurrency
    }
    init(forecast: SiriRecurringForecastIntent, sheetID: String) {
        self.init(); self.sheetID = sheetID; mode = "forecast"
        month = forecast.month ?? Calendar.current.date(byAdding: .month, value: 1, to: .now); category = forecast.categoryName; source = forecast.sourceCurrency; target = forecast.targetCurrency
        name = forecast.transactionName; start = forecast.startDate; end = forecast.endDate; next = forecast.nextOnly
        if forecast.nextOnly == true {
            start = forecast.startDate ?? Calendar.current.startOfDay(for: .now)
            end = forecast.endDate ?? start.flatMap { Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.date(byAdding: .year, value: 1, to: $0) ?? $0) }
        }
        limit = forecast.limit; showAll = forecast.showAll
        kind = forecast.kind; frequency = forecast.frequency
    }
    init(advances: SiriMemberAdvancesIntent, sheetID: String) {
        self.init(); self.sheetID = sheetID; mode = "advances"
        month = advances.month; day = advances.day; period = advances.period; member = advances.member
    }
    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let record = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext).resolve(sheetID)
        let sheet = ExpenseSheetEntity.from(record)
        let report: String
        let title: String
        switch mode {
        case "budget":
            var intent = SiriBudgetStatusIntent()
            intent.sheet = sheet; intent.month = month; intent.categoryName = category; intent.sourceCurrency = source; intent.targetCurrency = target
            report = try await intent.report().text; title = "予算と残額"
        case "forecast":
            var intent = SiriRecurringForecastIntent()
            intent.sheet = sheet; intent.month = month; intent.categoryName = category; intent.sourceCurrency = source; intent.targetCurrency = target
            intent.limit = limit; intent.showAll = showAll
            intent.transactionName = name; intent.startDate = start; intent.endDate = end; intent.nextOnly = next; intent.kind = kind; intent.frequency = frequency
            report = try await intent.report().text; title = "定期収支の予定"
        default:
            var intent = SiriMemberAdvancesIntent()
            intent.sheet = sheet; intent.month = month; intent.day = day; intent.period = period; intent.member = member
            report = try await intent.report().text; title = "立て替え総額"
        }
        return .result { SiriReadReportView(title: title, report: report) }
    }
}

@available(iOS 27.3, macOS 27.3, *)
private struct SiriReadReportView: View {
    let title: String
    let report: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "chart.bar.doc.horizontal").font(.headline)
            ForEach(Array(report.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                if index == 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(line.components(separatedBy: "。").filter { !$0.isEmpty }.enumerated()), id: \.offset) { offset, sentence in
                            Text(sentence).font(offset == 0 ? .headline : .subheadline)
                                .foregroundStyle(offset == 0 ? .primary : .secondary)
                        }
                    }
                } else {
                    Divider()
                    Text(line).font(.subheadline)
                }
            }
        }.padding()
    }
}
#endif

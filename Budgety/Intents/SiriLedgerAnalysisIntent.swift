#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation
import SwiftUI

// The scope travels with the Siri result. Separate conversations and sheets never share a last-query cache.
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriLedgerQuestionContext: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "直前の集計"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Property(title: "表示した集計") var label: String
    #if os(watchOS)
    @Property(title: "集計条件") var criteria: String
    #else
    @Property(title: "集計条件", visibility: .internal) var criteria: String
    #endif
    @Property(title: "この1件の編集対象") var editableTransaction: SiriEditableTransactionEntity?

    init() {}
    init(sheetID: String, interval: DateInterval?, period: String, kind: SiriTransactionSelection,
         name: String? = nil, category: String? = nil, memberID: String? = nil, sourceCurrency: String? = nil,
         targetCurrency: String? = nil, foreignOnly: Bool = false, grouped: Bool = false, singleID: String? = nil) throws {
        var query = SiriLedgerQuestion(sheetID: sheetID, interval: interval, period: period)
        query.kind = kind.rawValue
        query.name = name
        query.category = category
        query.memberID = memberID
        query.sourceCurrency = sourceCurrency
        query.targetCurrency = targetCurrency
        query.foreignOnly = foreignOnly
        query.grouped = grouped
        query.singleID = singleID
        try self.init(query: query, label: period)
    }

    fileprivate init(query: SiriLedgerQuestion, label: String) throws {
        self.label = label
        criteria = String(decoding: try JSONEncoder().encode(query), as: UTF8.self)
    }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
private struct SiriLedgerQuestion: Codable {
    var sheetID: String
    var interval: DateInterval?
    var period: String
    var kind = SiriTransactionSelection.expense.rawValue
    var mode = SiriAnalysisMode.transactions.rawValue
    var name: String?
    var category: String?
    var memberID: String?
    var sourceCurrency: String?
    var targetCurrency: String?
    var foreignOnly = false
    var grouped = false
    var excludedName: String?
    var excludedCategory: String?
    var selectedID: String?
    var excludedID: String?
    var singleID: String?
    var minimum: Double?
    var maximum: Double?
    var minimumExclusive = false
    var maximumExclusive = false
    var sort: String?
    var limit: Int?
    var all = false
    var comparisonInterval: DateInterval?
    var comparisonLabel: String?

    @MainActor
    func report() throws -> SiriAnalysisReport {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try access.resolve(sheetID)
        guard let mode = SiriAnalysisMode(rawValue: mode), let kind = SiriTransactionSelection(rawValue: kind)
        else { throw QuestionError.invalid }
        var request = SiriAnalysisRequest(mode: mode)
        request.kind = kind
        if let memberID {
            let roster = try SiriSheetMemberRoster(sheet: sheet, access: access)
            guard let member = roster.members.first(where: { $0.id == memberID }) else { throw AppIntentError.missingPayer }
            request.member = member
        }
        request.name = name
        request.category = category
        request.currency = sourceCurrency
        request.targetCurrency = targetCurrency
        request.foreignOnly = foreignOnly
        request.groupByOriginal = grouped
        request.excludedName = excludedName
        request.excludedCategory = excludedCategory
        request.excludedTransactionID = excludedID
        request.selectedTransactionID = selectedID
        guard minimum?.isFinite != false, maximum?.isFinite != false else { throw QuestionError.invalid }
        request.minimum = minimum.map { Decimal($0) }
        request.maximum = maximum.map { Decimal($0) }
        request.minimumExclusive = minimumExclusive
        request.maximumExclusive = maximumExclusive
        request.limit = all ? nil : (limit ?? 3)
        request.sort = sort.flatMap(SiriAnalysisSort.init(rawValue:))
        let scope = SiriExpenseScope(interval: interval, label: period, isDay: false)
        let comparison = comparisonInterval.map { SiriExpenseScope(interval: $0, label: comparisonLabel ?? period, isDay: false) }
        return try SiriTransactionAnalysis.run(sheet: sheet, access: access, scope: scope, request: request, comparison: comparison)
    }
}

private enum QuestionError: Error, CustomLocalizedStringResourceConvertible {
    case invalid, reference, interval
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalid: "集計条件を指定し直してください。"
        case .reference: "どの明細ですか？ 明細の名前を指定してください。"
        case .interval: "集計する期間の開始日と終了日を指定してください。"
        }
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
enum SiriAnalysisReference: String, AppEnum {
    case select, exclude
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "直前の明細の扱い"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.select: "その明細だけ", .exclude: "その明細を除く"]
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriAnalyzeLedgerIntent: AppIntent {
    static let title: LocalizedStringResource = "明細の内訳・比較・換算を表示"
    static let description = IntentDescription("家計簿の集計方法を選び、合計だけ、通貨・お店・カテゴリ・人・日・月別、期間比較、増えたカテゴリ、1日平均、金額順位、換算レートを表示します。「そのうち食費だけ」「元はいくら？」「それを除くと？」など続く質問では、前の回答の集計条件を引き継ぎます。", searchKeywords: ["内訳", "換算", "比較", "一番高い", "平均", "以外", "元の金額"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "直前の集計", description: "「そのうち」「それを除くと」「ドルで表示して」など同じ対象について続けて聞かれた場合、前の回答が返した集計条件。") var previous: SiriLedgerQuestionContext?
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "表示方法") var mode: SiriAnalysisMode?
    @Parameter(title: "収入・支出・収支") var kind: SiriTransactionSelection?
    @Parameter(title: "検索期間") var period: SiriExpensePeriod?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "開始日") var startDate: Date?
    @Parameter(title: "終了日", description: "旅行中や今年など任意の期間の最終日を含みます。") var endDate: Date?
    @Parameter(title: "比較する月", description: "先月と今月を比較する場合、先月。省略すると対象期間の直前の期間。") var comparisonMonth: Date?
    @Parameter(title: "比較期間の開始日") var comparisonStart: Date?
    @Parameter(title: "比較期間の終了日", description: "この日を含みます。") var comparisonEnd: Date?
    @Parameter(title: "カテゴリ名") var category: String?
    @Parameter(title: "店名・明細名") var name: String?
    @Parameter(title: "メンバー") var member: SiriSheetMemberEntity?
    @Parameter(title: "元の取引通貨", description: "「ドルで払った分だけ」はUSD。") var sourceCurrency: String?
    @Parameter(title: "表示通貨", description: "「円にすると」「ユーロ換算で」の換算先。") var targetCurrency: String?
    @Parameter(title: "外貨だけ") var foreignOnly: Bool?
    @Parameter(title: "元の通貨別で表示") var groupByOriginal: Bool?
    @Parameter(title: "除外する明細名", description: "「給料以外」を明細名で指定した場合は給料。") var excludedName: String?
    @Parameter(title: "除外するカテゴリ") var excludedCategory: String?
    #if os(watchOS)
    @Parameter(title: "対象の明細") var transaction: SiriEditableTransactionEntity?
    #else
    @Parameter(title: "対象の明細") var transaction: SiriListedTransactionEntity?
    #endif
    @Parameter(title: "直前の1件", description: "「それを除くと？」は除外、「元はいくら？」はその明細だけ。") var reference: SiriAnalysisReference?
    @Parameter(title: "下限額") var minimum: Double?
    @Parameter(title: "上限額") var maximum: Double?
    @Parameter(title: "下限額を含めない", description: "「1万円を超えた」はオン。「1万円以上」はオフ。") var minimumExclusive: Bool?
    @Parameter(title: "上限額を含めない") var maximumExclusive: Bool?
    @Parameter(title: "並べ方") var sort: SiriAnalysisSort?
    @Parameter(title: "表示件数", description: "「一番高い」は1、「直近3件」は3。") var limit: Int?
    @Parameter(title: "全件表示") var showAll: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriLedgerQuestionContext> & ProvidesDialog & ShowsSnippetIntent {
        let saved = try previous.map { try JSONDecoder().decode(SiriLedgerQuestion.self, from: Data($0.criteria.utf8)) }
        let sheetID: String
        if let id = sheet?.id ?? member.flatMap({ $0.id.components(separatedBy: "#").first }) ?? saved?.sheetID { sheetID = id }
        else {
            sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: nil) {
                try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートを調べますか？")
            }
        }
        let inherited = saved.flatMap { $0.sheetID == sheetID ? $0 : nil }
        let filter = SiriExpenseSearchFilter(expenseName: nil, month: month, day: day, period: period)
        var q = inherited ?? SiriLedgerQuestion(sheetID: sheetID, interval: filter.scope.interval, period: filter.scope.label)
        if startDate != nil || endDate != nil {
            let cal = Calendar.current
            guard let startDate, let endDate, cal.startOfDay(for: startDate) <= cal.startOfDay(for: endDate),
                  let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate)) else { throw QuestionError.interval }
            let start = cal.startOfDay(for: startDate)
            q.interval = DateInterval(start: start, end: end)
            q.period = start.formatted(date: .abbreviated, time: .omitted) + "〜" + endDate.formatted(date: .abbreviated, time: .omitted)
        } else if day != nil || month != nil || period != nil {
            q.interval = filter.scope.interval
            q.period = filter.scope.label
        }
        if let mode { q.mode = mode.rawValue }
        if let kind { q.kind = kind.rawValue }
        q.category = category ?? q.category
        q.name = name ?? q.name
        q.memberID = member?.id ?? q.memberID
        q.sourceCurrency = sourceCurrency ?? q.sourceCurrency
        q.targetCurrency = targetCurrency ?? q.targetCurrency
        if let groupByOriginal { q.grouped = groupByOriginal }
        else if targetCurrency != nil { q.grouped = false }
        if mode == .currency { q.grouped = true }
        else if targetCurrency != nil, q.mode == SiriAnalysisMode.currency.rawValue { q.mode = SiriAnalysisMode.total.rawValue }
        q.foreignOnly = foreignOnly ?? q.foreignOnly
        q.excludedName = excludedName ?? q.excludedName
        q.excludedCategory = excludedCategory ?? q.excludedCategory
        if minimum != nil { q.minimumExclusive = minimumExclusive ?? false }
        if maximum != nil { q.maximumExclusive = maximumExclusive ?? false }
        q.minimum = minimum ?? q.minimum
        q.maximum = maximum ?? q.maximum
        let impliedSingle = mode == .originalAmounts || mode == .exchangeRates
        if let reference = reference ?? (impliedSingle && inherited?.singleID != nil ? .select : nil) {
            guard let id = transaction?.id ?? inherited?.singleID else { throw QuestionError.reference }
            if reference == .exclude { q.excludedID = id; q.selectedID = nil; q.mode = (mode ?? .total).rawValue }
            else { q.selectedID = id }
            q.limit = nil
            q.sort = nil
        } else if let transaction { q.selectedID = transaction.id }
        if let sort { q.sort = sort.rawValue }
        if let limit { q.limit = limit; q.all = false }
        q.all = showAll ?? q.all
        let needsComparison = q.mode == SiriAnalysisMode.comparison.rawValue || q.mode == SiriAnalysisMode.categoryIncrease.rawValue
        let changedScope = day != nil || month != nil || period != nil || startDate != nil || endDate != nil
        if needsComparison && (comparisonStart != nil || comparisonEnd != nil || comparisonMonth != nil || changedScope || q.comparisonInterval == nil) {
            guard let interval = q.interval else { throw QuestionError.interval }
            let cal = Calendar.current
            let earlier: DateInterval
            if comparisonStart != nil || comparisonEnd != nil {
                guard let comparisonStart, let comparisonEnd,
                      cal.startOfDay(for: comparisonStart) <= cal.startOfDay(for: comparisonEnd),
                      let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: comparisonEnd)) else { throw QuestionError.interval }
                earlier = DateInterval(start: cal.startOfDay(for: comparisonStart), end: end)
            } else if let comparisonMonth, let month = cal.dateInterval(of: .month, for: comparisonMonth) { earlier = month }
            else if let year = cal.dateInterval(of: .year, for: interval.start), year == interval,
                    let previous = cal.date(byAdding: .year, value: -1, to: interval.start),
                    let previousYear = cal.dateInterval(of: .year, for: previous) { earlier = previousYear }
            else if let month = cal.dateInterval(of: .month, for: interval.start), month == interval,
                    let previous = cal.date(byAdding: .month, value: -1, to: interval.start),
                    let previousMonth = cal.dateInterval(of: .month, for: previous) { earlier = previousMonth }
            else {
                let days = cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
                guard days > 0, let start = cal.date(byAdding: .day, value: -days, to: interval.start) else { throw QuestionError.interval }
                earlier = DateInterval(start: start, end: interval.start)
            }
            q.comparisonInterval = earlier
            q.comparisonLabel = earlier.start.formatted(date: .abbreviated, time: .omitted) + "〜" +
                earlier.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
        }
        let report = try q.report()
        q.singleID = report.singleTransactionID
        var result = try SiriLedgerQuestionContext(query: q, label: report.scope + "・" + report.title)
        if let id = q.singleID {
            let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
            result.editableTransaction = try SiriEditableTransactionQuery.resolve([id], in: sheetID, access: access).first
        }
        return .result(value: result, dialog: IntentDialog("\(report.dialog)"),
                       snippetIntent: SiriLedgerAnalysisSnippet(criteria: result.criteria))
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriLedgerAnalysisSnippet: SnippetIntent {
    static let title: LocalizedStringResource = "集計のカードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "集計条件") var criteria: String
    init() {}
    init(criteria: String) { self.criteria = criteria }
    @MainActor func perform() async throws -> some IntentResult & ShowsSnippetView {
        let query = try JSONDecoder().decode(SiriLedgerQuestion.self, from: Data(criteria.utf8))
        return .result(view: SiriAnalysisCard(report: try query.report()))
    }
}
#endif

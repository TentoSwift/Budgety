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
    @Property(title: "月別順位の回答（月と合計額）") var monthlyAnswer: String?
    @Property(title: "使った金額と該当する明細の回答") var spendingAnswer: String?
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
private struct AdditionalMonthlyRanking: Codable {
    let interval: DateInterval?
    let period: String
    let sort: String
    let rank: Int?
    let limit: Int?
    let category: String?
    let kind: String

    func ranking() throws -> SiriMonthlyRanking {
        guard let order = SiriAnalysisSort(rawValue: sort), order == .highest || order == .lowest,
              let selection = SiriTransactionSelection(rawValue: kind) else { throw QuestionError.invalid }
        return SiriMonthlyRanking(scope: SiriExpenseScope(interval: interval, label: period, isDay: false),
                                  sort: order, rank: rank, limit: limit, category: category, kind: selection)
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
private struct SiriLedgerQuestion: Codable {
    var sheetID: String
    var interval: DateInterval?
    var period: String
    var kind = SiriTransactionSelection.expense.rawValue
    var mode = SiriAnalysisMode.transactions.rawValue
    var totalOnly: Bool?
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
    var rank: Int?
    var all = false
    var comparisonInterval: DateInterval?
    var comparisonLabel: String?
    var additionalMonthlyRankings: [AdditionalMonthlyRanking]?

    @MainActor
    func report() throws -> SiriAnalysisReport {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try report(in: access.resolve(sheetID), access: access)
    }

    @MainActor
    func report(in sheet: ExpenseSheet, access: IntentSheetAccess) throws -> SiriAnalysisReport {
        guard let mode = SiriAnalysisMode(rawValue: mode), let kind = SiriTransactionSelection(rawValue: kind)
        else { throw QuestionError.invalid }
        var request = SiriAnalysisRequest(mode: mode)
        request.totalOnly = totalOnly == true
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
        request.rank = rank
        request.sort = sort.flatMap(SiriAnalysisSort.init(rawValue:))
        let scope = SiriExpenseScope(interval: interval, label: period, isDay: false)
        if mode == .month, let order = request.sort, order == .highest || order == .lowest {
            let first = SiriMonthlyRanking(scope: scope, sort: order, rank: rank, limit: request.limit, category: category, kind: kind)
            let additional = try (additionalMonthlyRankings ?? []).map { try $0.ranking() }
            // Each condition carries its category, including an explicitly unfiltered second question.
            request.category = nil
            return try SiriTransactionAnalysis.runMonthlyRankings(sheet: sheet, access: access, request: request, rankings: [first] + additional)
        }
        let comparison = comparisonInterval.map { SiriExpenseScope(interval: $0, label: comparisonLabel ?? period, isDay: false) }
        return try SiriTransactionAnalysis.run(sheet: sheet, access: access, scope: scope, request: request, comparison: comparison)
    }
}

private enum QuestionError: Error, CustomLocalizedStringResourceConvertible {
    case invalid, reference, interval, missingRank
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .missingRank: "何番目の明細を調べますか？"
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
    static let description = IntentDescription("「寿司系で何円使った？」など支出額を聞かれたら、支出額の質問全文に発言を渡し、該当する店やカテゴリの合計と明細を答えます。家計簿の集計方法を選び、合計、通貨・お店・カテゴリ・人・日・月別、期間比較、増えたカテゴリ、1日平均、金額順位、換算レートを表示します。「2番目に高い出費」「先月の食費で2番目に安いもの」「安い順に3件」「次に高いのは？」など金額の順位にも使います。「今年、食費が一番高かったのは何月？」「直近半年で食費が安かった月を3つ教えて」は、月ごとの合計を順位付けして、月と金額を返します。2つを一度に聞かれたら「月別順位の質問全文」に両方の質問を省略せずにそのまま渡します。「そのうち食費だけ」「元はいくら？」「それを除くと？」など続く質問では、前の回答の集計条件を引き継ぎます。", searchKeywords: ["何円使った", "いくら使った", "内訳", "換算", "比較", "何番目", "高い順", "安い順", "平均", "以外", "元の金額", "何月", "安かった月", "月別順位", "直近半年"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "直前の集計", description: "「そのうち」「それを除くと」「ドルで表示して」など同じ対象について続けて聞かれた場合、前の回答が返した集計条件。") var previous: SiriLedgerQuestionContext?
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "表示方法", description: "「何円使った？」「いくら使った？」は合計。該当する最近の明細も表示します。") var mode: SiriAnalysisMode?
    @Parameter(title: "支出額の質問全文", description: "「寿司系で何円使った？」「はま寿司とかっぱ寿司でいくら使った？」など、支出の合計を聞かれた発言。期間・店名・系・など・通貨・合計だけの指定を含めて渡します。") var spendingQuestion: String?
    @Parameter(title: "合計だけ", description: "「合計だけ」「金額のみ」と明示された場合に限り、該当明細を省略します。") var totalOnly: Bool?
    @Parameter(title: "収入・支出・収支") var kind: SiriTransactionSelection?
    @Parameter(title: "検索期間") var period: SiriExpensePeriod?
    @Parameter(title: "月別順位の質問全文", description: "「今年、食費が一番高かったのは何月？ 直近半年で食費が安かった月を3つ教えて」など、月の順位を尋ねた発言。複数の質問を一度に聞かれた場合は、各期間・カテゴリ・順位・件数を含め、両方の質問をそのまま渡します。") var monthlyQuestion: String?
    @Parameter(title: "2つ目の月別順位の期間", description: "同時に2つの月別順位を聞かれた場合の後半の期間。「直近半年」は今月を含む6か月。") var additionalPeriod: SiriExpensePeriod?
    @Parameter(title: "2つ目の月別順位の並べ方", description: "後半の質問が「安かった月」なら金額が低い順。") var additionalSort: SiriAnalysisSort?
    @Parameter(title: "2つ目の月別順位", description: "後半の質問が「2番目に高い月」なら2。") var additionalRank: Int?
    @Parameter(title: "2つ目の月別順位の表示件数", description: "後半の質問が「安かった月を3つ」なら3。") var additionalLimit: Int?
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
    @Parameter(title: "順位", description: "「2番めに高い」「安い方から二番目」は2。「一番安い」は1。指定した順位の1件を返します。") var rank: Int?
    @Parameter(title: "直前の順位の次", description: "「その次は？」「次に高いのは？」のように直前の順位から1つ進むときに指定します。") var nextRank: Bool?
    @Parameter(title: "表示件数", description: "「高い順に2件」は2、「直近3件」は3。特定の順位だけを聞かれた場合は順位を使います。") var limit: Int?
    @Parameter(title: "全件表示") var showAll: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriLedgerQuestionContext> & ProvidesDialog & ShowsSnippetIntent {
        let (report, result) = try await analyze()
        return .result(value: result, dialog: IntentDialog("\(report.dialog)"),
                       snippetIntent: SiriLedgerAnalysisSnippet(criteria: result.criteria))
    }

    @MainActor
    func analyze() async throws -> (SiriAnalysisReport, SiriLedgerQuestionContext) {
        let saved = try previous.map { try JSONDecoder().decode(SiriLedgerQuestion.self, from: Data($0.criteria.utf8)) }
        let sheetID: String
        if let id = sheet?.id ?? member.flatMap({ $0.id.components(separatedBy: "#").first }) ?? saved?.sheetID { sheetID = id }
        else {
            sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: nil) {
                try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートを調べますか？")
            }
        }
        let inherited = saved.flatMap { $0.sheetID == sheetID ? $0 : nil }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let record = try access.resolve(sheetID)
        func monthlyClauses(_ text: String?) -> [SiriSpokenMonthlyRanking] {
            SiriSpokenMonthlyRanking.clauses(in: text, sheetName: record.displayName)
        }
        let spoken = SiriSpokenRankingRequest(name)
        let spending = [spendingQuestion, name, category].lazy.compactMap(SiriSpokenSpendingRequest.init).first
        let clauses = [monthlyQuestion, name, category].compactMap { $0 }.lazy
            .map { monthlyClauses($0) }.first(where: { !$0.isEmpty }) ?? []
        let first = clauses.first
        let categoryIsQuestion = first != nil && !monthlyClauses(category).isEmpty
        let secondSpecified = additionalPeriod != nil || additionalSort != nil || additionalRank != nil || additionalLimit != nil
        if monthlyQuestion != nil && first == nil && mode != .month && !secondSpecified { throw QuestionError.invalid }
        let nameSubject = TransactionSearchTerm.sushiSubject(name)
        let categorySubject = TransactionSearchTerm.sushiSubject(category)
        let spokenSubject = TransactionSearchTerm.sushiSubject(spending?.subject)
        // When Siri shortens 寿司系 to a category named 寿司, prefer a real category on this sheet.
        let missingSushiCategory = categorySubject == "寿司" && !(record.categories as? Set<ExpenseCategory> ?? []).contains {
            TransactionSearchTerm(category ?? "").matchesCategory($0.displayName)
        }
        let isSpendingGroup = [spokenSubject, nameSubject, categorySubject].compactMap { $0 }.contains { $0 != "寿司" }
        let wantsSpending = spending != nil || isSpendingGroup
        let resolvedMode: SiriAnalysisMode? = first != nil || secondSpecified ? .month : mode ?? (wantsSpending ? .total : nil)
        let requestedRank = rank ?? (limit == nil ? first?.rank ?? spoken.rank : nil)
        let requestedCount = limit ?? first?.limit ?? spoken.limit
        let requestedSort = sort ?? first?.sort ?? spoken.sort
        let advance = nextRank ?? spoken.next
        let searchPeriod = period ?? first?.period ?? spoken.period ?? spending?.period
        let now = Date.now
        let calendar = Calendar.current
        let isMonthly = resolvedMode == .month || (resolvedMode == nil && inherited?.mode == SiriAnalysisMode.month.rawValue)
        // Fresh month rankings without a period cover the recorded history; inherited questions keep their scope.
        let monthOrder = requestedSort ?? inherited?.sort.flatMap(SiriAnalysisSort.init(rawValue:))
        let ranksMonths = isMonthly && (monthOrder == .highest || monthOrder == .lowest || requestedRank != nil || secondSpecified)
        let fallback: SiriExpensePeriod = ranksMonths ? .allTime : .thisMonth
        var scope = SiriExpenseSearchFilter(expenseName: nil, month: month, day: day, period: searchPeriod,
                                            unnamedPeriod: fallback, now: now, calendar: calendar).scope
        if ranksMonths, searchPeriod == .thisYear, day == nil {
            scope = Self.monthlyScope(.thisYear, now: now, calendar: calendar)
        }
        if let months = first?.recentMonths, period == nil, day == nil, month == nil {
            scope = SiriExpenseScope(recentMonths: months, now: now, calendar: calendar)
        }
        var q = inherited ?? SiriLedgerQuestion(sheetID: sheetID, interval: scope.interval, period: scope.label)
        if startDate != nil || endDate != nil {
            let cal = Calendar.current
            guard let startDate, let endDate, cal.startOfDay(for: startDate) <= cal.startOfDay(for: endDate),
                  let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate)) else { throw QuestionError.interval }
            let start = cal.startOfDay(for: startDate)
            q.interval = DateInterval(start: start, end: end)
            q.period = start.formatted(date: .abbreviated, time: .omitted) + "〜" + endDate.formatted(date: .abbreviated, time: .omitted)
        } else if day != nil || month != nil || searchPeriod != nil || first?.recentMonths != nil {
            q.interval = scope.interval
            q.period = scope.label
        }
        if let resolvedMode { q.mode = resolvedMode.rawValue }
        if let selection = kind ?? first?.kind ?? spoken.kind ?? (wantsSpending ? .expense : nil) { q.kind = selection.rawValue }
        q.category = (categoryIsQuestion ? nil : category) ?? first?.category ?? (first?.kind == nil ? q.category : nil)
        if !spoken.isRanking, (first == nil || monthlyQuestion != nil), let name, name != monthlyQuestion {
            // Siri sometimes copies the category (or the entire question) into the merchant field as well.
            if ranksMonths, name == q.category || !monthlyClauses(name).isEmpty { q.name = nil }
            else { q.name = name }
        }
        if first == nil, !spoken.isRanking {
            let amountMode = resolvedMode == .total || spending != nil
            let subject = spokenSubject ?? nameSubject ?? categorySubject
            if let subject, isSpendingGroup || (amountMode && (spokenSubject != nil || nameSubject != nil || missingSushiCategory)) {
                // The group must match a transaction title OR its displayed category, including recurring rows.
                q.name = subject == "寿司" ? "寿司系" : subject
                if categorySubject != nil || SiriSpokenSpendingRequest(category) != nil { q.category = nil }
                if let name, nameSubject == nil, SiriSpokenSpendingRequest(name) == nil {
                    q.name = name
                }
            } else if let spending {
                if SiriSpokenSpendingRequest(category) != nil { q.category = nil }
                q.name = q.category == spending.subject ? nil : spending.subject
            }
        }
        q.totalOnly = totalOnly ?? spending.map(\.totalOnly) ?? q.totalOnly
        q.memberID = member?.id ?? q.memberID
        q.sourceCurrency = sourceCurrency ?? q.sourceCurrency
        let displayCurrency = targetCurrency ?? spending?.targetCurrency
        q.targetCurrency = displayCurrency ?? q.targetCurrency
        if let groupByOriginal { q.grouped = groupByOriginal }
        else if displayCurrency != nil { q.grouped = false }
        if groupByOriginal == true, resolvedMode == nil,
           q.mode == SiriAnalysisMode.transactions.rawValue || q.mode == SiriAnalysisMode.total.rawValue {
            q.mode = SiriAnalysisMode.currency.rawValue
            q.rank = nil
        }
        if mode == .currency { q.grouped = true }
        else if displayCurrency != nil, q.mode == SiriAnalysisMode.currency.rawValue { q.mode = SiriAnalysisMode.total.rawValue }
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
            q.rank = nil
            q.sort = nil
        } else if let transaction { q.selectedID = transaction.id }
        if let resolvedMode, inherited?.mode != resolvedMode.rawValue { q.rank = nil }
        if let requestedSort { q.sort = requestedSort.rawValue }
        if let requestedCount { q.limit = requestedCount; q.rank = nil; q.all = false }
        if showAll == true { q.rank = nil; q.limit = nil }
        q.all = showAll ?? q.all
        if advance || requestedRank != nil {
            if resolvedMode == nil, (!isMonthly && inherited?.rank == nil) || spoken.kind != nil {
                q.mode = SiriAnalysisMode.transactions.rawValue
            }
            q.selectedID = nil
            if let requestedRank { q.rank = requestedRank }
            else {
                let lastRank: Int?
                if let previousRank = inherited?.rank {
                    lastRank = previousRank
                } else if let order = requestedSort, order == .highest || order == .lowest {
                    // In a fresh question, 「次に高い」 means second-highest.
                    lastRank = 1
                } else if inherited?.limit == 1, inherited?.singleID != nil || ranksMonths {
                    lastRank = 1
                } else {
                    lastRank = nil
                }
                guard let lastRank, lastRank > 0, lastRank < Int.max else { throw QuestionError.missingRank }
                q.rank = lastRank + 1
            }
            q.all = false
            q.limit = nil
        }
        if isMonthly, first != nil || secondSpecified || requestedSort != nil || requestedRank != nil || requestedCount != nil
            || advance || searchPeriod != nil || startDate != nil || endDate != nil || day != nil || month != nil {
            if q.sort == nil, q.rank != nil || secondSpecified { q.sort = SiriAnalysisSort.highest.rawValue }
            if transaction == nil, reference != .select { q.selectedID = nil }
            let extraCount = max(clauses.count - 1, secondSpecified ? 1 : 0)
            var additional: [AdditionalMonthlyRanking] = []
            for index in 0..<extraCount {
                let clause = index + 1 < clauses.count ? clauses[index + 1] : nil
                let relative = (index == 0 ? additionalPeriod : nil) ?? clause?.period
                let periodScope = relative.map { Self.monthlyScope($0, now: now, calendar: calendar) }
                    ?? clause?.recentMonths.map { SiriExpenseScope(recentMonths: $0, now: now, calendar: calendar) }
                    ?? SiriExpenseScope(interval: q.interval, label: q.period, isDay: false)
                let explicitCount = index == 0 ? additionalLimit : nil
                let count = explicitCount ?? clause?.limit
                let position = (index == 0 ? additionalRank : nil) ?? (count == nil ? clause?.rank ?? 1 : nil)
                let order = (index == 0 ? additionalSort : nil) ?? clause?.sort ?? requestedSort ?? .highest
                let selection = clause?.kind?.rawValue ?? q.kind
                let subject = clause?.category ?? (clause?.kind == nil ? q.category : nil)
                additional.append(.init(interval: periodScope.interval, period: periodScope.label, sort: order.rawValue,
                                        rank: position, limit: count, category: subject, kind: selection))
            }
            q.additionalMonthlyRankings = additional.isEmpty ? nil : additional
        } else if isMonthly, category != nil || kind != nil {
            // A follow-up like 「交通費では？」 reapplies both period/order choices to the new subject.
            q.additionalMonthlyRankings = q.additionalMonthlyRankings?.map {
                AdditionalMonthlyRanking(interval: $0.interval, period: $0.period, sort: $0.sort, rank: $0.rank,
                                         limit: $0.limit, category: category ?? $0.category, kind: kind?.rawValue ?? $0.kind)
            }
        } else if !isMonthly {
            q.additionalMonthlyRankings = nil
        }
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
        let report = try q.report(in: record, access: access)
        q.singleID = report.singleTransactionID
        var result = try SiriLedgerQuestionContext(query: q, label: report.scope + "・" + report.title)
        if !report.sections.isEmpty {
            result.monthlyAnswer = report.dialog
        }
        if report.filteredTotalDialog != nil { result.spendingAnswer = report.dialog }
        if let id = q.singleID {
            result.editableTransaction = try SiriEditableTransactionQuery.resolve([id], in: sheetID, access: access).first
        }
        return (report, result)
    }

    private static func monthlyScope(_ period: SiriExpensePeriod, now: Date, calendar: Calendar) -> SiriExpenseScope {
        let scope = SiriExpenseScope(period: period, now: now, calendar: calendar)
        guard period == .thisYear, let start = scope.interval?.start,
              let end = calendar.dateInterval(of: .day, for: now)?.end else { return scope }
        return SiriExpenseScope(interval: DateInterval(start: start, end: end), label: String(localized: "今年"), isDay: false)
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriRankMonthsIntent: AppIntent {
    static let title: LocalizedStringResource = "支出・収入の高かった月や安かった月を調べる"
    static let description = IntentDescription("「今年、食費が一番高かったのは何月？」「直近半年で食費が安かった月を3つ教えて」など、カテゴリごとの月間合計が高い月・安い月を調べます。両方を一度に尋ねられたら、質問全文に両方を含めて1回で実行し、各期間の月と金額を返します。", searchKeywords: ["何月", "一番高かった月", "安かった月", "月ごとの順位", "直近半年", "月間合計"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "質問全文", description: "月の順位を尋ねた発言をそのまま渡します。質問が2つあるときは、両方の期間・カテゴリ・件数を含め、発言全体を省略せずに渡します。") var question: String
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "直前の集計", description: "前の質問と同じシートや条件を引き継ぐ場合に指定します。") var previous: SiriLedgerQuestionContext?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriLedgerQuestionContext> & ProvidesDialog & ShowsSnippetIntent {
        let analysis = SiriAnalyzeLedgerIntent()
        analysis.sheet = sheet
        analysis.previous = previous
        analysis.monthlyQuestion = question
        return try await analysis.perform()
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriCurrencyBreakdownIntent: AppIntent {
    static let title: LocalizedStringResource = "収入・支出を通貨別で表示"
    static let description = IntentDescription("「通貨別で表示して」「通貨ごとの内訳は？」「円とドル、それぞれいくら？」に答えます。続けて聞かれたら、直前の収入・支出・収支の集計条件を受け取り、記録時の通貨ごとに合計します。", searchKeywords: ["通貨別で表示して", "通貨ごと", "通貨別内訳"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "直前の集計", description: "前の回答の集計条件。続けて聞かれた場合、同じシート・期間・対象を使用します。") var previous: SiriLedgerQuestionContext?
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "対象の収支") var kind: SiriTransactionSelection?
    @Parameter(title: "検索期間") var period: SiriExpensePeriod?
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "カテゴリ名") var category: String?
    @Parameter(title: "メンバー") var member: SiriSheetMemberEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriLedgerQuestionContext> & ProvidesDialog & ShowsSnippetIntent {
        let analysis = SiriAnalyzeLedgerIntent()
        analysis.previous = previous
        analysis.sheet = sheet
        analysis.kind = kind
        analysis.period = period
        analysis.month = month
        analysis.day = day
        analysis.category = category
        analysis.member = member
        analysis.mode = .currency
        analysis.groupByOriginal = true
        return try await analysis.perform()
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

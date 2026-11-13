#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "支出名で明細を確認"
    static let description = IntentDescription("指定したシートの支出を支出名、カテゴリ名、日付、月で探し、通貨別の合計、直近3件と残り件数をテキストで返します。明細をすべて求められたときは全件を返します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "シート名を指定された場合だけ設定します。省略時は最後に開いたシートを使い、特定できなければ選択を求めます。")
    var sheet: ExpenseSheetEntity?

    @Parameter(title: "支出名・カテゴリ名", description: "店名や支出名の検索語。カテゴリを明示した質問にはカテゴリ名を設定します。")
    var expenseName: String?
    @Parameter(title: "カテゴリ名", description: "「今月の食費」なら「食費」。指定されたカテゴリに絞り、店名や日付の条件があれば併用します。")
    var categoryName: String?

    @Parameter(title: "対象月", description: "年月だけが指定されたときの月。「今日」や特定の日付は対象月に設定しません。")
    var month: Date?
    @Parameter(title: "対象日", description: "11月11日など、特定の1日について尋ねられたときの日付。")
    var day: Date?
    @Parameter(title: "検索期間", description: "今日・昨日・今月・先月・全期間。期間を省略すると全期間を検索します。")
    var period: SiriExpensePeriod?

    @Parameter(title: "本文に全件を表示", description: "明細を全部・全件・すべて表示するよう明示された場合のみ有効にします。「全期間」は検索期間の指定です。")
    var showAllInReply: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetIntent {
        // Existing personal shortcuts consume this action's text output.
        let request = SiriTransactionReplyRequest(expenseName)
        let filter = SiriExpenseSearchFilter(expenseName: request.search, categoryName: categoryName, month: month, day: day, period: period, unnamedPeriod: .allTime, isSpokenQuery: request.requestsAll)
        let result = try await SiriExpenseLookup.run(sheet: sheet, filter: filter, showAll: showAllInReply ?? request.requestsAll) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートで支出を検索しますか？")
        }
        let snippet = SiriExpenseResultsSnippetIntent(sheetIdentifier: result.sheetID, filter: filter)
        #if os(iOS) && DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT
        SiriCompactExperimentDiagnostics.record(.legacyTextResult)
        #endif
        return .result(value: result.report, dialog: IntentDialog("\(result.report)"), snippetIntent: snippet)
    }
}

#if os(iOS) || os(macOS)
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct SiriListTransactionsIntent: AppIntent {
    #if os(iOS) && DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT
    static let title: LocalizedStringResource = "シートの収支と明細を調べる"
    static let description = IntentDescription("「家計シートの支出を調べて」「今月の支出には何がある？」「収支は？」など、シートの明細を検索する質問に使います。期間・店名・カテゴリ・メンバーで絞った全件を新しい順の一覧にします。本文は直近3件と残り件数、すべてと指定された場合は全件を伝えます。", searchKeywords: ["支出", "収入", "収支", "明細一覧", "全件"])
    #else
    static let title: LocalizedStringResource = "すべての明細を一覧で表示"
    static let description = IntentDescription("「全件を一覧で表示」「すべての明細を見せて」のように、全件の一覧を明示したときの検索です。各明細を新しい順で返します。通常の支出・収入・収支の質問には「シートの収入・支出を検索して表示」を使います。", searchKeywords: ["全件一覧", "すべての明細"])
    #endif
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = .background

    @Parameter(title: "シート", description: "指定されたシート。省略時は指定したメンバーのシート、または最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバー", description: "支払った人や受け取った人で絞る場合に指定します。", optionsProvider: SiriListMemberQuery())
    var member: SiriSheetMemberEntity?
    @Parameter(title: "支出名・収入名", description: "指定された店名や明細名。明細全般を聞かれたら省略します。")
    var expenseName: String?
    @Parameter(title: "カテゴリ名") var categoryName: String?
    @Parameter(title: "対象の収支", description: "「収支」や明細全般は両方です。「支出だけ」「収入だけ」の指定があれば対応する種別を選びます。")
    var kind: SiriTransactionSelection?
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "検索期間", description: "今日・昨日・今月・先月・全期間。")
    var period: SiriExpensePeriod?
    @Parameter(title: "本文に全件を表示", description: "すべての明細を読み上げるよう明示された場合だけオン。「全期間」は期間の指定で、「一覧」「何がある？」も通常はオフです。")
    var showAllInReply: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SiriListedTransactionEntity]> & ProvidesDialog & ShowsSnippetIntent {
        #if os(iOS) && DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT
        SiriCompactExperimentDiagnostics.record(.searchStarted)
        #endif
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet, member: member) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの明細を一覧にしますか？")
        }
        let request = SiriTransactionReplyRequest(expenseName)
        let filter = SiriExpenseSearchFilter(expenseName: request.search, categoryName: categoryName, month: month, day: day, period: period, isSpokenQuery: request.requestsAll)
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let selected = try access.resolve(sheetID)
        let selection = filter.spokenKind ?? kind ?? .both
        let payer = try member.map { person in
            let roster = try SiriSheetMemberRoster(sheet: selected, access: access)
            return SiriMemberTransactionLookup.Payer(member: try roster.resolve(person), roster: roster, sheet: selected)
        }
        let ledger = try SiriTransactionLedger.read(sheet: selected, access: access, interval: filter.scope.interval,
                                                    includeExpenses: selection.includesExpenses, includeIncome: selection.includesIncome,
                                                    expenseName: filter.name, categoryName: filter.categoryName, allRows: true,
                                                    matchesPayer: { payer?.matches($0) ?? true })
        let reply = ledger.reply(for: selection, sheetName: selected.displayName, period: filter.scope.label,
                                 member: member?.name, category: filter.categoryName, name: filter.name,
                                 showAll: showAllInReply ?? request.requestsAll)
        let entities = try ledger.rows.map(SiriListedTransactionEntity.init(row:))
        let snippet = SiriExpenseResultsSnippetIntent(sheetIdentifier: sheetID, filter: filter, kind: selection,
                                                     memberIdentifier: member?.id)
        #if os(iOS) && DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT
        SiriCompactExperimentDiagnostics.record(.searchFinished)
        #endif
        return .result(value: entities, dialog: IntentDialog("\(reply)"), snippetIntent: snippet)
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriListMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriListTransactionsIntent>(\.$sheet) var list

    @MainActor func selectedSheetID(access: IntentSheetAccess) throws -> String? { list?.sheet.id }

    @MainActor func suggestedEntities() async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriSheetMemberRoster.searchCandidates(access: access, sheetID: selectedSheetID(access: access))
    }
}
#endif

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
#if os(macOS) || (os(iOS) && !(DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT))
@AppIntent(.tool)
#endif
struct SiriFindExpenseCardsIntent: AppIntent {
    #if os(iOS) && DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT
    static let isDiscoverable = false
    #endif
    static let title: LocalizedStringResource = "シートの収入・支出を検索して表示"
    static let description = IntentDescription("「家計シートの支出を調べて」「今月の支出には何がある？」「収支は？」など、シートの収入・支出・差額や明細を質問されたらこのカードを表示します。期間、店名、カテゴリ、メンバーで絞れます。本文には直近3件と残り件数を使い、全件を明示した場合だけすべて伝えます。", searchKeywords: ["収支", "支出", "収入", "明細", "カテゴリ"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "指定されたシート。省略時は最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバー", description: "支払った人・受け取った人が指定された場合のみ。", optionsProvider: SiriCardMemberQuery())
    var member: SiriSheetMemberEntity?
    @Parameter(title: "支出名・カテゴリ名", description: "店名や支出名の検索語。カテゴリだけを尋ねられた場合や全件表示では省略します。")
    var expenseName: String?
    @Parameter(title: "カテゴリ名", description: "「今月の食費」なら「食費」。指定されたカテゴリに絞り、店名や日付の条件があれば併用します。")
    var categoryName: String?
    @Parameter(title: "対象の収支", description: "「支出を調べて」は支出、「収入を調べて」は収入。「収支」や「何がある？」など明細全般なら両方です。")
    var kind: SiriTransactionSelection?
    @Parameter(title: "対象月", description: "2026年5月など年月だけが指定されたときの月。「今日」や日付を含む質問は対象月に設定しません。")
    var month: Date?
    @Parameter(title: "対象日", description: "11月11日など、特定の1日について尋ねられたときの日付。")
    var day: Date?
    @Parameter(title: "検索期間", description: "「今日の支出は？」は今日、「昨日」は昨日、「今月」は今月、「先月」は先月。期間指定がない一覧は今月、店名だけの検索は全期間を対象にします。")
    var period: SiriExpensePeriod?

    @Parameter(title: "本文に全件を表示", description: "明細を全部・全件・すべて表示するよう明示された場合のみ有効にします。「全期間」は検索期間の指定です。")
    var showAllInReply: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriExpenseCardResult> & ProvidesDialog & ShowsSnippetIntent {
        #if os(watchOS)
        let defaultKind: SiriTransactionSelection = .expense
        let isSpokenQuery = member == nil && expenseName == nil && categoryName == nil && kind == nil && month == nil && day == nil && period == nil && showAllInReply != true
        let search = isSpokenQuery
            ? try await $expenseName.requestValue("何を検索しますか？「今日の収支」「今月の食費」やお店の名前をどうぞ。")
            : expenseName
        #else
        let defaultKind: SiriTransactionSelection = .both
        let isSpokenQuery = false
        let search = expenseName
        #endif
        let request = SiriTransactionReplyRequest(search)
        let filter = SiriExpenseSearchFilter(expenseName: request.search, categoryName: categoryName, month: month, day: day,
                                            period: period, isSpokenQuery: isSpokenQuery || request.requestsAll)
        let selection = filter.spokenKind ?? kind ?? defaultKind
        let result = try await SiriExpenseLookup.run(sheet: sheet, member: member, filter: filter, kind: selection, showAll: showAllInReply ?? request.requestsAll) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの明細を検索しますか？")
        }
        let snippet = SiriExpenseResultsSnippetIntent(sheetIdentifier: result.sheetID, filter: filter, kind: selection, memberIdentifier: member?.id)
        #if os(iOS) && DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT
        SiriCompactExperimentDiagnostics.record(.singleCardResult)
        #endif
        return .result(value: result.card, dialog: IntentDialog("\(result.report)"),
                       snippetIntent: snippet)
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriCardMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriFindExpenseCardsIntent>(\.$sheet) var search

    func selectedSheetID(access: IntentSheetAccess) throws -> String? { search?.sheet.id }

    @MainActor func suggestedEntities() async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriSheetMemberRoster.searchCandidates(access: access, sheetID: selectedSheetID(access: access))
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseResultsSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "支出明細のカードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シートの識別子") var sheetIdentifier: String
    @Parameter(title: "メンバーの識別子") var memberIdentifier: String?
    @Parameter(title: "支出名・カテゴリ名") var expenseName: String?
    @Parameter(title: "カテゴリ名") var categoryName: String?
    @Parameter(title: "対象の収支") var kind: SiriTransactionSelection?
    // Retained to decode snippets created before daily searches were supported.
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "期間の開始") var intervalStart: Date?
    @Parameter(title: "期間の終了") var intervalEnd: Date?
    @Parameter(title: "対象期間") var periodLabel: String?

    init() {}

    init(sheetIdentifier: String, filter: SiriExpenseSearchFilter, kind: SiriTransactionSelection = .expense,
         memberIdentifier: String? = nil) {
        self.kind = kind
        self.sheetIdentifier = sheetIdentifier
        self.memberIdentifier = memberIdentifier
        self.expenseName = filter.name
        self.categoryName = filter.categoryName
        self.intervalStart = filter.scope.interval?.start
        self.intervalEnd = filter.scope.interval?.end
        self.periodLabel = filter.scope.label
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        #if os(iOS) && DEBUG && BUDGETY_SIRI_COMPACT_EXPERIMENT
        SiriCompactExperimentDiagnostics.record(.snippetRequested)
        #endif
        let interval: DateInterval?
        let label: String
        switch (intervalStart, intervalEnd, periodLabel) {
        case let (start?, end?, savedLabel?) where start <= end:
            interval = DateInterval(start: start, end: end)
            label = savedLabel
        case (nil, nil, let savedLabel?):
            interval = nil
            label = savedLabel
        case (nil, nil, nil):
            let legacy = SiriExpenseSearchFilter(expenseName: nil, month: month, period: nil, unnamedPeriod: .allTime)
            interval = legacy.scope.interval
            label = legacy.scope.label
        default:
            throw AppIntentError.expenseUnavailable
        }
        let result = try SiriExpenseLookup.search(sheetID: sheetIdentifier, expenseName: expenseName, categoryName: categoryName,
                                                 interval: interval, periodLabel: label, kind: kind ?? .expense,
                                                 memberIdentifier: memberIdentifier)
        return .result(view: SiriExpenseCardView(result: result.card))
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriOpenExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "明細を開く"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "明細の識別子") var expenseIdentifier: String

    init() {}

    init(expenseIdentifier: String) {
        self.expenseIdentifier = expenseIdentifier
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        try WatchSiriNavigation.shared.requestOpenExpense(identifier: expenseIdentifier)
        #elseif os(macOS)
        try MacSiriNavigation.shared.requestOpenExpense(identifier: expenseIdentifier)
        #else
        try DeepLinkRouter.shared.requestOpenExpense(identifier: expenseIdentifier)
        #endif
        return .result()
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
enum SiriExpenseLookup {
    struct Result {
        let sheetID: String
        let report: String
        let card: SiriExpenseCardResult
    }

    @MainActor
    static func run(sheet: ExpenseSheetEntity?, member: SiriSheetMemberEntity? = nil, filter: SiriExpenseSearchFilter, kind: SiriTransactionSelection = .expense, showAll: Bool,
                    choosing: ([ExpenseSheetEntity]) async throws -> ExpenseSheetEntity) async throws -> Result {
        let sheetID = try await sheetIdentifier(sheet: sheet, member: member, choosing: choosing)
        return try search(sheetID: sheetID, expenseName: filter.name, categoryName: filter.categoryName, interval: filter.scope.interval, periodLabel: filter.scope.label, kind: kind, showAll: showAll, memberIdentifier: member?.id)
    }

    @MainActor
    static func sheetIdentifier(sheet: ExpenseSheetEntity?, member: SiriSheetMemberEntity? = nil,
                               choosing: ([ExpenseSheetEntity]) async throws -> ExpenseSheetEntity) async throws -> String {
        if let member {
            guard let separator = member.id.firstIndex(of: "#") else { throw AppIntentError.missingPayer }
            let sheetID = String(member.id[..<separator])
            guard sheet == nil || sheet?.id == sheetID else { throw AppIntentError.sheetNotFound }
            return sheetID
        }
        if let sheet {
            return sheet.id
        } else if let lastID = IntentSheetAccess.lastOpenedSheetURI, !lastID.isEmpty {
            return lastID
        }
        let viewContext = PersistenceController.shared.container.viewContext
        let candidates = try IntentSheetAccess(checking: viewContext).sheets().map(ExpenseSheetEntity.from)
        guard let first = candidates.first else { throw AppIntentError.sheetNotFound }
        if candidates.count == 1 { return first.id }
        return try await choosing(candidates).id
    }

    @MainActor
    static func search(sheetID: String, expenseName: String?, categoryName: String? = nil, interval: DateInterval?, periodLabel period: String,
                       kind: SiriTransactionSelection = .expense, showAll: Bool = false,
                       memberIdentifier: String? = nil) throws -> Result {
        // Recheck stored access when Siri rebuilds the snippet as well as at initial lookup.
        let viewContext = PersistenceController.shared.container.viewContext
        let access = try IntentSheetAccess(checking: viewContext)
        let record = try access.resolve(sheetID)
        let name = (expenseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category = (categoryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let person = try memberIdentifier.map { identifier in
            let roster = try SiriSheetMemberRoster(sheet: record, access: access)
            guard let member = roster.members.first(where: { $0.id == identifier }) else { throw AppIntentError.missingPayer }
            return (name: member.name, payer: SiriMemberTransactionLookup.Payer(member: member, roster: roster, sheet: record))
        }
        let ledger = try SiriTransactionLedger.read(sheet: record, access: access, interval: interval,
                                                    includeExpenses: kind.includesExpenses, includeIncome: kind.includesIncome,
                                                    expenseName: name, categoryName: category, allRows: showAll,
                                                    matchesPayer: { person?.payer.matches($0) ?? true })
        let report = ledger.reply(for: kind, sheetName: record.displayName, period: period, member: person?.name,
                                  category: category.isEmpty ? nil : category, name: name.isEmpty ? nil : name, showAll: showAll)
        let amounts: String
        switch kind {
        case .expense: amounts = ledger.expenseTotal
        case .income: amounts = ledger.incomeTotal
        case .both: amounts = String(localized: "収支 \(ledger.netTotal)")
        }
        var card = SiriExpenseCardResult(sheetName: record.displayName, period: period, expenseName: name.isEmpty ? category : name,
                                         count: ledger.count, total: amounts, rows: ledger.rows,
                                         sheetSymbol: record.displaySymbol, sheetColorHex: record.displayColorHex)
        if kind == .both {
            card.incomeTotal = ledger.incomeTotal
            card.expenseTotal = ledger.expenseTotal
        }
        return Result(sheetID: sheetID, report: report, card: card)
    }

    @MainActor
    static func dueExpenses(in sheet: ExpenseSheet, interval: DateInterval?) -> [RecurringOccurrence] {
        let range = interval.map { $0.start...$0.end }
        // The ledger excludes materialized, skipped and future slots. Its range includes both ends.
        return RecurringOccurrenceService.virtualOccurrences(for: sheet, in: range, includeFuture: false).filter { occurrence in
            occurrence.kind == .expense && (interval.map { occurrence.date < $0.end } ?? true)
        }
    }
}
#endif

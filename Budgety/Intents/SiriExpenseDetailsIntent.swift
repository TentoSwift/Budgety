#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "支出名で明細を確認"
    static let description = IntentDescription("指定したシートの支出を支出名、カテゴリ名、日付、月で探し、件数、通貨別の合計と最新5件までの明細をテキストで返します。")
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

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Existing personal shortcuts consume this action's text output.
        let filter = SiriExpenseSearchFilter(expenseName: expenseName, categoryName: categoryName, month: month, day: day, period: period, unnamedPeriod: .allTime)
        let result = try await SiriExpenseLookup.run(sheet: sheet, filter: filter) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートで支出を検索しますか？")
        }
        return .result(value: result.report, dialog: IntentDialog("\(result.report)"))
    }
}

#if os(iOS) || os(macOS)
@available(iOS 27.3, macOS 27.3, *)
@AppIntent(.tool)
struct SiriListTransactionsIntent: AppIntent {
    static let title: LocalizedStringResource = "シートの収支と明細を調べる"
    static let description = IntentDescription("「収支は？」「今月の収支は？」「収入と支出を見せて」では収入・支出・差額を通貨ごとに答え、両方の明細をすべて新しい順で返します。「それなら先月は？」では対象期間を切り替えます。支出のみ、収入のみ、日付、店名、カテゴリ、メンバーを指定した検索にも使えます。", searchKeywords: ["収支", "収入と支出", "差額", "明細一覧", "全件", "取引一覧"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = .background

    @Parameter(title: "シート", description: "指定されたシート。省略時は指定したメンバーのシート、または最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバー", description: "支払った人や受け取った人で絞る場合に指定します。", optionsProvider: SiriListMemberQuery())
    var member: SiriSheetMemberEntity?
    @Parameter(title: "支出名・収入名", description: "お店の名前や明細名の検索語。全件を一覧にするときは省略します。")
    var expenseName: String?
    @Parameter(title: "カテゴリ名") var categoryName: String?
    @Parameter(title: "対象の収支", description: "「収支」や明細全般は両方です。「支出だけ」「収入だけ」の指定があれば対応する種別を選びます。")
    var kind: SiriTransactionSelection?
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "検索期間", description: "今日・昨日・今月・先月・全期間。")
    var period: SiriExpensePeriod?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SiriListedTransactionEntity]> & ProvidesDialog {
        let sheetID: String
        if let member {
            guard let separator = member.id.firstIndex(of: "#") else { throw AppIntentError.missingPayer }
            sheetID = String(member.id[..<separator])
            guard sheet == nil || sheet?.id == sheetID else { throw AppIntentError.sheetNotFound }
        } else {
            sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
                try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの明細を一覧にしますか？")
            }
        }
        let filter = SiriExpenseSearchFilter(expenseName: expenseName, categoryName: categoryName, month: month, day: day, period: period)
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
        let summary = ledger.summary(for: selection, sheetName: selected.displayName, period: filter.scope.label,
                                     member: member?.name, category: filter.categoryName, name: filter.name)
        return .result(value: try ledger.rows.map(SiriListedTransactionEntity.init(row:)), dialog: IntentDialog("\(summary)"))
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
struct SiriFindExpenseCardsIntent: AppIntent {
    // Existing shortcuts keep the original output type. New spoken ledger queries use the entity list.
    #if os(iOS) || os(macOS)
    static let isDiscoverable = false
    #endif
    static let title: LocalizedStringResource = "シートの収入・支出を検索して表示"
    static let description = IntentDescription("シート全体の支出、収入、または両方を日付・月・カテゴリ・店名で検索します。「今月の収支は？」「収入と支出を見せて」では両方を指定し、同じカードに表示します。「今日の支出」は今日1日、「今月の食費」は今月の食費です。", searchKeywords: ["収支", "支出", "収入", "カテゴリ"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "指定されたシート。省略時は最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "支出名・カテゴリ名", description: "店名や支出名の検索語。カテゴリだけを尋ねられた場合や全件表示では省略します。")
    var expenseName: String?
    @Parameter(title: "カテゴリ名", description: "「今月の食費」なら「食費」。指定されたカテゴリに絞り、店名や日付の条件があれば併用します。")
    var categoryName: String?
    @Parameter(title: "対象の収支", description: "支出・収入・両方から選びます。「収支」や「収入と支出」は両方。省略時は支出です。")
    var kind: SiriTransactionSelection?
    @Parameter(title: "対象月", description: "2026年5月など年月だけが指定されたときの月。「今日」や日付を含む質問は対象月に設定しません。")
    var month: Date?
    @Parameter(title: "対象日", description: "11月11日など、特定の1日について尋ねられたときの日付。")
    var day: Date?
    @Parameter(title: "検索期間", description: "「今日の支出は？」は今日、「昨日」は昨日、「今月」は今月、「先月」は先月。期間指定がない一覧は今月、店名だけの検索は全期間を対象にします。")
    var period: SiriExpensePeriod?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriExpenseCardResult> & ProvidesDialog & ShowsSnippetIntent {
        #if os(watchOS)
        let isSpokenQuery = expenseName == nil && categoryName == nil && kind == nil && month == nil && day == nil && period == nil
        let search = isSpokenQuery
            ? try await $expenseName.requestValue("何を検索しますか？「今日の収支」「今月の食費」やお店の名前をどうぞ。")
            : expenseName
        #else
        let isSpokenQuery = false
        let search = expenseName
        #endif
        let filter = SiriExpenseSearchFilter(expenseName: search, categoryName: categoryName, month: month, day: day,
                                            period: period, isSpokenQuery: isSpokenQuery)
        let selection = kind ?? filter.spokenKind ?? .expense
        let result = try await SiriExpenseLookup.run(sheet: sheet, filter: filter, kind: selection) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの明細を検索しますか？")
        }
        let supporting: LocalizedStringResource = result.card.count == 0
            ? "該当する明細はありません" : "明細が見つかりました。"
        let snippet = SiriExpenseResultsSnippetIntent(sheetIdentifier: result.sheetID, filter: filter, kind: selection)
        return .result(value: result.card, dialog: IntentDialog(full: "\(result.summary)", supporting: supporting),
                       snippetIntent: snippet)
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseResultsSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "支出明細のカードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シートの識別子") var sheetIdentifier: String
    @Parameter(title: "支出名・カテゴリ名") var expenseName: String?
    @Parameter(title: "カテゴリ名") var categoryName: String?
    @Parameter(title: "対象の収支") var kind: SiriTransactionSelection?
    // Retained to decode snippets created before daily searches were supported.
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "期間の開始") var intervalStart: Date?
    @Parameter(title: "期間の終了") var intervalEnd: Date?
    @Parameter(title: "対象期間") var periodLabel: String?

    init() {}

    init(sheetIdentifier: String, filter: SiriExpenseSearchFilter, kind: SiriTransactionSelection = .expense) {
        self.kind = kind
        self.sheetIdentifier = sheetIdentifier
        self.expenseName = filter.name
        self.categoryName = filter.categoryName
        self.intervalStart = filter.scope.interval?.start
        self.intervalEnd = filter.scope.interval?.end
        self.periodLabel = filter.scope.label
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
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
        let result = try SiriExpenseLookup.search(sheetID: sheetIdentifier, expenseName: expenseName, categoryName: categoryName, interval: interval, periodLabel: label, kind: kind ?? .expense)
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
        let summary: String
        let card: SiriExpenseCardResult
    }

    @MainActor
    static func run(sheet: ExpenseSheetEntity?, filter: SiriExpenseSearchFilter, kind: SiriTransactionSelection = .expense,
                    choosing: ([ExpenseSheetEntity]) async throws -> ExpenseSheetEntity) async throws -> Result {
        let sheetID = try await sheetIdentifier(sheet: sheet, choosing: choosing)
        return try search(sheetID: sheetID, expenseName: filter.name, categoryName: filter.categoryName, interval: filter.scope.interval, periodLabel: filter.scope.label, kind: kind)
    }

    @MainActor
    static func sheetIdentifier(sheet: ExpenseSheetEntity?,
                               choosing: ([ExpenseSheetEntity]) async throws -> ExpenseSheetEntity) async throws -> String {
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
                       kind: SiriTransactionSelection = .expense) throws -> Result {
        // Recheck stored access when Siri rebuilds the snippet as well as at initial lookup.
        let viewContext = PersistenceController.shared.container.viewContext
        let access = try IntentSheetAccess(checking: viewContext)
        let record = try access.resolve(sheetID)
        let name = (expenseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category = (categoryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ledger = try SiriTransactionLedger.read(sheet: record, access: access, interval: interval,
                                                    includeExpenses: kind.includesExpenses, includeIncome: kind.includesIncome,
                                                    expenseName: name, categoryName: category)
        let rows = ledger.rows
        let count = ledger.count
        let periodScope = category.isEmpty ? period : String(localized: "\(period)のカテゴリ「\(category)」")
        let scope: String
        let amounts: String
        switch kind {
        case .expense:
            scope = name.isEmpty ? String(localized: "「\(record.displayName)」の\(periodScope)の支出")
                : String(localized: "「\(record.displayName)」の\(periodScope)で支出名またはカテゴリ名に「\(name)」を含む明細")
            amounts = ledger.expenseTotal
        case .income, .both:
            let title = kind == .income ? String(localized: "収入") : String(localized: "収支")
            scope = [record.displayName, periodScope, title, name].filter { !$0.isEmpty }.joined(separator: " · ")
            amounts = kind == .income ? ledger.incomeTotal : String(localized: "収支 \(ledger.netTotal)")
        }
        let summary: String
        var report: String
        if count == 0 {
            summary = String(localized: "\(scope)は見つかりませんでした。")
            report = summary
        } else {
            summary = String(localized: "\(scope)は\(amounts)です。")
            report = String(localized: "\(scope)は\(count)件、合計は\(amounts)です。")
        }
        if count > rows.count {
            report += "\n" + String(localized: "新しい順に\(rows.count)件を表示します。")
        }
        for row in rows {
            let label = row.title == row.category ? row.title : String(localized: "\(row.title)（\(row.category)）")
            report += "\n" + String(localized: "\(row.date)　\(label)　\(row.amount)")
        }
        var card = SiriExpenseCardResult(sheetName: record.displayName, period: period, expenseName: name.isEmpty ? category : name,
                                         count: count, total: amounts, rows: rows,
                                         sheetSymbol: record.displaySymbol, sheetColorHex: record.displayColorHex)
        if kind == .both {
            card.incomeTotal = ledger.incomeTotal
            card.expenseTotal = ledger.expenseTotal
        }
        return Result(sheetID: sheetID, report: report, summary: summary, card: card)
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

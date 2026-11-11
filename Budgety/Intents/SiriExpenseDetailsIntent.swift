#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, *)
struct SiriExpenseDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "支出名で明細を確認"
    static let description = IntentDescription("指定したシートの支出を名前、日付、月で探し、件数、通貨別の合計と最新5件までの明細をテキストで返します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "シート名を指定された場合だけ設定します。省略時は最後に開いたシートを使い、特定できなければ選択を求めます。")
    var sheet: ExpenseSheetEntity?

    @Parameter(title: "支出名", description: "「ランチ」や店名など、支出の名前に含まれる言葉。省略するとすべての支出名が対象になります。")
    var expenseName: String?

    @Parameter(title: "対象月", description: "年月だけが指定されたときの月。「今日」や特定の日付は対象月に設定しません。")
    var month: Date?
    @Parameter(title: "対象日", description: "11月11日など、特定の1日について尋ねられたときの日付。")
    var day: Date?
    @Parameter(title: "検索期間", description: "今日・昨日・今月・先月・全期間。期間を省略すると全期間を検索します。")
    var period: SiriExpensePeriod?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Existing personal shortcuts consume this action's text output.
        let filter = SiriExpenseSearchFilter(expenseName: expenseName, month: month, day: day, period: period, unnamedPeriod: .allTime)
        let result = try await SiriExpenseLookup.run(sheet: sheet, filter: filter) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートで支出を検索しますか？")
        }
        return .result(value: result.report, dialog: IntentDialog("\(result.report)"))
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriFindExpenseCardsIntent: AppIntent {
    static let title: LocalizedStringResource = "支出明細を検索してカードで表示"
    static let description = IntentDescription("「今日の支出は？」なら今日1日だけ、「今月の支出は？」なら今月の支出を、明細カードと通貨別の金額で返します。日付と店名を組み合わせて検索することもできます。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "指定されたシート。省略時は最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "支出名", description: "「ランチ」や店名など、支出名に含まれる言葉。「今日の支出は？」など一覧を求められたら省略します。")
    var expenseName: String?
    @Parameter(title: "対象月", description: "2026年5月など年月だけが指定されたときの月。「今日」や日付を含む質問は対象月に設定しません。")
    var month: Date?
    @Parameter(title: "対象日", description: "11月11日など、特定の1日について尋ねられたときの日付。")
    var day: Date?
    @Parameter(title: "検索期間", description: "「今日の支出は？」は今日、「昨日」は昨日、「今月」は今月、「先月」は先月。期間指定がない一覧は今月、店名だけの検索は全期間を対象にします。")
    var period: SiriExpensePeriod?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriExpenseCardResult> & ProvidesDialog & ShowsSnippetIntent {
        let filter = SiriExpenseSearchFilter(expenseName: expenseName, month: month, day: day, period: period)
        let result = try await SiriExpenseLookup.run(sheet: sheet, filter: filter) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートで支出を検索しますか？")
        }
        let supporting: LocalizedStringResource = result.card.count == 0
            ? "該当する支出はありません" : "支出が見つかりました。"
        let snippet = SiriExpenseResultsSnippetIntent(sheetIdentifier: result.sheetID, filter: filter)
        return .result(value: result.card, dialog: IntentDialog(full: "\(result.summary)", supporting: supporting),
                       snippetIntent: snippet)
    }
}

@available(iOS 27.3, *)
struct SiriExpenseResultsSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "支出明細のカードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シートの識別子") var sheetIdentifier: String
    @Parameter(title: "支出名") var expenseName: String?
    // Retained to decode snippets created before daily searches were supported.
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "期間の開始") var intervalStart: Date?
    @Parameter(title: "期間の終了") var intervalEnd: Date?
    @Parameter(title: "対象期間") var periodLabel: String?

    init() {}

    init(sheetIdentifier: String, filter: SiriExpenseSearchFilter) {
        self.sheetIdentifier = sheetIdentifier
        self.expenseName = filter.name
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
        let result = try SiriExpenseLookup.search(sheetID: sheetIdentifier, expenseName: expenseName, interval: interval, periodLabel: label)
        return .result(view: SiriExpenseCardView(result: result.card))
    }
}

@available(iOS 27.3, *)
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
        try DeepLinkRouter.shared.requestOpenExpense(identifier: expenseIdentifier)
        return .result()
    }
}

@available(iOS 27.3, *)
enum SiriExpenseLookup {
    struct Result {
        let sheetID: String
        let report: String
        let summary: String
        let card: SiriExpenseCardResult
    }

    @MainActor
    static func run(sheet: ExpenseSheetEntity?, filter: SiriExpenseSearchFilter,
                    choosing: ([ExpenseSheetEntity]) async throws -> ExpenseSheetEntity) async throws -> Result {
        let sheetID = try await sheetIdentifier(sheet: sheet, choosing: choosing)
        return try search(sheetID: sheetID, expenseName: filter.name, interval: filter.scope.interval, periodLabel: filter.scope.label)
    }

    @MainActor
    static func sheetIdentifier(sheet: ExpenseSheetEntity?,
                               choosing: ([ExpenseSheetEntity]) async throws -> ExpenseSheetEntity) async throws -> String {
        if let sheet {
            return sheet.id
        } else if let lastID = UserDefaults.standard.string(forKey: "lastOpenedSheetURI"), !lastID.isEmpty {
            return lastID
        }
        let viewContext = PersistenceController.shared.container.viewContext
        let candidates = try IntentSheetAccess(checking: viewContext).sheets().map(ExpenseSheetEntity.from)
        guard let first = candidates.first else { throw AppIntentError.sheetNotFound }
        if candidates.count == 1 { return first.id }
        return try await choosing(candidates).id
    }

    @MainActor
    static func search(sheetID: String, expenseName: String?, interval: DateInterval?, periodLabel period: String) throws -> Result {
        // Recheck stored access when Siri rebuilds the snippet as well as at initial lookup.
        let viewContext = PersistenceController.shared.container.viewContext
        let access = try IntentSheetAccess(checking: viewContext)
        let record = try access.resolve(sheetID)
        let request = NSFetchRequest<Expense>(entityName: "Expense")
        var filters = [NSPredicate(format: "sheet == %@", record)]
        if let interval {
            filters.append(NSPredicate(format: "date >= %@ AND date < %@", interval.start as NSDate, interval.end as NSDate))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: filters)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Expense.date, ascending: false),
                                   NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)]
        request.fetchBatchSize = 64

        let name = (expenseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query = Self.searchKey(name)
        var count = 0
        var totals: [String: Decimal] = [:]
        var rows: [SiriExpenseCardRow] = []
        lazy var isSoloSheet = !record.hasAcceptedOtherMembers()
        for expense in try access.context.fetch(request) where expense.kind == .expense && !expense.isSkipped {
            let title = expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle
            guard query.isEmpty || Self.searchKey(title).contains(query) else { continue }
            count += 1
            let currency = expense.resolvedCurrencyCode.uppercased()
            totals[currency, default: 0] += expense.amountDecimal
            if rows.count < 5 {
                rows.append(.from(expense, in: record, isSoloSheet: isSoloSheet))
            }
        }

        let scope = name.isEmpty ? String(localized: "「\(record.displayName)」の\(period)の支出")
            : String(localized: "「\(record.displayName)」の\(period)で支出名に「\(name)」を含む明細")
        let summary: String
        let amounts = totals.sorted { $0.key < $1.key }.map { currency, total in
            total.formatted(.currency(code: currency).presentation(.isoCode))
        }.formatted(.list(type: .and))
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
        let card = SiriExpenseCardResult(sheetName: record.displayName, period: period, expenseName: name,
                                         count: count, total: amounts, rows: rows,
                                         sheetSymbol: record.displaySymbol, sheetColorHex: record.displayColorHex)
        return Result(sheetID: sheetID, report: report, summary: summary, card: card)
    }

    private static func searchKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}
#endif

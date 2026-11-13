#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
enum SiriTransactionSelection: String, AppEnum, Codable {
    case expense, income, both

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "対象の収支"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .expense: "支出", .income: "収入",
        .both: DisplayRepresentation(title: "収入と支出", synonyms: ["収支"])
    ]

    var includesExpenses: Bool { self != .income }
    var includesIncome: Bool { self != .expense }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriFindMemberTransactionsIntent: AppIntent {
    static let title: LocalizedStringResource = "人別に収入と支出を検索"
    static let description = IntentDescription("「はるさんの今月の支出は？」「私の収入は？」「はるさんの収入と支出を見せて」のように、家計簿のメンバー別に明細を検索し、写真と名前の付いたカードで返します。支出は支払った人、収入は受け取った人で検索します。", searchKeywords: ["メンバー", "収支", "支出", "収入"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "発話で指定されたシート。省略時は選んだメンバーのシートを使います。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバー", description: "指定した人。自分、共有メンバー、バーチャルメンバーから名前で選びます。", optionsProvider: SiriMemberSearchQuery())
    var member: SiriSheetMemberEntity
    @Parameter(title: "対象の収支", description: "支払った金額は支出、受け取った金額は収入。「収支」「収入と支出」や種別の指定がない質問は両方です。")
    var kind: SiriTransactionSelection?
    @Parameter(title: "検索期間", description: "今日・昨日・今月・先月・全期間。省略時は今月です。")
    var period: SiriExpensePeriod?
    @Parameter(title: "対象月", description: "特定の年月を指定したときの月。")
    var month: Date?
    @Parameter(title: "対象日", description: "特定の1日を指定したときの日付。")
    var day: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriMemberCardResult> & ProvidesDialog & ShowsSnippetIntent {
        let selection = kind ?? .both
        let scope = SiriExpenseSearchFilter(expenseName: nil, month: month, day: day, period: period).scope
        guard let separator = member.id.firstIndex(of: "#") else { throw AppIntentError.sheetNotFound }
        let sheetID = String(member.id[..<separator])
        guard sheet == nil || sheet?.id == sheetID else { throw AppIntentError.sheetNotFound }
        let result = try SiriMemberTransactionLookup.search(sheetID: sheetID, memberIdentifier: member.id,
                                                           scope: scope, includeExpenses: selection.includesExpenses,
                                                           includeIncome: selection.includesIncome)
        return .result(value: result.card, dialog: IntentDialog("\(result.summary)"),
                       snippetIntent: SiriMemberResultsSnippetIntent(sheetID: sheetID, memberID: member.id,
                                                                    kind: selection, scope: scope))
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriMemberResultsSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "メンバーの収支カードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シートの識別子") var sheetID: String
    @Parameter(title: "メンバーの識別子") var memberID: String
    @Parameter(title: "対象の収支") var kind: SiriTransactionSelection
    @Parameter(title: "対象期間") var periodLabel: String
    @Parameter(title: "期間の開始") var start: Date?
    @Parameter(title: "期間の終了") var end: Date?

    init() {}

    init(sheetID: String, memberID: String, kind: SiriTransactionSelection, scope: SiriExpenseScope) {
        self.sheetID = sheetID
        self.memberID = memberID
        self.kind = kind
        periodLabel = scope.label
        start = scope.interval?.start
        end = scope.interval?.end
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let interval: DateInterval?
        switch (start, end) {
        case let (start?, end?) where start.compare(end) != .orderedDescending:
            interval = DateInterval(start: start, end: end)
        case (nil, nil):
            interval = nil
        default:
            throw AppIntentError.expenseUnavailable
        }
        let scope = SiriExpenseScope(interval: interval, label: periodLabel, isDay: false)
        let result = try SiriMemberTransactionLookup.search(sheetID: sheetID, memberIdentifier: memberID,
                                                           scope: scope, includeExpenses: kind.includesExpenses,
                                                           includeIncome: kind.includesIncome)
        return .result(view: SiriExpenseCardView(member: result.card))
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriMemberSearchQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriFindMemberTransactionsIntent>(\.$sheet) var search

    @MainActor
    func selectedSheetID(access: IntentSheetAccess) throws -> String? {
        search?.sheet.id
    }

    @MainActor
    func suggestedEntities() async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriSheetMemberRoster.searchCandidates(access: access, sheetID: selectedSheetID(access: access))
    }
}
#endif

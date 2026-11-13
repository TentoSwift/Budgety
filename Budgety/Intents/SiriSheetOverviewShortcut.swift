#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation

/// A bound kind routes to the sheet; the legacy member phrases request a member.
/// This shortcut stays separate from the natural-language tools.
@available(iOS 27.3, *)
struct SiriSheetOverviewShortcut: AppIntent {
    static let title: LocalizedStringResource = "シート・メンバーの収支を確認"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "対象の収支") var kind: SiriTransactionSelection?
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバー", optionsProvider: SiriOverviewMemberQuery()) var member: SiriSheetMemberEntity?

    @Parameter(title: "検索期間") var period: SiriExpensePeriod?
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "本文に全件を表示") var showAllInReply: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        if let kind, member == nil {
            let filter = SiriExpenseSearchFilter(expenseName: nil, month: month, day: day, period: period)
            let result = try await SiriExpenseLookup.run(sheet: sheet, filter: filter, kind: kind, showAll: showAllInReply == true) {
                try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの明細を検索しますか？")
            }
            return .result(dialog: IntentDialog("\(result.report)"),
                           snippetIntent: SiriExpenseResultsSnippetIntent(sheetIdentifier: result.sheetID, filter: filter, kind: kind))
        }

        let selectedMember: SiriSheetMemberEntity
        if let member { selectedMember = member }
        else {
            let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
            let candidates = try SiriSheetMemberRoster.searchCandidates(access: access, sheetID: sheet?.id)
            guard !candidates.isEmpty else { throw AppIntentError.sheetNotFound }
            if candidates.count == 1 {
                selectedMember = candidates[0]
            } else {
                selectedMember = try await $member.requestDisambiguation(among: candidates, dialog: "どのメンバーの収支を調べますか？")
            }
        }
        var lookup = SiriFindMemberTransactionsIntent()
        lookup.sheet = sheet
        lookup.member = selectedMember
        lookup.kind = kind
        lookup.period = period
        lookup.month = month
        lookup.day = day
        lookup.showAllInReply = showAllInReply
        let result = try lookup.search()
        return .result(dialog: IntentDialog("\(result.lookup.summary)"), snippetIntent: result.snippet)
    }
}

@available(iOS 27.3, *)
struct SiriOverviewMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriSheetOverviewShortcut>(\.$sheet) var overview

    @MainActor
    func selectedSheetID(access: IntentSheetAccess) throws -> String? { overview?.sheet.id }
}
#endif

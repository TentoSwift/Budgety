#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriMemberAdvancesIntent: AppIntent {
    static let title: LocalizedStringResource = "メンバーの立て替え総額を確認"
    static let description = IntentDescription("「旅行で私が立て替えた分はいくら？」に、支払った割り勘支出のうち他の人の負担分の累計を返します。自分の負担分と精算の送金は含めません。既に返金された分も含む元の立て替え総額で、現在の受取残額とは別です。現在の支払先と支払額は精算状況で確認します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバー", description: "省略すると自分。", optionsProvider: SiriRecordingMemberQuery()) var member: SiriSheetMemberEntity?
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "検索期間", description: "省略すると全期間。") var period: SiriExpensePeriod?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetIntent {
        let result = try await report()
        return .result(value: result.text, dialog: IntentDialog("\(result.text)"), snippetIntent: SiriReadReportSnippetIntent(advances: self, sheetID: result.sheetID))
    }

    @MainActor
    func report() async throws -> (sheetID: String, text: String) {
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet, member: member) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの立て替えを確認しますか？")
        }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let record = try access.resolve(sheetID)
        let roster = try SiriSheetMemberRoster(sheet: record, access: access)
        let selected: SiriSheetMemberEntity
        if let member {
            guard let current = roster.members.first(where: { $0.id == member.id }) else { throw AppIntentError.missingPayer }
            selected = current
        } else {
            guard let current = roster.members.first(where: \.isSelf) else { throw AppIntentError.missingPayer }
            selected = current
        }
        let scope = SiriExpenseSearchFilter(expenseName: nil, month: month, day: day, period: period, unnamedPeriod: .allTime).scope
        // Calculator ranges include both endpoints; Siri periods exclude the next midnight.
        let range = scope.interval.map { $0.start...Date(timeIntervalSinceReferenceDate: $0.end.timeIntervalSinceReferenceDate.nextDown) }
        let result = SettlementCalculator.calculate(for: record, in: range)
        let ids = selected.isSelf ? roster.selfProfileIDs.union([selected.profileID]) : [selected.profileID]
        let amount = result.originalAdvances.filter { ids.contains($0.key) }.values.reduce(Decimal.zero, +)
        var report = "「\(record.displayName)」\(scope.label)に\(selected.name)が他の人のために立て替えた総額は\(CurrencyCatalog.format(amount, code: result.currencyCode))です。自分の負担分と精算送金を除いた、返金前の累計です。今日までの未確定の定期支出もアプリの精算計算と同じく含みます。"
        if !result.missingRateCurrencies.isEmpty {
            report += " 為替レートがない通貨（\(result.missingRateCurrencies.sorted().joined(separator: ", "))）は除外しています。"
        }
        let response = report
        return (sheetID, response)
    }
}
#endif

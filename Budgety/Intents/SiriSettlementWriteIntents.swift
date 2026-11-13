#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import Foundation
import SwiftUI

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriSettleSuggestedTransferIntent: AppIntent {
    static let title: LocalizedStringResource = "送金の提案を精算済みにする"
    static let description = IntentDescription("「精算済みにして」「この送金を精算済みにして」と頼まれたら、現在の精算プランから送金を選び、内容を確認して記録します。", searchKeywords: ["精算", "送金"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", optionsProvider: SiriSettlementWritableSheetQuery()) var sheet: ExpenseSheetEntity?
    @Parameter(title: "送金の提案", description: "精算済みにする送金。直前の精算プランの提案を指定できます。")
    var proposal: SiriSettlementProposalEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSettlementRecordEntity> & ProvidesDialog & ShowsSnippetIntent {
        let selected: SiriSettlementProposalEntity
        if let proposal {
            guard sheet == nil || sheet?.id == proposal.sheetID else { throw AppIntentError.sheetNotFound }
            selected = proposal
        } else {
            let sheets = try SiriSettlementStore.writableSheets()
            let candidates: [SiriSettlementProposalEntity]
            if let sheet {
                guard let allowed = sheets.first(where: { $0.id == sheet.id }) else { throw AppIntentError.sheetNotFound }
                candidates = try SiriSettlementProposalQuery.proposals(in: allowed)
            } else {
                candidates = try SiriSettlementProposalQuery.availableProposals(across: sheets)
            }
            guard let first = candidates.first else { throw SettlementSelectionError.noProposal }
            if candidates.count == 1 { selected = first }
            else { selected = try await $proposal.requestDisambiguation(among: candidates, dialog: "どの送金を精算済みにしますか？") }
        }
        let prepared = try SiriSettlementStore.prepareSuggested(sheetID: selected.sheetID, proposalID: selected.id)
        let saved = try await confirmAndRecord(prepared, sheetID: selected.sheetID)
        return .result(value: saved.record, dialog: saved.dialog, snippetIntent: saved.snippet)
    }
}

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriLogSettlementTransferIntent: AppIntent {
    static let title: LocalizedStringResource = "メンバー間の送金を記録"
    static let description = IntentDescription("「アキラからユキに1,000円を送金した」のように、すでに行った送金をシートの精算履歴に記録します。送金者・受取者・金額を確認して保存します。", searchKeywords: ["送金", "精算"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", optionsProvider: SiriSettlementWritableSheetQuery()) var sheet: ExpenseSheetEntity?
    @Parameter(title: "送金者", optionsProvider: SiriSettlementSenderQuery()) var fromMember: SiriSheetMemberEntity
    @Parameter(title: "受取者", optionsProvider: SiriSettlementRecipientQuery()) var toMember: SiriSheetMemberEntity
    @Parameter(title: "金額") var amount: Double
    @Parameter(title: "通貨", description: "送金した通貨。省略時はシートの既定通貨を使います。", optionsProvider: SiriCurrencyOptions())
    var currencyCode: String?
    @Parameter(title: "送金日") var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$fromMember) から \(\.$toMember) に \(\.$amount) の送金を記録") {
            \.$sheet
            \.$currencyCode
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSettlementRecordEntity> & ProvidesDialog & ShowsSnippetIntent {
        guard let sheetID = SiriSettlementProposalQuery.sheetIdentifier(of: fromMember.id),
              SiriSettlementProposalQuery.sheetIdentifier(of: toMember.id) == sheetID,
              sheet == nil || sheet?.id == sheetID else { throw SettlementSelectionError.chooseMatchingMembers }
        let prepared = try SiriSettlementStore.prepareManual(sheetID: sheetID, fromMemberID: fromMember.id, toMemberID: toMember.id,
                                                             amount: amount, currency: currencyCode, date: date)
        let saved = try await confirmAndRecord(prepared, sheetID: sheetID)
        return .result(value: saved.record, dialog: saved.dialog, snippetIntent: saved.snippet)
    }
}

@available(iOS 27.3, macOS 27.3, *)
private extension AppIntent {
    @MainActor
    func confirmAndRecord(_ prepared: SiriSettlementStore.Prepared, sheetID: String) async throws
        -> (record: SiriSettlementRecordEntity, dialog: IntentDialog, snippet: SiriSettlementReceiptSnippetIntent) {
        let day = prepared.date.formatted(date: .abbreviated, time: .omitted)
        let amount = prepared.formattedAmount
        let prompt = IntentDialog("「\(prepared.sheetName)」に、\(day)の\(prepared.fromName)から\(prepared.toName)への送金 \(amount)（\(prepared.currencyCode)）を記録しますか？")
        try await requestConfirmation(actionName: .custom(acceptLabel: "送金を記録", acceptAlternatives: ["記録"],
                                                          denyLabel: "キャンセル", denyAlternatives: [], destructive: false),
                                      dialog: prompt, showDialogAsPrompt: true) {
            SiriSettlementCardView(sheetName: prepared.sheetName, sheetSymbol: prepared.sheetSymbol, sheetColorHex: prepared.sheetColorHex,
                                   period: day, title: "送金を記録", rows: [.init(from: prepared.fromAvatar, to: prepared.toAvatar, amount: amount)])
        }
        let id = try SiriSettlementStore.commit(prepared)
        let label = String(localized: "\(prepared.fromName) → \(prepared.toName) · \(amount)")
        let record = SiriSettlementRecordEntity(sheetID: sheetID, recordID: id, label: label)
        let dialog = IntentDialog("「\(prepared.sheetName)」に、\(prepared.fromName)から\(prepared.toName)への送金 \(amount) を記録しました。")
        return (record, dialog, SiriSettlementReceiptSnippetIntent(sheetID: sheetID, recordID: id))
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriSettlementReceiptSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "送金の記録カードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シートの識別子") var sheetID: String
    @Parameter(title: "送金記録の識別子") var recordID: String

    init() {}
    init(sheetID: String, recordID: UUID) {
        self.sheetID = sheetID
        self.recordID = recordID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard let id = UUID(uuidString: recordID) else { throw SettlementSelectionError.recordUnavailable }
        let receipt = try SiriSettlementStore.receipt(sheetID: sheetID, recordID: id)
        return .result(view: SiriSettlementCardView(sheetName: receipt.sheetName, sheetSymbol: receipt.sheetSymbol, sheetColorHex: receipt.sheetColorHex,
                                                    period: receipt.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "日付不明"), title: "送金を記録しました",
                                                    rows: [.init(from: receipt.fromAvatar, to: receipt.toAvatar, amount: receipt.formattedAmount)]))
    }
}

private enum SettlementSelectionError: Error, CustomLocalizedStringResourceConvertible {
    case noProposal, chooseMatchingMembers, recordUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noProposal: "精算済みにできる送金の提案はありません。"
        case .chooseMatchingMembers: "同じシートの送金者と受取者を選んでください。"
        case .recordUnavailable: "この送金記録は現在表示できません。"
        }
    }
}
#endif

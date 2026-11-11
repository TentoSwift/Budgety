#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import Foundation
import SwiftUI

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriSettlementStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "シートの精算状況を確認"
    static let description = IntentDescription(
        "「だれがだれにいくら払えばいい？」「精算の状況は？」に、シートの全期間の割り勘から、未精算の送金元・送金先・金額を返します。",
        searchKeywords: ["精算", "割り勘", "立て替え", "送金プラン"]
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "指定されたシート。省略時は最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSettlementCardResult> & ProvidesDialog & ShowsSnippetIntent {
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの精算状況を確認しますか？")
        }
        let card = try SiriSettlementCardResult.status(sheetID: sheetID)
        return .result(value: card, dialog: IntentDialog(full: "\(card.summary)", supporting: "精算状況"),
                       snippetIntent: SiriSettlementStatusSnippetIntent(sheetID: sheetID))
    }
}

@available(iOS 27.3, *)
struct SiriSettlementStatusSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "精算状況のカードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シートの識別子") var sheetID: String

    init() {}

    init(sheetID: String) { self.sheetID = sheetID }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        // Re-resolve the sheet so a locked, removed or revoked share is never redrawn.
        let card = try SiriSettlementCardResult.status(sheetID: sheetID)
        return .result(view: SiriSettlementCardView(result: card))
    }
}

@available(iOS 27.3, *)
struct SiriSettlementProfile: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "メンバー"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "名前") var name: String
    @Property(title: "メンバーの色", visibility: .internal) var colorHex: String
    @Property(title: "プロフィール画像", visibility: .internal) var photo: IntentFile?
    @Property(title: "バーチャルメンバー", visibility: .internal) var isVirtual: Bool

    init() {}

    init(name: String, colorHex: String = "", photo: IntentFile? = nil, isVirtual: Bool = false) {
        self.name = name
        self.colorHex = colorHex
        self.photo = photo
        self.isVirtual = isVirtual
    }

    init(_ avatar: SiriSettlementStore.Avatar) {
        self.init(name: avatar.name, colorHex: avatar.colorHex, photo: SiriExpensePayer.thumbnail(from: avatar.photoData),
                  isVirtual: avatar.isVirtual)
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(iOS 27.3, *)
struct SiriSettlementCardRow: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "送金の提案"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "送金元") var sender: SiriSettlementProfile
    @Property(title: "送金先") var recipient: SiriSettlementProfile
    @Property(title: "対象の送金") var proposal: SiriSettlementProposalEntity?
    @Property(title: "金額") var amount: String

    init() {}

    init(from: SiriSettlementStore.Avatar, to: SiriSettlementStore.Avatar, amount: String,
         proposal: SiriSettlementProposalEntity? = nil) {
        self.sender = SiriSettlementProfile(from)
        self.recipient = SiriSettlementProfile(to)
        self.amount = amount
        self.proposal = proposal
    }

    var spokenDetail: String { String(localized: "\(sender.name)から\(recipient.name)へ\(amount)") }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sender.name) → \(recipient.name)", subtitle: "\(amount)")
    }
}

@available(iOS 27.3, *)
struct SiriSettlementCardResult: TransientAppEntity, SnippetRepresentableEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "精算状況"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "シート名") var sheetName: String
    @Property(title: "シートのアイコン", visibility: .internal) var sheetSymbol: String?
    @Property(title: "シートの色", visibility: .internal) var sheetColorHex: String?
    @Property(title: "対象期間") var period: String
    @Property(title: "送金プラン") var rows: [SiriSettlementCardRow]
    @Property(title: "レートが見つからず除外された通貨") var missingRates: [String]

    init() {}

    @MainActor
    static func status(sheetID: String) throws -> Self {
        let status = try SiriSettlementStore.status(sheetID: sheetID)
        let card = Self()
        card.sheetName = status.sheetName
        card.sheetSymbol = status.sheetSymbol
        card.sheetColorHex = status.sheetColorHex
        card.period = String(localized: "全期間")
        card.rows = status.proposals.map {
            SiriSettlementCardRow(from: $0.fromAvatar, to: $0.toAvatar, amount: $0.formattedAmount,
                                  proposal: SiriSettlementProposalEntity(sheetID: sheetID, sheetName: status.sheetName, proposal: $0))
        }
        card.missingRates = status.missingRateCurrencies
        return card
    }

    var summary: String {
        let plan = rows.isEmpty
            ? String(localized: missingRates.isEmpty ? "精算は不要です" : "換算できた範囲では精算は不要です")
            : rows.map(\.spokenDetail).formatted(.list(type: .and))
        let header = [sheetName, period].joined(separator: " · ")
        var lines = [header, plan]
        if !missingRates.isEmpty {
            lines.append(String(localized: "未換算の通貨：\(missingRates.formatted(.list(type: .and)))"))
        }
        return lines.joined(separator: "\n")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sheetName)", subtitle: "\(period)")
    }

    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { result, _ in
            SiriSettlementCardView(result: result)
        }
    }
}
#endif

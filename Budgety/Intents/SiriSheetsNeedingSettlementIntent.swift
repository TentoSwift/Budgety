#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import SwiftUI

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriSheetsNeedingSettlementIntent: AppIntent {
    static let title: LocalizedStringResource = "精算が必要なシートを確認"
    static let description = IntentDescription("「精算が必要なシートは？」「まだ精算していないシートはどれ？」に、確認できるすべてのシートの未精算額をシートごとの通貨で返します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSheetsNeedingSettlementResult> & ProvidesDialog & ShowsSnippetIntent {
        let result = try SiriSheetsNeedingSettlementResult.load()
        return .result(value: result, dialog: IntentDialog(full: "\(result.summary)", supporting: "精算が必要なシート"),
                       snippetIntent: SiriSheetsNeedingSettlementSnippetIntent())
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriSheetsNeedingSettlementSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "精算が必要なシートのカードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let result = try SiriSheetsNeedingSettlementResult.load()
        return .result(view: SiriUnsettledSheetsCard(result: result))
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriUnsettledSheet: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "シートの未精算額"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "シート") var sheet: ExpenseSheetEntity
    @Property(title: "未精算額") var amount: String?
    @Property(title: "基準通貨") var currency: String
    @Property(title: "未換算の通貨") var missingRates: [String]

    init() {}

    @MainActor
    init(sheet: ExpenseSheetEntity, status: SiriSettlementStore.Status) {
        self.sheet = sheet
        currency = status.currencyCode
        missingRates = status.missingRateCurrencies
        if !status.proposals.isEmpty {
            let total = status.proposals.reduce(Decimal.zero) { $0 + $1.amount }
            amount = SiriSettlementStore.formatAmount(total, currency: status.currencyCode)
        }
    }

    var rateNote: String? {
        guard !missingRates.isEmpty else { return nil }
        return String(localized: "未換算：\(missingRates.formatted(.list(type: .and)))")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sheet.name)", subtitle: "\([amount, rateNote].compactMap { $0 }.joined(separator: " · "))")
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriSheetsNeedingSettlementResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "精算が必要なシート"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "精算が必要なシート") var outstanding: [SiriUnsettledSheet]
    @Property(title: "レート不足で判定できないシート") var undetermined: [SiriUnsettledSheet]

    init() {}

    init(outstanding: [SiriUnsettledSheet], undetermined: [SiriUnsettledSheet]) {
        self.outstanding = outstanding
        self.undetermined = undetermined
    }

    @MainActor
    static func load() throws -> Self {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        var outstanding: [SiriUnsettledSheet] = []
        var undetermined: [SiriUnsettledSheet] = []
        for sheet in try access.sheets() {
            let entity = ExpenseSheetEntity.from(sheet)
            let status: SiriSettlementStore.Status
            do { status = try SiriSettlementStore.status(sheetID: entity.id) }
            catch AppIntentError.sheetNotFound { continue }
            guard !status.proposals.isEmpty || !status.missingRateCurrencies.isEmpty else { continue }
            let item = SiriUnsettledSheet(sheet: entity, status: status)
            if item.amount != nil { outstanding.append(item) }
            else { undetermined.append(item) }
        }
        return Self(outstanding: outstanding, undetermined: undetermined)
    }

    var summary: String {
        if outstanding.isEmpty && undetermined.isEmpty { return String(localized: "精算が必要なシートはありません。") }
        let lines = outstanding.map { item in
            [item.sheet.name, item.amount, item.rateNote].compactMap { $0 }.joined(separator: " · ")
        } + undetermined.map { item in
            String(localized: "\(item.sheet.name)はレート不足のため判定できません。\(item.rateNote ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }
}

@available(iOS 27.3, macOS 27.3, *)
private struct SiriUnsettledSheetsCard: View {
    let result: SiriSheetsNeedingSettlementResult
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let items = result.outstanding + result.undetermined
        #if os(watchOS)
        let limit = 2
        #else
        let limit = 4
        #endif
        VStack(alignment: .leading, spacing: 8) {
            Text("精算が必要なシート").font(.headline)
            if items.isEmpty {
                Text("精算が必要なシートはありません。").font(.subheadline)
            }
            ForEach(Array(items.prefix(limit)), id: \.sheet.id) { item in
                HStack(alignment: .top, spacing: 8) {
                    SheetSymbolIcon(symbol: item.sheet.symbol, tint: Color(hex: item.sheet.colorHex) ?? .indigo, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.sheet.name).font(.subheadline.weight(.semibold))
                        if let amount = item.amount {
                            Text(verbatim: amount).font(.body.monospacedDigit())
                        } else {
                            Text("判定できません").font(.subheadline)
                        }
                        if let note = item.rateNote { Text(verbatim: note).font(.caption) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if items.count > limit { Text("+\(items.count - limit)件").font(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .foregroundStyle(colorScheme == .dark ? .white : .black)
        .background(colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.98),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif

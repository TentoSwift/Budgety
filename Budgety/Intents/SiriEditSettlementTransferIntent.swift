#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import SwiftUI

@available(iOS 27.3, *)
struct SiriSettlementRecordEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "送金記録"
    static let defaultQuery = SiriSettlementRecordQuery()
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    let id: String
    @Property(title: "シートの識別子", visibility: .internal) var sheetID: String
    @Property(title: "送金記録") var label: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }

    init(sheetID: String, recordID: UUID, label: String) {
        id = sheetID + "#" + recordID.uuidString
        self.sheetID = sheetID
        self.label = label
    }

    @MainActor
    init(_ row: SettlementRecord, sheet: ExpenseSheet) {
        let sheetKey = sheet.objectID.uriRepresentation().absoluteString
        id = sheetKey + "#" + (row.id?.uuidString ?? row.objectID.uriRepresentation().absoluteString)
        sheetID = sheetKey
        let from = SiriSettlementStore.avatar(row.fromProfileID ?? "", in: sheet).name
        let to = SiriSettlementStore.avatar(row.toProfileID ?? "", in: sheet).name
        let date = row.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "日付不明")
        label = [from + " → " + to, SiriSettlementStore.formatAmount(row.amountDecimal, currency: row.resolvedCurrencyCode), date, sheet.displayName].joined(separator: " · ")
    }
}

@available(iOS 27.3, *)
struct SiriSettlementRecordQuery: EntityStringQuery {
    @IntentParameterDependency<SiriEditSettlementTransferIntent>(\.$sheet) var edit

    @MainActor
    func suggestedEntities() async throws -> [SiriSettlementRecordEntity] { try search("") }

    @MainActor
    func entities(matching string: String) async throws -> [SiriSettlementRecordEntity] { try search(string) }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriSettlementRecordEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return identifiers.compactMap { id in
            guard let end = id.firstIndex(of: "#") else { return nil }
            let sheetID = String(id[..<end])
            guard edit?.sheet.id == nil || sheetID == edit?.sheet.id,
                  let sheet = try? SiriSettlementStore.writableSheet(sheetID, access: access),
                  let row = try? SiriSettlementEditStore.record(identifier: id, in: sheet, access: access) else { return nil }
            return SiriSettlementRecordEntity(row, sheet: sheet)
        }
    }

    @MainActor
    private func search(_ text: String) throws -> [SiriSettlementRecordEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let ids: [String]
        if let selected = edit?.sheet.id ?? UserDefaults.standard.string(forKey: "lastOpenedSheetURI") {
            ids = [selected]
        } else {
            ids = try SiriSettlementStore.writableSheets().map(\.id)
        }
        let sheets = try ids.map { try SiriSettlementStore.writableSheet($0, access: access) }
        let request = SettlementRecord.fetchRequest()
        request.predicate = NSPredicate(format: "sheet IN %@", sheets)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \SettlementRecord.createdAt, ascending: false),
                                   NSSortDescriptor(keyPath: \SettlementRecord.date, ascending: false)]
        request.fetchBatchSize = 40
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var results: [SiriSettlementRecordEntity] = []
        for row in try access.context.fetch(request) {
            guard let sheet = row.sheet, SiriSettlementEditStore.canEdit(row, access: access) else { continue }
            let entity = SiriSettlementRecordEntity(row, sheet: sheet)
            let searchable = [entity.label, row.resolvedCurrencyCode, NSDecimalNumber(decimal: row.amountDecimal).stringValue,
                              row.note ?? ""].joined(separator: " ")
            if terms.allSatisfy({ searchable.localizedStandardContains($0) }) { results.append(entity) }
            if terms.isEmpty, results.count == 20 { break }
        }
        return results
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriEditSettlementTransferIntent: AppIntent {
    static let title: LocalizedStringResource = "記録した送金を変更"
    static let description = IntentDescription("送金履歴や、直前に精算済みにした送金の相手・金額・通貨・日付・メモを訂正します。変更内容を確認して同じ送金記録を更新します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", optionsProvider: SiriSettlementWritableSheetQuery()) var sheet: ExpenseSheetEntity?
    @Parameter(title: "変更する送金") var record: SiriSettlementRecordEntity
    @Parameter(title: "変更後の送金元", optionsProvider: SiriSettlementEditMemberQuery()) var sender: SiriSheetMemberEntity?
    @Parameter(title: "変更後の送金先", optionsProvider: SiriSettlementEditMemberQuery()) var recipient: SiriSheetMemberEntity?
    @Parameter(title: "新しい金額") var amount: Double?
    @Parameter(title: "変更後の通貨", optionsProvider: SiriCurrencyOptions()) var currency: String?
    @Parameter(title: "新しい日付") var date: Date?
    @Parameter(title: "変更後のメモ") var note: String?
    @Parameter(title: "メモを消去") var clearNote: Bool?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSettlementRecordEntity> & ProvidesDialog & ShowsSnippetIntent {
        guard sheet == nil || sheet?.id == record.sheetID else { throw AppIntentError.sheetNotFound }
        let prepared = try SiriSettlementEditStore.prepare(identifier: record.id, sheetID: record.sheetID,
            request: .init(sender: sender, recipient: recipient, amount: amount, currency: currency, date: date,
                           note: clearNote == true ? "" : note))
        let changes = prepared.changes.joined(separator: "\n")
        let prompt = IntentDialog("「\(prepared.sheetName)」の送金を変更しますか？\n\(changes)")
        try await requestConfirmation(actionName: .custom(acceptLabel: "アップデート", acceptAlternatives: ["変更を保存"],
                                                          denyLabel: "キャンセル", denyAlternatives: [], destructive: true),
                                      dialog: prompt, showDialogAsPrompt: true) {
            SiriSettlementCardView(sheetName: prepared.sheetName, sheetSymbol: prepared.sheetSymbol,
                                   sheetColorHex: prepared.sheetColorHex, period: prepared.after.date?.formatted(date: .abbreviated, time: .omitted) ?? "",
                                   title: "変更後の送金", rows: [.init(from: prepared.fromAvatar, to: prepared.toAvatar, amount: prepared.formattedAmount)])
        }
        let id = try SiriSettlementEditStore.commit(prepared)
        let label = String(localized: "\(prepared.fromAvatar.name) → \(prepared.toAvatar.name) · \(prepared.formattedAmount)")
        return .result(value: SiriSettlementRecordEntity(sheetID: prepared.sheetID, recordID: id, label: label),
                       dialog: "送金記録を変更しました。",
                       snippetIntent: SiriSettlementReceiptSnippetIntent(sheetID: prepared.sheetID, recordID: id))
    }
}

@available(iOS 27.3, *)
struct SiriSettlementEditMemberQuery: SettlementMemberOptions {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriEditSettlementTransferIntent>(\.$sheet) var editSheet
    @IntentParameterDependency<SiriEditSettlementTransferIntent>(\.$record) var editRecord

    var requestedSheetID: String? { editSheet?.sheet.id ?? editRecord?.record.sheetID }
    var senderID: String? { nil }
}
#endif

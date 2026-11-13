#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import SwiftUI

@available(iOS 27.3, macOS 27.3, *)
struct SiriSettlementRecordEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "送金記録"
    static let defaultQuery = SiriSettlementRecordQuery()
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    let id: String
    #if os(iOS) || os(macOS)
    @Property(title: "シートの識別子", visibility: .internal)
    #endif
    var sheetID: String
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

@available(iOS 27.3, macOS 27.3, *)
struct SiriSettlementRecordQuery: EntityStringQuery {
    @IntentParameterDependency<SiriEditSettlementTransferIntent>(\.$sheet) var edit

    @IntentParameterDependency<SiriCancelSettlementIntent>(\.$sheet) var cancel

    private var sheetID: String? { edit?.sheet.id ?? cancel?.sheet.id }

    @MainActor
    func suggestedEntities() async throws -> [SiriSettlementRecordEntity] {
        try Self.search("", sheetID: sheetID, forCancellation: cancel != nil)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriSettlementRecordEntity] {
        try Self.search(string, sheetID: sheetID, forCancellation: cancel != nil)
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriSettlementRecordEntity] {
        try Self.resolve(identifiers, sheetID: sheetID, forCancellation: cancel != nil)
    }

    @MainActor
    static func resolve(_ identifiers: [String], sheetID selected: String?, forCancellation: Bool) throws -> [SiriSettlementRecordEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return identifiers.compactMap { id in
            guard let end = id.firstIndex(of: "#") else { return nil }
            let sheetID = String(id[..<end])
            guard selected == nil || sheetID == selected,
                  let sheet = try? SiriSettlementStore.writableSheet(sheetID, access: access),
                  let row = try? SiriSettlementEditStore.record(identifier: id, in: sheet, access: access, forCancellation: forCancellation) else { return nil }
            return SiriSettlementRecordEntity(row, sheet: sheet)
        }
    }

    @MainActor
    static func search(_ text: String, sheetID: String?, forCancellation: Bool) throws -> [SiriSettlementRecordEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let ids: [String]
        if let selected = sheetID ?? IntentSheetAccess.lastOpenedSheetURI {
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
            guard let sheet = row.sheet, SiriSettlementEditStore.canModify(row, access: access, forCancellation: forCancellation) else { continue }
            let entity = SiriSettlementRecordEntity(row, sheet: sheet)
            let searchable = [entity.label, row.resolvedCurrencyCode, NSDecimalNumber(decimal: row.amountDecimal).stringValue,
                              row.note ?? ""].joined(separator: " ")
            if terms.allSatisfy({ searchable.localizedStandardContains($0) }) { results.append(entity) }
            if terms.isEmpty, results.count == 20 { break }
        }
        return results
    }
}

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
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
    #if os(watchOS)
    @Parameter(title: "変更する項目") var field: SettlementEditField?
    #endif

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSettlementRecordEntity> & ProvidesDialog & ShowsSnippetIntent {
        guard sheet == nil || sheet?.id == record.sheetID else { throw AppIntentError.sheetNotFound }
        var request = SiriSettlementEditStore.Request(sender: sender, recipient: recipient, amount: amount,
                                                       currency: currency, date: date, note: clearNote == true ? "" : note)
        #if os(watchOS)
        if sender == nil, recipient == nil, amount == nil, currency == nil, date == nil, request.note == nil {
            let selected: SettlementEditField
            if let field { selected = field }
            else { selected = try await $field.requestValue("送金のどの項目を変更しますか？") }
            switch selected {
            case .amount:    request.amount = try await $amount.requestValue("新しい金額はいくらですか？")
            case .sender:    request.sender = try await $sender.requestValue("変更後の送金者はだれですか？")
            case .recipient: request.recipient = try await $recipient.requestValue("変更後の受取者はだれですか？")
            case .currency:  request.currency = try await $currency.requestValue("どの通貨に変更しますか？")
            case .date:      request.date = try await $date.requestValue("いつの送金に変更しますか？")
            case .note:      request.note = try await $note.requestValue("新しいメモを教えてください。")
            case .clearNote: request.note = ""
            }
        }
        #endif
        let prepared = try SiriSettlementEditStore.prepare(identifier: record.id, sheetID: record.sheetID, request: request)
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

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriCancelSettlementIntent: AppIntent {
    static let title: LocalizedStringResource = "記録した精算を取り消す"
    static let description = IntentDescription("精算済みにした送金や、手動で追加した送金を取り消します。送金元・送金先・金額を確認してから、選んだ送金記録を削除し、シートの精算残高に反映します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", optionsProvider: SiriSettlementWritableSheetQuery()) var sheet: ExpenseSheetEntity?
    @Parameter(title: "取り消す送金", optionsProvider: SiriSettlementRecordQuery()) var record: SiriSettlementRecordEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard sheet == nil || sheet?.id == record.sheetID else { throw AppIntentError.sheetNotFound }
        let prepared = try SiriSettlementEditStore.prepareCancellation(identifier: record.id, sheetID: record.sheetID)
        let prompt = IntentDialog("「\(prepared.sheetName)」の\(prepared.from.name)から\(prepared.to.name)への\(prepared.formattedAmount)の送金記録を取り消しますか？")
        try await requestConfirmation(actionName: .custom(acceptLabel: "精算を取り消す", acceptAlternatives: ["取り消す"],
                                                          denyLabel: "キャンセル", denyAlternatives: [], destructive: true),
                                      dialog: prompt, showDialogAsPrompt: true) {
            SiriSettlementCardView(sheetName: prepared.sheetName, sheetSymbol: prepared.sheetSymbol,
                                   sheetColorHex: prepared.sheetColorHex, period: prepared.date?.formatted(date: .abbreviated, time: .omitted) ?? "",
                                   title: "取り消す送金", rows: [.init(from: prepared.from, to: prepared.to, amount: prepared.formattedAmount)])
        }
        try SiriSettlementEditStore.cancel(prepared)
        return .result(dialog: "送金記録を取り消しました。")
    }
}

#if os(watchOS)
enum SettlementEditField: String, AppEnum {
    case amount, sender, recipient, currency, date, note, clearNote

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "変更する送金項目"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .amount: "金額", .sender: "送金者", .recipient: "受取者", .currency: "通貨",
        .date: "送金日", .note: "メモ", .clearNote: "メモを消去"
    ]
}
#endif

@available(iOS 27.3, macOS 27.3, *)
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

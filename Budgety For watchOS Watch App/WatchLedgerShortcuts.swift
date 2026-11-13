import AppIntents
import CoreData
import Foundation

enum WatchRecordLedgerOperation: String, AppEnum {
    case single, batch
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "追加する明細"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .single: "支出を1件追加", .batch: "明細をまとめて追加"
    ]
}

enum WatchEditLedgerOperation: String, AppEnum {
    case single, batch
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "編集する明細"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .single: "明細を1件編集", .batch: "明細をまとめて編集"
    ]
}

private enum WatchLedgerInputError: Error, CustomLocalizedStringResourceConvertible {
    case singleEntryParameters, singleEditParameters

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .singleEntryParameters: "まとめて追加では各行に名前と金額を指定してください。支払者や割り勘の指定は1件ずつ追加するときに使えます。"
        case .singleEditParameters: "まとめて編集では名前、金額、通貨、日付、カテゴリを変更できます。支払者や割り勘の変更は1件ずつ指定してください。"
        }
    }
}

struct WatchRecordLedgerShortcut: AppIntent {
    static let title: LocalizedStringResource = "明細を追加"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "追加方法") var operation: WatchRecordLedgerOperation?
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity
    @Parameter(title: "追加する明細", description: "1件ずつ「ランチ 1,200円」「収入 給与 300000円」のように指定します。")
    var lines: [String]?
    @Parameter(title: "金額") var amount: Double?
    @Parameter(title: "支出名") var expenseTitle: String?
    @Parameter(title: "日付") var date: Date?
    @Parameter(title: "通貨", optionsProvider: SiriCurrencyOptions()) var currencyCode: String?
    @Parameter(title: "支払者", optionsProvider: WatchRecordingMemberQuery()) var payer: SiriSheetMemberEntity?
    @Parameter(title: "全員で割り勘") var splitAll: Bool?
    @Parameter(title: "割り勘の対象", optionsProvider: WatchRecordingMemberQuery()) var beneficiaries: [SiriSheetMemberEntity]?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        if operation == .batch {
            guard amount == nil, expenseTitle == nil, payer == nil, splitAll != true, beneficiaries?.isEmpty != false
            else { throw WatchLedgerInputError.singleEntryParameters }
            guard let lines, !lines.isEmpty else { throw $lines.needsValueError("追加する明細の名前と金額を1件ずつ教えてください。") }
            let entries = try SiriBatchAddTransactionsIntent.parse(lines: lines, defaultKind: .expense, currency: currencyCode, date: date ?? .now)
            let prepared = try SiriBatchTransactionStore.prepareAdd(sheetID: sheet.id, entries: entries)
            try await requestConfirmation(actionName: .add, dialog: IntentDialog("次の\(prepared.count)件を追加しますか？\n\(prepared.summary)"))
            let count = try SiriBatchTransactionStore.commit(prepared).count
            return .result(dialog: "\(count)件の明細を追加しました。", snippetIntent: EmptySnippetIntent())
        }
        guard let amount else { throw $amount.needsValueError("支出はいくらですか？") }
        let saved = try await AddExpenseIntent.recordTransaction(sheet: sheet, kind: .expense, amount: amount, title: expenseTitle,
                                                                 date: date ?? .now, currencyCode: currencyCode, payer: payer,
                                                                 splitAll: splitAll ?? false, beneficiaries: beneficiaries ?? [])
        let id = saved.transaction.objectID.uriRepresentation().absoluteString
        return .result(dialog: saved.dialog, snippetIntent: SiriRecordedTransactionSnippetIntent(identifier: id))
    }
}

struct WatchRecordingMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<WatchRecordLedgerShortcut>(\.$sheet) var recording
    func selectedSheetID(access: IntentSheetAccess) throws -> String? { recording?.sheet.id }
}

struct WatchEditLedgerShortcut: AppIntent {
    static let title: LocalizedStringResource = "明細を編集"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "編集方法") var operation: WatchEditLedgerOperation?
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity
    @Parameter(title: "変更する明細", optionsProvider: WatchSelectedLedgerQuery()) var transaction: SiriEditableTransactionEntity?
    @Parameter(title: "まとめて変更する明細", optionsProvider: WatchSelectedLedgerQuery()) var transactions: [SiriEditableTransactionEntity]?
    @Parameter(title: "変更する項目") var field: WatchTransactionEditField?
    @Parameter(title: "新しい名前") var newTitle: String?
    @Parameter(title: "新しい金額") var newAmount: Double?
    @Parameter(title: "変更後の通貨", optionsProvider: SiriCurrencyOptions()) var currencyCode: String?
    @Parameter(title: "新しい日付") var newDate: Date?
    @Parameter(title: "変更後のカテゴリ", optionsProvider: WatchSelectedCategoryQuery()) var category: ExpenseCategoryEntity?
    @Parameter(title: "支払者・受取者", optionsProvider: WatchEditingMemberQuery()) var payer: SiriSheetMemberEntity?
    @Parameter(title: "割り勘") var split: SiriTransactionSplitChange?
    @Parameter(title: "割り勘の対象", optionsProvider: WatchEditingMemberQuery()) var beneficiaries: [SiriSheetMemberEntity]?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let isBatch = operation == .batch
        let selected: [SiriEditableTransactionEntity]
        if isBatch {
            guard let transactions, !transactions.isEmpty else { throw $transactions.needsValueError("どの明細をまとめて変更しますか？") }
            selected = transactions
        } else {
            guard let transaction else { throw $transaction.needsValueError("どの明細を変更しますか？") }
            selected = [transaction]
        }
        if newTitle == nil, newAmount == nil, newDate == nil, category == nil, currencyCode == nil, payer == nil,
           split == nil, beneficiaries?.isEmpty != false {
            let fields = WatchTransactionEditField.allCases.filter { choice in
                if choice == .split { return !isBatch && selected.first?.kindName == TransactionKind.expense.label }
                if choice == .payer { return !isBatch }
                return true
            }
            guard let field else {
                throw $field.needsDisambiguationError(among: fields, dialog: "どの項目を変更しますか？")
            }
            switch field {
            case .title: throw $newTitle.needsValueError("新しい名前は何ですか？")
            case .amount: throw $newAmount.needsValueError("金額をいくらにしますか？")
            case .currency: throw $currencyCode.needsValueError("どの通貨にしますか？")
            case .date: throw $newDate.needsValueError("日付をいつにしますか？")
            case .category: throw $category.needsValueError("どのカテゴリにしますか？")
            case .payer: throw $payer.needsValueError("どのメンバーに変更しますか？")
            case .split: throw $split.needsDisambiguationError(among: [.off, .all, .selected], dialog: "割り勘をどう変更しますか？")
            }
        }
        if isBatch {
            guard payer == nil, split == nil, beneficiaries?.isEmpty != false else {
                throw WatchLedgerInputError.singleEditParameters
            }
            let prepared = try SiriBatchEditTransactionsIntent.prepare(sheetID: sheet.id, transactions: selected, title: newTitle,
                                                                       amount: newAmount, currencyCode: currencyCode, date: newDate, category: category)
            try await requestConfirmation(actionName: SiriBatchEditTransactionsIntent.confirmationAction,
                                          dialog: IntentDialog("次の\(prepared.count)件を変更しますか？\n\(prepared.summary)"))
            let count = try SiriBatchTransactionStore.commit(prepared).count
            return .result(dialog: "\(count)件の明細を変更しました。", snippetIntent: EmptySnippetIntent())
        }
        if split == .selected, beneficiaries?.isEmpty != false { throw $beneficiaries.needsValueError("割り勘の対象は誰ですか？") }
        let edit = SiriEditTransactionIntent()
        edit.sheet = sheet
        edit.transaction = selected[0]
        edit.newTitle = newTitle
        edit.newAmount = newAmount
        edit.currencyCode = currencyCode
        edit.newDate = newDate
        edit.category = category
        edit.payer = payer
        edit.split = split
        edit.beneficiaries = beneficiaries
        _ = try await edit.perform()
        return .result(dialog: "明細を変更しました。", snippetIntent: SiriRecordedTransactionSnippetIntent(identifier: selected[0].id))
    }
}

struct WatchSelectedLedgerQuery: EntityStringQuery {
    @IntentParameterDependency<WatchEditLedgerShortcut>(\.$sheet) var edit

    @MainActor func suggestedEntities() async throws -> [SiriEditableTransactionEntity] { try candidates("") }
    @MainActor func entities(matching string: String) async throws -> [SiriEditableTransactionEntity] { try candidates(string) }
    @MainActor func entities(for identifiers: [String]) async throws -> [SiriEditableTransactionEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriEditableTransactionQuery.resolve(identifiers, in: edit?.sheet.id, access: access)
    }
    @MainActor private func candidates(_ term: String) throws -> [SiriEditableTransactionEntity] {
        guard let selected = edit?.sheet else { return [] }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriEditableTransactionQuery.candidates(in: access.resolve(selected.id), matching: term, access: access)
    }
}

struct WatchEditingMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<WatchEditLedgerShortcut>(\.$sheet) var edit
    func selectedSheetID(access: IntentSheetAccess) throws -> String? { edit?.sheet.id }
}

struct WatchSelectedCategoryQuery: EntityStringQuery {
    @IntentParameterDependency<WatchEditLedgerShortcut>(\.$sheet) var editSheet
    @IntentParameterDependency<WatchEditLedgerShortcut>(\.$transaction) var editOne
    @IntentParameterDependency<WatchEditLedgerShortcut>(\.$transactions) var editMany

    @MainActor func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        let targets = editMany?.transactions ?? editOne.map { [$0.transaction] } ?? []
        return try SiriBatchCategoryQuery.options(sheet: editSheet?.sheet, transactions: targets)
    }
    @MainActor func entities(for identifiers: [String]) async throws -> [ExpenseCategoryEntity] {
        let options = try await suggestedEntities()
        return identifiers.compactMap { id in options.first { $0.id == id } }
    }
    @MainActor func entities(matching string: String) async throws -> [ExpenseCategoryEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

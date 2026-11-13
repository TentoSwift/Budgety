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
    case singleEntryParameters

    var localizedStringResource: LocalizedStringResource {
        "まとめて追加では各行に名前と金額を指定してください。"
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
    @Parameter(title: "支払者・受取者", optionsProvider: WatchRecordingMemberQuery()) var payer: SiriSheetMemberEntity?
    @Parameter(title: "全員で割り勘") var splitAll: Bool?
    @Parameter(title: "割り勘の対象", optionsProvider: WatchRecordingMemberQuery()) var beneficiaries: [SiriSheetMemberEntity]?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        if operation == .batch {
            guard amount == nil, expenseTitle == nil else { throw WatchLedgerInputError.singleEntryParameters }
            guard let lines, !lines.isEmpty else { throw $lines.needsValueError("追加する明細の名前と金額を1件ずつ教えてください。") }
            let prepared = try SiriBatchAddTransactionsIntent.prepare(sheetID: sheet.id, lines: lines, defaultKind: .expense,
                                                                      currency: currencyCode, date: date ?? .now, payer: payer,
                                                                      splitAll: splitAll ?? false, beneficiaries: beneficiaries ?? [])
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
            let allExpenses = selected.allSatisfy { $0.kindName == TransactionKind.expense.label }
            let fields = WatchTransactionEditField.allCases.filter { $0 != .split || allExpenses }
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
        if split == .selected, beneficiaries?.isEmpty != false { throw $beneficiaries.needsValueError("割り勘の対象は誰ですか？") }
        if isBatch {
            let prepared = try SiriBatchEditTransactionsIntent.prepare(sheetID: sheet.id, transactions: selected, title: newTitle,
                                                                       amount: newAmount, currencyCode: currencyCode, date: newDate, category: category,
                                                                       payer: payer, split: split, beneficiaries: beneficiaries ?? [])
            try await requestConfirmation(actionName: SiriBatchEditTransactionsIntent.confirmationAction,
                                          dialog: IntentDialog("次の\(prepared.count)件を変更しますか？\n\(prepared.summary)"))
            let count = try SiriBatchTransactionStore.commit(prepared).count
            return .result(dialog: "\(count)件の明細を変更しました。", snippetIntent: EmptySnippetIntent())
        }
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

enum WatchSheetAction: String, AppEnum {
    case memberTransactions, members, categories, addCategory, pendingSettlements, cancelSettlement

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "シートの操作"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .memberTransactions: "メンバーの収支を確認",
        .members: DisplayRepresentation(title: "メンバー一覧を表示", synonyms: ["メンバーを教えて"]),
        .categories: DisplayRepresentation(title: "カテゴリ一覧を表示", synonyms: ["カテゴリを教えて"]),
        .addCategory: "カテゴリを追加",
        .pendingSettlements: DisplayRepresentation(title: "精算が必要なシートを確認", synonyms: ["精算が必要なシートは", "未精算のシートを表示"]),
        .cancelSettlement: DisplayRepresentation(title: "精算を取り消す", synonyms: ["送金を取り消す"])
    ]
}

struct WatchSheetActionShortcut: AppIntent {
    static let title: LocalizedStringResource = "シートの操作"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "操作") var operation: WatchSheetAction?
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバー", optionsProvider: WatchSheetActionMemberQuery()) var member: SiriSheetMemberEntity?
    @Parameter(title: "本文に全件を表示") var showAllInReply: Bool?
    @Parameter(title: "対象の収支") var kind: SiriTransactionSelection?
    @Parameter(title: "検索期間") var period: SiriExpensePeriod?
    @Parameter(title: "対象月") var month: Date?
    @Parameter(title: "対象日") var day: Date?
    @Parameter(title: "表示するメンバー") var rosterFilter: SiriRosterFilter?
    @Parameter(title: "カテゴリの種類") var categoryKind: TransactionKind?
    @Parameter(title: "新しいカテゴリ名") var categoryName: String?
    @Parameter(title: "取り消す精算", optionsProvider: WatchCancellationRecordQuery()) var settlement: SiriSettlementRecordEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        switch operation ?? .memberTransactions {
        case .memberTransactions:
            guard let member else { throw $member.needsValueError("どのメンバーの収支を調べますか？") }
            let query = SiriFindMemberTransactionsIntent()
            query.sheet = sheet
            query.member = member
            query.showAllInReply = showAllInReply
            query.kind = kind
            query.period = period
            query.month = month
            query.day = day
            let result = try query.search()
            return .result(dialog: IntentDialog("\(result.lookup.summary)"), snippetIntent: result.snippet)
        case .members, .categories:
            let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
                try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートを調べますか？")
            }
            let contents: SiriDirectoryContents
            if operation == .members {
                contents = (rosterFilter ?? .all).contents
            } else {
                switch categoryKind {
                case .expense: contents = .expenseCategories
                case .income: contents = .incomeCategories
                case nil: contents = .categories
                }
            }
            let result = try SiriSheetDirectoryResult.load(sheetID: sheetID, contents: contents)
            return .result(dialog: IntentDialog("\(result.summary)"), snippetIntent: SiriSheetDirectorySnippetIntent(sheetID: sheetID, contents: contents))
        case .addCategory:
            guard let categoryName else { throw $categoryName.needsValueError("新しいカテゴリの名前は何ですか？") }
            let intent = SiriAddCategoryIntent()
            intent.sheet = sheet
            intent.name = categoryName
            intent.kind = categoryKind
            _ = try await intent.perform()
            return .result(dialog: "カテゴリを追加しました。", snippetIntent: EmptySnippetIntent())
        case .pendingSettlements:
            let result = try SiriSheetsNeedingSettlementResult.load()
            return .result(dialog: IntentDialog("\(result.summary)"), snippetIntent: SiriSheetsNeedingSettlementSnippetIntent())
        case .cancelSettlement:
            guard let settlement else { throw $settlement.needsValueError("どの精算を取り消しますか？") }
            let intent = SiriCancelSettlementIntent()
            intent.sheet = sheet
            intent.record = settlement
            _ = try await intent.perform()
            return .result(dialog: "精算を取り消しました。", snippetIntent: EmptySnippetIntent())
        }
    }
}

struct WatchSheetActionMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<WatchSheetActionShortcut>(\.$sheet) var action

    func selectedSheetID(access: IntentSheetAccess) throws -> String? { action?.sheet.id }

    @MainActor func suggestedEntities() async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriSheetMemberRoster.searchCandidates(access: access, sheetID: selectedSheetID(access: access))
    }
}

struct WatchCancellationRecordQuery: EntityStringQuery {
    @IntentParameterDependency<WatchSheetActionShortcut>(\.$sheet) var action

    @MainActor func suggestedEntities() async throws -> [SiriSettlementRecordEntity] { try await entities(matching: "") }
    @MainActor func entities(matching string: String) async throws -> [SiriSettlementRecordEntity] {
        try SiriSettlementRecordQuery.search(string, sheetID: action?.sheet.id, forCancellation: true)
    }
    @MainActor func entities(for identifiers: [String]) async throws -> [SiriSettlementRecordEntity] {
        try SiriSettlementRecordQuery.resolve(identifiers, sheetID: action?.sheet.id, forCancellation: true)
    }
}

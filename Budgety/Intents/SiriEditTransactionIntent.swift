#if os(watchOS) || (os(iOS) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import Foundation
import SwiftUI

@available(iOS 27.3, *)
#if os(iOS)
@AppIntent(.tool)
#endif
struct SiriEditTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "登録済みの明細を変更"
    static let description = IntentDescription("直前に登録した明細や、既存の支出・収入のカテゴリ、金額、名前などを訂正します。対象の明細と変更したい項目だけを指定し、保存前に確認します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    #if os(watchOS)
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity
    @Parameter(title: "変更する項目") var editField: WatchTransactionEditField?
    #else
    @Parameter(title: "シート", description: "明細を名前で探すシート。直前のカードの明細を指定するときは省略できます。")
    var sheet: ExpenseSheetEntity?
    #endif
    @Parameter(title: "変更する明細", description: "直前の登録カードの編集対象、または変更したい既存の支出・収入。")
    var transaction: SiriEditableTransactionEntity
    @Parameter(title: "新しい名前") var newTitle: String?
    @Parameter(title: "新しい金額", description: "変更後の額面を正の数で指定します。通貨も変えるときは変更後の通貨を併せて指定します。")
    var newAmount: Double?
    @Parameter(title: "変更後の通貨", description: "明細の通貨だけを訂正するときや「1,200円に変更」のように金額と通貨を指定したときに設定します。金額を省略すれば数値は変わりません。",
               optionsProvider: SiriCurrencyOptions())
    var currencyCode: String?
    @Parameter(title: "新しい日付") var newDate: Date?
    @Parameter(title: "変更後のカテゴリ", description: "変更先のカテゴリ。支出はそのシートの支出カテゴリ、収入は収入カテゴリから選びます。解除するときは未分類、変更しないときは省略します。",
               optionsProvider: SiriEditingCategoryQuery())
    var category: ExpenseCategoryEntity?
    @Parameter(title: "支払者・受取者", description: "変更後の支払者。収入の場合は受取者。省略すると元の人を維持します。",
               optionsProvider: SiriEditingMemberQuery())
    var payer: SiriSheetMemberEntity?
    @Parameter(title: "割り勘", description: "割り勘を解除、全員で均等割り、または選んだメンバーだけで均等割り。省略すると元の設定を維持します。")
    var split: SiriTransactionSplitChange?
    @Parameter(title: "割り勘の対象", description: "変更後に負担する人全員。支払者も負担するときは含めてください。",
               optionsProvider: SiriEditingMemberQuery())
    var beneficiaries: [SiriSheetMemberEntity]?

    static var parameterSummary: some ParameterSummary {
        #if os(watchOS)
        Summary("\(\.$sheet) の \(\.$transaction) を変更") {
            \.$editField
            \.$newTitle
            \.$newAmount
            \.$currencyCode
            \.$newDate
            \.$category
            \.$payer
            \.$split
            \.$beneficiaries
        }
        #else
        Summary("\(\.$transaction) を変更") {
            \.$sheet
            \.$newTitle
            \.$newAmount
            \.$currencyCode
            \.$newDate
            \.$category
            \.$payer
            \.$split
            \.$beneficiaries
        }
        #endif
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriRecordedTransaction> & ProvidesDialog & ShowsSnippetIntent {
        #if os(watchOS)
        try requestMissingEditValues()
        let sheetID = sheet.id
        #else
        let sheetID = sheet?.id ?? transaction.sheetID
        #endif
        let selected = beneficiaries ?? []
        let prepared = try SiriTransactionEditStore.prepare(
            identifier: transaction.id, sheetIdentifier: sheetID,
            title: newTitle, amount: newAmount, date: newDate, payer: payer,
            split: split ?? (selected.isEmpty ? .unchanged : .selected), beneficiaries: selected,
            category: category, currencyCode: currencyCode)
        let changes = prepared.changes.map { String(localized: "\($0.label)：\($0.before) → \($0.after)") }
            .joined(separator: "\n")
        let prompt = IntentDialog("「\(prepared.sheetName)」の「\(prepared.transactionTitle)」を変更しますか？\n\(changes)")
        try await requestConfirmation(actionName: .custom(acceptLabel: "アップデート", acceptAlternatives: ["変更を保存"],
                                                          denyLabel: "キャンセル", denyAlternatives: [], destructive: true),
                                      dialog: prompt, showDialogAsPrompt: true) {
            SiriExpenseCardView(recorded: prepared.originalReceipt, allowsOpening: false)
        }
        let saved = try SiriTransactionEditStore.commit(prepared)
        let receipt = SiriRecordedTransaction(transaction: saved.transaction, sheet: saved.sheet)
        return .result(value: receipt, dialog: saved.dialog,
                       snippetIntent: SiriRecordedTransactionSnippetIntent(identifier: prepared.identifier))
    }

    #if os(watchOS)
    @MainActor
    private func requestMissingEditValues() throws {
        if newTitle == nil, newAmount == nil, currencyCode == nil, newDate == nil,
           category == nil, payer == nil, split == nil, beneficiaries?.isEmpty != false {
            let (_, row, _) = try SiriTransactionEditStore.target(transaction.id, in: sheet.id)
            let fields = WatchTransactionEditField.allCases.filter { $0 != .split || row.kind == .expense }
            guard let editField else {
                throw $editField.needsDisambiguationError(among: fields, dialog: "どの項目を変更しますか？")
            }
            switch editField {
            case .title: throw $newTitle.needsValueError("新しい名前は何ですか？")
            case .amount: throw $newAmount.needsValueError("金額をいくらに変更しますか？")
            case .currency: throw $currencyCode.needsValueError("どの通貨に変更しますか？")
            case .date: throw $newDate.needsValueError("日付をいつに変更しますか？")
            case .category: throw $category.needsValueError("どのカテゴリに変更しますか？")
            case .payer: throw $payer.needsValueError("どのメンバーに変更しますか？")
            case .split:
                throw $split.needsDisambiguationError(among: [.off, .all, .selected], dialog: "割り勘をどう変更しますか？")
            }
        }
        if split == .selected, beneficiaries?.isEmpty != false {
            throw $beneficiaries.needsValueError("割り勘の対象にするメンバーを選んでください。")
        }
    }
    #endif
}

#if os(watchOS)
enum WatchTransactionEditField: String, AppEnum {
    case title, amount, currency, date, category, payer, split

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "変更する項目"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .title: "名前", .amount: "金額", .currency: "通貨", .date: "日付",
        .category: "カテゴリ", .payer: "支払者・受取者", .split: "割り勘"
    ]
}
#endif

@available(iOS 27.3, *)
struct SiriEditingMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriEditTransactionIntent>(\.$sheet) var editSheet
    @IntentParameterDependency<SiriEditTransactionIntent>(\.$transaction) var editTarget

    func selectedSheetID(access: IntentSheetAccess) throws -> String? {
        editSheet?.sheet.id ?? editTarget?.transaction.sheetID
    }
}
#endif

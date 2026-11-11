#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import Foundation
import SwiftUI

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriEditTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "登録済みの明細を変更"
    static let description = IntentDescription("直前に登録した明細や、シート内の既存の支出・収入を訂正します。元の明細を選び、変更したい項目だけ指定してください。保存前に変更内容を確認します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "明細を名前で探すシート。直前のカードの明細を指定するときは省略できます。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "変更する明細", description: "直前の登録カードの編集対象、または変更したい既存の支出・収入。")
    var transaction: SiriEditableTransactionEntity
    @Parameter(title: "新しい名前") var newTitle: String?
    @Parameter(title: "新しい金額", description: "明細の通貨で、変更後の金額を正の数で指定します。")
    var newAmount: Double?
    @Parameter(title: "新しい日付") var newDate: Date?
    @Parameter(title: "支払者・受取者", description: "変更後の支払者。収入の場合は受取者。省略すると元の人を維持します。",
               optionsProvider: SiriEditingMemberQuery())
    var payer: SiriSheetMemberEntity?
    @Parameter(title: "割り勘", description: "割り勘を解除、全員で均等割り、または選んだメンバーだけで均等割り。省略すると元の設定を維持します。")
    var split: SiriTransactionSplitChange?
    @Parameter(title: "割り勘の対象", description: "変更後に負担する人全員。支払者も負担するときは含めてください。",
               optionsProvider: SiriEditingMemberQuery())
    var beneficiaries: [SiriSheetMemberEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$transaction) を変更") {
            \.$sheet
            \.$newTitle
            \.$newAmount
            \.$newDate
            \.$payer
            \.$split
            \.$beneficiaries
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriRecordedTransaction> & ProvidesDialog & ShowsSnippetIntent {
        let selected = beneficiaries ?? []
        let prepared = try SiriTransactionEditStore.prepare(
            identifier: transaction.id, sheetIdentifier: sheet?.id ?? transaction.sheetID,
            title: newTitle, amount: newAmount, date: newDate, payer: payer,
            split: split ?? (selected.isEmpty ? .unchanged : .selected), beneficiaries: selected)
        let changes = prepared.changes.map { String(localized: "\($0.label)：\($0.before) → \($0.after)") }
            .joined(separator: "\n")
        let prompt = IntentDialog("「\(prepared.sheetName)」の「\(prepared.transactionTitle)」を変更しますか？\n\(changes)")
        try await requestConfirmation(actionName: .custom(acceptLabel: "アップデート", acceptAlternatives: ["変更を保存"],
                                                          denyLabel: "キャンセル", denyAlternatives: []),
                                      dialog: prompt, showDialogAsPrompt: true) {
            SiriExpenseCardView(recorded: prepared.originalReceipt, allowsOpening: false)
        }
        let saved = try SiriTransactionEditStore.commit(prepared)
        let receipt = SiriRecordedTransaction(transaction: saved.transaction, sheet: saved.sheet)
        return .result(value: receipt, dialog: saved.dialog,
                       snippetIntent: SiriRecordedTransactionSnippetIntent(identifier: prepared.identifier))
    }
}

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

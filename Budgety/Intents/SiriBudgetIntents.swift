// The Siri AI tool trait was introduced in the iOS 27.3 App Intents SDK.
#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriRecordExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "シートに支出を記録"
    static let description = IntentDescription("シートに支出を記録して明細を表示します。共有メンバーやバーチャルメンバーがいるときは、支払った人と、全員または指定した人での均等割りを設定できます。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "この支出を記録する家計簿または旅行などのシート。")
    var sheet: ExpenseSheetEntity

    @Parameter(title: "金額", description: "実際に支払った正の金額。シートの通貨には換算しません。発話に円などの単位が付いていれば支払通貨も設定します。")
    var amount: Double

    @Parameter(title: "支払通貨", description: "金額に付いた通貨を指定します。ドル建てシートでも「1,200円」はJPY、「15ユーロ」はEUR。通貨が言われなかった場合だけ省略します。",
               optionsProvider: SiriCurrencyOptions())
    var currencyCode: String?

    @Parameter(title: "支出名", description: "「ランチ代」「駅までのバス代」など、利用者が話した支出の名前。指定された名前のまま記録します。")
    var expenseTitle: String?

    @Parameter(title: "支払日", description: "支出の日付。省略すると今日になります。")
    var date: Date?

    @Parameter(title: "支払者", description: "このシートで実際に支払ったメンバー。省略すると自分になります。",
               optionsProvider: SiriRecordingMemberQuery())
    var payer: SiriSheetMemberEntity?
    @Parameter(title: "全員で割り勘", description: "全員で均等に負担する場合にオンにします。対象を個別指定する場合は省略します。")
    var splitAll: Bool?
    @Parameter(title: "割り勘の対象", description: "費用を負担する全メンバー。「自分とあかりで半分ずつ」の場合は両者を指定します。省略して全員で割り勘もオフなら支払者だけが負担します。",
               optionsProvider: SiriRecordingMemberQuery())
    var beneficiaries: [SiriSheetMemberEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) に \(\.$amount) の支出を追加") {
            \.$expenseTitle
            \.$date
            \.$currencyCode
            \.$payer
            \.$splitAll
            \.$beneficiaries
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriRecordedTransaction> & ProvidesDialog & ShowsSnippetIntent {
        try await SiriTransactionRecording.record(.expense, sheet: sheet, amount: amount, title: expenseTitle,
                                                  date: date, currencyCode: currencyCode, payer: payer, splitAll: splitAll ?? false,
                                                  beneficiaries: beneficiaries ?? [])
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriRecordIncomeIntent: AppIntent {
    static let title: LocalizedStringResource = "収入を追加"
    static let description = IntentDescription("給与やお小遣い、売上など、受け取った金額を指定したBudgetyのシートに収入として1件記録し、その明細を表示します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "収入を記録するシート。")
    var sheet: ExpenseSheetEntity
    @Parameter(title: "金額", description: "受け取った、0より大きい金額。")
    var amount: Double
    @Parameter(title: "通貨", description: "金額に付いた通貨。シートの既定通貨と違っても「円」はJPY、「米ドル」はUSDを指定します。金額の単位を省略した場合だけシートの通貨を使います。",
               optionsProvider: SiriCurrencyOptions())
    var currencyCode: String?
    @Parameter(title: "収入名", description: "「給与」「お小遣い」など、利用者が指定した収入の名前。")
    var incomeTitle: String?
    @Parameter(title: "受取日", description: "収入を受け取った日。省略時は今日の日付を使います。")
    var date: Date?
    @Parameter(title: "受取者", description: "このシートで収入を受け取ったメンバー。省略すると自分になります。",
               optionsProvider: SiriRecordingMemberQuery())
    var recipient: SiriSheetMemberEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) に \(\.$amount) の収入を追加") {
            \.$incomeTitle
            \.$date
            \.$currencyCode
            \.$recipient
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriRecordedTransaction> & ProvidesDialog & ShowsSnippetIntent {
        try await SiriTransactionRecording.record(.income, sheet: sheet, amount: amount, title: incomeTitle,
                                                  date: date, currencyCode: currencyCode, payer: recipient)
    }
}

@available(iOS 27.3, *)
private enum SiriTransactionRecording {
    @MainActor
    static func record(_ kind: TransactionKind, sheet: ExpenseSheetEntity, amount: Double, title: String?,
                       date: Date?, currencyCode: String?, payer: SiriSheetMemberEntity?,
                       splitAll: Bool = false, beneficiaries: [SiriSheetMemberEntity] = []) async throws
        -> some IntentResult & ReturnsValue<SiriRecordedTransaction> & ProvidesDialog & ShowsSnippetIntent {
        let saved = try await AddExpenseIntent.recordTransaction(sheet: sheet, kind: kind, amount: amount,
                                                                 title: title, date: date ?? .now, currencyCode: currencyCode,
                                                                 payer: payer, splitAll: splitAll, beneficiaries: beneficiaries)
        let receipt = SiriRecordedTransaction(transaction: saved.transaction, sheet: saved.sheet)
        let identifier = saved.transaction.objectID.uriRepresentation().absoluteString
        return .result(value: receipt, dialog: saved.dialog,
                       snippetIntent: SiriRecordedTransactionSnippetIntent(identifier: identifier))
    }
}

@available(iOS 27.3, *)
extension SiriRecordedTransaction {
    @MainActor
    init(transaction: Expense, sheet: ExpenseSheet) {
        let ids = transaction.beneficiaryIDList
        let isSplit = transaction.kind == .expense && !ids.isEmpty && !(ids.count == 1 && ids.first == transaction.payerProfileID)
        let names = isSplit ? ids.map { sheet.memberDisplayInfo(for: $0).name } : []
        self.init(sheetName: sheet.displayName,
                  row: .from(transaction, in: sheet, isSoloSheet: !sheet.hasAcceptedOtherMembers()),
                  kindName: transaction.kind.label, sheetSymbol: sheet.displaySymbol, sheetColorHex: sheet.displayColorHex,
                  splitMemberNames: names.isEmpty ? nil : names)
    }
}

@available(iOS 27.3, *)
struct SiriRecordedTransactionSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "追加した明細を表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "明細の識別子") var identifier: String

    init() {}
    init(identifier: String) { self.identifier = identifier }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        // Siri can request the same view again. Only read the saved transaction here.
        let viewContext = PersistenceController.shared.container.viewContext
        let transaction = try? IntentSheetAccess(checking: viewContext).transactionForDisplay(identifier: identifier)
        return .result {
            if let transaction, let sheet = transaction.sheet {
                SiriExpenseCardView(recorded: SiriRecordedTransaction(transaction: transaction, sheet: sheet))
            } else {
                Text("この明細は現在表示できません。")
            }
        }
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriMonthlySpendingIntent: AppIntent {
    static let title: LocalizedStringResource = "シートの支出額を確認"
    static let description = IntentDescription("「今日の支出はいくら？」なら今日1日だけ、「今月はいくら？」なら今月について、シートの支出額を既定通貨で返します。明細カードは含みません。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "集計したいシート。省略すると最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?

    @Parameter(title: "対象月", description: "2026年5月など年月だけが指定されたときの月。「今日」や日付を含む質問は対象月に設定しません。")
    var month: Date?
    @Parameter(title: "対象日", description: "11月11日など、特定の1日について尋ねられたときの日付。")
    var day: Date?
    @Parameter(title: "検索期間", description: "「今日の支出は？」は今日、「昨日」は昨日、「今月」は今月、「先月」は先月。日付も期間も省略すると今月を集計します。")
    var period: SiriExpensePeriod?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの支出を集計しますか？")
        }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let record = try access.resolve(sheetID)
        let scope = SiriExpenseSearchFilter(expenseName: nil, month: month, day: day, period: period).scope
        let totals = record.convertedTotals { expense in
            guard expense.kind == .expense, !expense.isSkipped else { return false }
            guard let interval = scope.interval else { return true }
            guard let paidOn = expense.date else { return false }
            return interval.start <= paidOn && paidOn < interval.end
        }
        let amount = CurrencyCatalog.format(totals.expense, code: record.resolvedDefaultCurrencyCode)
        let periodLabel = scope.label
        let report: LocalizedStringResource
        if totals.missing.isEmpty {
            report = "「\(record.displayName)」の\(periodLabel)の支出は\(amount)です。"
        } else {
            let currencies = totals.missing.sorted().joined(separator: ", ")
            report = "「\(record.displayName)」の\(periodLabel)の支出は\(amount)です。為替レートを取得できない通貨（\(currencies)）の明細は合計に含まれていません。"
        }
        return .result(value: String(localized: report), dialog: IntentDialog(report))
    }
}
#endif

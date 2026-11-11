// The Siri AI tool trait was introduced in the iOS 27.3 App Intents SDK.
#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriRecordExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "シートに支出を記録"
    static let description = IntentDescription("指定したBudgetyのシートに支出を1件記録します。通貨を省略するとシートの既定通貨、日付を省略すると今日の日付を使います。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "この支出を記録する家計簿または旅行などのシート。")
    var sheet: ExpenseSheetEntity

    @Parameter(title: "金額", description: "実際に支払った、0より大きい金額。")
    var amount: Double

    @Parameter(title: "支払通貨", description: "通貨の指定があれば、日本円はJPY、米ドルはUSDのようにISO通貨コードで指定します。通貨の指定がない場合は省略します。")
    var currencyCode: String?

    @Parameter(title: "支出名", description: "「ランチ代」「駅までのバス代」など、利用者が話した支出の名前。指定された名前のまま記録します。")
    var expenseTitle: String?

    @Parameter(title: "支払日", description: "支出の日付。省略すると今日になります。")
    var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = try await AddExpenseIntent.record(sheet: sheet, amount: amount,
                                                       title: expenseTitle, date: date ?? .now, currencyCode: currencyCode)
        return .result(dialog: dialog)
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriMonthlySpendingIntent: AppIntent {
    static let title: LocalizedStringResource = "シートの月間支出を確認"
    static let description = IntentDescription("シート全体の月間支出の合計を、シートの既定通貨で返します。個別の支出名や明細は含みません。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "集計したいシート。省略すると最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?

    @Parameter(title: "対象月", description: "2026年5月など年月を指定されたとき、その月に含まれる日付。")
    var month: Date?
    @Parameter(title: "検索期間", description: "「今月」「先月」「全期間」の指定。対象月と検索期間を省略すると今月の合計になります。")
    var period: SiriExpensePeriod?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの支出を集計しますか？")
        }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let record = try access.resolve(sheetID)
        let calendar = Calendar.current
        let date = month ?? (period ?? .thisMonth).month(relativeTo: .now, calendar: calendar)
        let totals = record.convertedTotals { expense in
            guard expense.kind == .expense, !expense.isSkipped else { return false }
            guard let date else { return true }
            guard let paidOn = expense.date else { return false }
            return calendar.isDate(paidOn, equalTo: date, toGranularity: .month)
        }
        let amount = CurrencyCatalog.format(totals.expense, code: record.resolvedDefaultCurrencyCode)
        let periodLabel = date?.formatted(.dateTime.year().month(.wide)) ?? String(localized: "全期間")
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

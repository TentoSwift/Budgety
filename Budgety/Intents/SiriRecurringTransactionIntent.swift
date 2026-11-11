#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, *)
nonisolated extension TransactionKind: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "種別"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.expense: "支出", .income: "収入"]
}

@available(iOS 27.3, *)
nonisolated extension RecurrenceFrequency: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "頻度"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .daily: "毎日", .weekly: "毎週", .monthly: "毎月", .yearly: "毎年"
    ]
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriRecurringTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "定期収入・定期支出を設定"
    static let description = IntentDescription("毎月の給与や家賃、毎週の交通費など、繰り返す収入や支出をシートに登録します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート") var sheet: ExpenseSheetEntity
    @Parameter(title: "種別") var kind: TransactionKind
    @Parameter(title: "名前") var transactionTitle: String
    @Parameter(title: "金額") var amount: Double
    @Parameter(title: "通貨", description: "金額に付いた通貨。省略するとシートの既定通貨を使います。",
               optionsProvider: SiriCurrencyOptions()) var currencyCode: String?
    @Parameter(title: "頻度") var frequency: RecurrenceFrequency
    @Parameter(title: "間隔", description: "隔週なら2、毎週なら1。省略時は1です。") var interval: Int?
    @Parameter(title: "開始日", description: "最初の発生日。毎月25日なら、初回の25日を指定します。省略時は今日です。")
    var startDate: Date?
    @Parameter(title: "終了日", description: "最後に発生できる日。期限がないときは省略します。") var endDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let target = try access.resolve(sheet.id)
        let name = transactionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppIntentError.emptyTitle }
        guard let value = CurrencyCatalog.transactionAmount(amount) else { throw AppIntentError.invalidAmount }
        let currency: String
        if let currencyCode {
            guard let code = CurrencyCatalog.transactionCurrencyCode(for: currencyCode) else { throw AppIntentError.unsupportedCurrency }
            currency = code
        } else {
            currency = target.resolvedDefaultCurrencyCode
        }
        let step = interval ?? 1
        guard (1...60).contains(step) else { throw ScheduleError.invalidInterval }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate ?? .now)
        let end = endDate.map { calendar.startOfDay(for: $0) }
        if let end, end.compare(start) == .orderedAscending { throw ScheduleError.invalidDates }

        let category = CategoryHistorySuggestor.suggest(title: name, kind: kind, in: target)
        try Task.checkCancellation()
        try QuickIntentLogic.saveRecurringRule(in: target, context: access.context, kind: kind, title: name, amount: value,
                                              currency: currency, category: category?.name, frequency: frequency,
                                              interval: Int32(step), start: start, end: end)
        let amountLabel = "\(value.formatted(.number.precision(.fractionLength(0...38)))) \(currency)"
        let schedule = frequency.summary(interval: step)
        let beginning = start.formatted(date: .abbreviated, time: .omitted)
        let dates = end.map { "\(beginning) – \($0.formatted(date: .abbreviated, time: .omitted))" } ?? beginning
        let report = String(localized: "「\(target.displayName)」に定期\(kind.label)「\(name)」を設定しました。\(amountLabel) · \(schedule) · \(dates)")
        return .result(value: report, dialog: IntentDialog("\(report)"))
    }

    private enum ScheduleError: Error, CustomLocalizedStringResourceConvertible {
        case invalidInterval, invalidDates
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .invalidInterval: "繰り返しの間隔は1から60の整数を指定してください。"
            case .invalidDates: "終了日は開始日以降を指定してください。"
            }
        }
    }
}
#endif

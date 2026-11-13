#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriBudgetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "予算の残額と使用率を確認"
    static let description = IntentDescription("「予算は？」「今月の予算はあといくら？」「予算を超えている？」など、シートの月予算を尋ねられたときに使います。予算上限、残額、使用率と、予算未設定の場合はその状態を返します。", searchKeywords: ["残り予算", "予算残額", "月予算", "予算使用率"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "対象月", description: "省略すると今月。予算は月単位です。") var month: Date?
    @Parameter(title: "カテゴリ名", description: "予算の確認に添える支出額だけを絞ります。月予算の残額と使用率はシート全体で計算します。") var categoryName: String?
    @Parameter(title: "支払通貨", description: "予算の確認に添える支出額だけを元の支払通貨で絞ります。ドル払いだけならUSD。月予算の残額と使用率はシート全体で計算します。", optionsProvider: SiriCurrencyOptions()) var sourceCurrency: String?
    @Parameter(title: "予算の表示通貨", description: "月予算と残額を表示する通貨。省略時はシートの基準通貨。", optionsProvider: SiriCurrencyOptions()) var targetCurrency: String?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) の \(\.$month) の月予算の残額と使用率を確認") {
            \.$targetCurrency
            \.$categoryName
            \.$sourceCurrency
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetIntent {
        let result = try await report()
        return .result(value: result.text, dialog: IntentDialog("\(result.text)"), snippetIntent: SiriReadReportSnippetIntent(budget: self, sheetID: result.sheetID))
    }

    @MainActor
    func report() async throws -> (sheetID: String, text: String) {
        let id = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの予算を確認しますか？")
        }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        // Core Data rows do not retain the private context used for this read.
        defer { withExtendedLifetime(access) {} }
        let record = try access.resolve(id)
        let scope = SiriExpenseSearchFilter(expenseName: nil, month: month ?? .now, period: nil).scope
        let target = try SiriBudgetForecastRead.currency(targetCurrency, fallback: record.resolvedDefaultCurrencyCode)
        let source = try sourceCurrency.map { try SiriBudgetForecastRead.currency($0, fallback: target) }
        let allItems = SiriBudgetForecastRead.items(sheet: record, interval: scope.interval!, future: false).filter { $0.kind == .expense }
        let items = allItems.filter { SiriBudgetForecastRead.matches($0, category: categoryName, source: source) }
        let total = SiriBudgetForecastRead.total(items, target: target)
        let budgetTotal = SiriBudgetForecastRead.total(allItems, target: target)
        let amount = CurrencyCatalog.format(total.amount, code: target)
        let filterLabel = [categoryName, source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・")
        let context = "「\(record.displayName)」\(scope.label)"
        var report: String
        if let budget = record.resolvedMonthlyBudget,
           let limit = FXRatesService.shared.convert(budget, from: record.resolvedDefaultCurrencyCode, to: target), limit > 0 {
            let usage = SiriBudgetUsage(spent: budgetTotal.amount, limit: limit)
            let remaining = CurrencyCatalog.format(abs(usage.remaining), code: target)
            report = usage.remaining >= 0 ? "\(context)の予算は残り\(remaining)です。" : "\(context)の予算を\(remaining)超過しています。"
            let percentage = usage.percentage.formatted(.number.precision(.fractionLength(0...1)))
            report += "\n月予算　\(CurrencyCatalog.format(limit, code: target))"
            report += "\n使用額　\(CurrencyCatalog.format(budgetTotal.amount, code: target))（\(percentage)%）"
        } else if record.resolvedMonthlyBudget == nil {
            report = "\(context)の月予算は未設定です。\n使用額　\(CurrencyCatalog.format(budgetTotal.amount, code: target))"
        } else {
            report = "\(context)の月予算を\(target)に換算できません。"
        }
        if !filterLabel.isEmpty { report += "\n\(filterLabel)の支出　\(amount)" }
        report += SiriBudgetForecastRead.missingWarning(budgetTotal.missing.union(total.missing))
        if !budgetTotal.missing.isEmpty { report += " 残額と使用率は換算できた支出だけによる参考値です。" }
        let response = report
        return (id, response)
    }
}

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriRecurringForecastIntent: AppIntent {
    static let title: LocalizedStringResource = "定期収支の予定を確認"
    static let description = IntentDescription("来月のサブスク、毎月ドルで払っているもの、定期収入や定期支出の次の予定を確認します。未確定の予定と保存済みの定期明細を区別し、スキップや個別変更も反映します。登録済みの定期設定から予測し、新しい明細は作りません。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "対象月", description: "省略すると来月の予定。") var month: Date?
    @Parameter(title: "表示件数", description: "「直近3件」など表示する予定の数。") var limit: Int?
    @Parameter(title: "すべての予定を表示") var showAll: Bool?
    @Parameter(title: "次回のみ", description: "次の支払日・受取日を調べるときにオン。今日から1年以内の各定期項目の次回を表示します。") var nextOnly: Bool?
    @Parameter(title: "開始日") var startDate: Date?
    @Parameter(title: "終了日", description: "この日を含みます。") var endDate: Date?
    @Parameter(title: "名前", description: "登録済みの定期項目名。サブスクという名前に限らず、全定期支出を調べるなら省略します。") var transactionName: String?
    @Parameter(title: "カテゴリ名") var categoryName: String?
    @Parameter(title: "種別", description: "省略すると収入と支出の両方。") var kind: TransactionKind?
    @Parameter(title: "頻度", description: "「毎月ドルで払うもの」なら毎月。") var frequency: RecurrenceFrequency?
    @Parameter(title: "支払通貨", optionsProvider: SiriCurrencyOptions()) var sourceCurrency: String?
    @Parameter(title: "表示通貨", optionsProvider: SiriCurrencyOptions()) var targetCurrency: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetIntent {
        let result = try await report()
        return .result(value: result.text, dialog: IntentDialog("\(result.text)"), snippetIntent: SiriReadReportSnippetIntent(forecast: self, sheetID: result.sheetID))
    }

    @MainActor
    func report() async throws -> (sheetID: String, text: String) {
        let id = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートの定期予定を確認しますか？")
        }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        // Core Data rows do not retain the private context used for this read.
        defer { withExtendedLifetime(access) {} }
        let record = try access.resolve(id)
        let calendar = Calendar.current
        let anchor = month ?? startDate ?? calendar.date(byAdding: .month, value: 1, to: .now) ?? .now
        let monthRange = calendar.dateInterval(of: .month, for: anchor)!
        let start = startDate.map { calendar.startOfDay(for: $0) } ?? (nextOnly == true ? calendar.startOfDay(for: .now) : monthRange.start)
        let end = endDate.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) } ?? (nextOnly == true ? calendar.date(byAdding: .year, value: 1, to: start)! : monthRange.end)
        guard start < end else { throw ForecastError.invalidDates }
        if let limit, limit < 1 { throw ForecastError.invalidCount }
        let target = try SiriBudgetForecastRead.currency(targetCurrency, fallback: record.resolvedDefaultCurrencyCode)
        let source = try sourceCurrency.map { try SiriBudgetForecastRead.currency($0, fallback: target) }
        let rules = record.recurringRules as? Set<RecurringRule> ?? []
        let ruleIDs = Set(rules.filter { !$0.isDeleted && (frequency == nil || $0.resolvedFrequency == frequency) }.compactMap(\.id))
        let term = TransactionSearchTerm(transactionName ?? "")
        var items = SiriBudgetForecastRead.items(sheet: record, interval: DateInterval(start: start, end: end), future: true)
            .filter { item in
                let ruleID: UUID?
                let matchesName: Bool
                switch item {
                case .expense(let row): ruleID = row.generatedFromRuleID; matchesName = term.isEmpty || term.matchesNameOrCategory(of: row)
                case .occurrence(let row): ruleID = row.ruleID; matchesName = term.isEmpty || term.matchesNameOrCategory(of: row)
                }
                return ruleID.map { frequency == nil || ruleIDs.contains($0) } == true && matchesName
                    && (kind == nil || item.kind == kind) && SiriBudgetForecastRead.matches(item, category: categoryName, source: source)
            }.sorted { $0.date < $1.date }
        if nextOnly == true {
            let families = Dictionary(rules.compactMap { rule in rule.id.map { ($0, rule.recurringSeriesID ?? $0) } }, uniquingKeysWith: { first, _ in first })
            var seen: Set<UUID> = []
            items = items.filter { item in
                let id: UUID?
                switch item { case .expense(let row): id = row.generatedFromRuleID; case .occurrence(let row): id = row.ruleID }
                guard let id else { return false }
                return seen.insert(families[id] ?? id).inserted
            }
        }
        let expenses = SiriBudgetForecastRead.total(items.filter { $0.kind == .expense }, target: target)
        let incomes = SiriBudgetForecastRead.total(items.filter { $0.kind == .income }, target: target)
        let dates = "\(start.formatted(date: .abbreviated, time: .omitted))〜\(calendar.date(byAdding: .day, value: -1, to: end)!.formatted(date: .abbreviated, time: .omitted))"
        var report = "「\(record.displayName)」\(dates)の定期収支は\(items.count)件です。支出\(CurrencyCatalog.format(expenses.amount, code: target))、収入\(CurrencyCatalog.format(incomes.amount, code: target))。"
        let visible = items.prefix(showAll == true ? items.count : (limit ?? 3))
        let details = visible.map { item in
            let name: String
            switch item { case .expense(let row): name = row.title ?? ""; case .occurrence(let row): name = row.title }
            return "\(item.date.formatted(date: .abbreviated, time: .omitted))　\(name)　\(item.kind.label) \(CurrencyCatalog.format(item.amountDecimal, code: item.currencyCode))（\(item.isVirtual ? "未確定の予定" : "保存済み")）"
        }
        if !details.isEmpty { report += "\n" + details.joined(separator: "\n") }
        if items.count > visible.count { report += "\nほかに\(items.count - visible.count)件あります。" }
        report += SiriBudgetForecastRead.missingWarning(expenses.missing.union(incomes.missing))
        report += "\n予定額と換算額は定期設定と現在の為替による見込みです。"
        let response = report
        return (id, response)
    }
    private enum ForecastError: Error, CustomLocalizedStringResourceConvertible {
        case invalidDates, invalidCount
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .invalidDates: "開始日と終了日を確認してください。"
            case .invalidCount: "表示件数は1件以上で指定してください。"
            }
        }
    }
}

@available(iOS 27.3, macOS 27.3, *)
@MainActor
private enum SiriBudgetForecastRead {
    static func currency(_ code: String?, fallback: String) throws -> String {
        guard let code else { return fallback }
        guard let normalized = CurrencyCatalog.transactionCurrencyCode(for: code) else { throw AppIntentError.unsupportedCurrency }
        return normalized
    }
    static func items(sheet: ExpenseSheet, interval: DateInterval, future: Bool) -> [LedgerItem] {
        let saved = (sheet.expenses as? Set<Expense> ?? []).filter {
            !$0.isDeleted && !$0.isSkipped && $0.date.map { interval.start <= $0 && $0 < interval.end } == true
        }.map(LedgerItem.expense)
        let pending = RecurringOccurrenceService.virtualOccurrences(for: sheet, in: interval.start...interval.end,
            includeFuture: future, futureHorizon: interval.end, projectUnmaterialized: future).filter { $0.date < interval.end }.map(LedgerItem.occurrence)
        return saved + pending
    }
    static func matches(_ item: LedgerItem, category: String?, source: String?) -> Bool {
        guard source == nil || item.currencyCode.uppercased() == source else { return false }
        let term = TransactionSearchTerm(category ?? "")
        let name: String
        switch item { case .expense(let row): name = row.categoryDisplayName; case .occurrence(let row): name = row.categoryDisplayName }
        return term.isEmpty || term.matchesCategory(name)
    }
    static func total(_ items: [LedgerItem], target: String) -> (amount: Decimal, missing: Set<String>) {
        var amount: Decimal = 0
        var missing: Set<String> = []
        for item in items {
            if let converted = FXRatesService.shared.convert(item.amountDecimal, from: item.currencyCode, to: target) { amount += converted }
            else { missing.insert(item.currencyCode) }
        }
        return (amount, missing)
    }
    static func missingWarning(_ currencies: Set<String>) -> String {
        currencies.isEmpty ? "" : " 為替レートがない通貨（\(currencies.sorted().joined(separator: ", "))）は合計から除外しています。"
    }
}
#endif

// Pure arithmetic shared by the spoken budget metrics.
struct SiriBudgetUsage {
    let spent: Decimal
    let limit: Decimal
    var remaining: Decimal { limit - spent }
    var percentage: Double { limit > 0 ? NSDecimalNumber(decimal: spent / limit).doubleValue * 100 : 0 }
}

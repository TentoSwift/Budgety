#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation

/// Source filters apply to the recorded currency. The display currency only affects valuation.
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriLedgerCurrency: Sendable {
    let groupByOriginal: Bool
    let targetCurrency: String?
    let sourceCurrency: String?
    let foreignOnly: Bool

    nonisolated init() {
        groupByOriginal = false
        targetCurrency = nil
        sourceCurrency = nil
        foreignOnly = false
    }

    @MainActor
    init(groupByOriginal: Bool = false, targetCurrency: String? = nil, sourceCurrency: String? = nil,
         foreignOnly: Bool = false) throws {
        self.groupByOriginal = groupByOriginal
        self.targetCurrency = try targetCurrency.map { try Self.code($0) }
        self.sourceCurrency = try sourceCurrency.map { try Self.code($0) }
        self.foreignOnly = foreignOnly
    }

    var filterLabel: String? {
        if let sourceCurrency { return String(localized: "\(sourceCurrency)で記録") }
        return foreignOnly ? String(localized: "外貨のみ") : nil
    }

    func periodLabel(_ period: String) -> String {
        [period, filterLabel].compactMap { $0 }.joined(separator: "・")
    }

    @MainActor
    private static func code(_ input: String) throws -> String {
        if let code = CurrencyCatalog.transactionCurrencyCode(for: input) { return code }
        // A legacy row can still be filtered and reported in its original ISO currency.
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Locale.Currency.isoCurrencies.contains(where: { $0.identifier == code }) else {
            throw SiriLedgerCurrencyError.unrecognized(input)
        }
        return code
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
protocol SiriLedgerCurrencyParameters {
    var targetCurrency: String? { get set }
    var sourceCurrency: String? { get set }
    var foreignOnly: Bool? { get set }
    var groupByOriginal: Bool? { get set }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
extension SiriLedgerCurrencyParameters {
    @MainActor
    func currencyOptions() throws -> SiriLedgerCurrency {
        try SiriLedgerCurrency(groupByOriginal: groupByOriginal == true, targetCurrency: targetCurrency,
                               sourceCurrency: sourceCurrency, foreignOnly: foreignOnly == true)
    }

    mutating func restoreCurrencyOptions(_ currency: SiriLedgerCurrency) {
        targetCurrency = currency.targetCurrency
        sourceCurrency = currency.sourceCurrency
        foreignOnly = currency.foreignOnly
        groupByOriginal = currency.groupByOriginal
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
private enum SiriLedgerCurrencyError: Error, CustomLocalizedStringResourceConvertible {
    case unrecognized(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unrecognized(let name): "「\(name)」の通貨を特定できません。通貨名または通貨コードを指定してください。"
        }
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriTransactionValue {
    let original: Decimal
    let source: String
    let target: String
    let converted: Decimal?
    let rate: Decimal?

    @MainActor
    init(_ item: LedgerItem, target: String) {
        original = item.amountDecimal
        source = item.currencyCode.uppercased()
        self.target = target.uppercased()
        let fx = FXRatesService.shared
        // Match the dashboard's cached rates. Settlement has its own historical snapshots.
        converted = fx.convert(original, from: source, to: self.target)
        rate = fx.convert(1, from: source, to: self.target)
    }

    func conversion(presentation: CurrencyFormatStyleConfiguration.Presentation = .isoCode) -> String? {
        guard source != target else { return nil }
        guard let converted else { return String(localized: "\(target)換算不可") }
        return converted.formatted(.currency(code: target).presentation(presentation))
    }
}

/// Reads committed transactions and due, unmaterialized occurrences from an authorized sheet.
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
@MainActor
struct SiriTransactionLedger {
    let count: Int
    let rows: [SiriExpenseCardRow]
    let expenseTotals: [String: Decimal]
    let incomeTotals: [String: Decimal]
    private let items: [(item: LedgerItem, value: SiriTransactionValue)]
    private let currency: String
    private let filterLabel: String?
    private let missingExpense: Set<String>
    private let missingIncome: Set<String>

    var expenseTotal: String { formatted(expenseTotals, missing: missingExpense) }
    var incomeTotal: String { formatted(incomeTotals, missing: missingIncome) }
    var netTotal: String { formatted(netAmounts, missing: missingExpense.union(missingIncome)) }

    func reply(for kind: SiriTransactionSelection, sheetName: String, period: String, member: String?,
               category: String?, name: String?, showAll: Bool) -> String {
        let scope = [sheetName, period, member, category, name, filterLabel].compactMap { $0 }.joined(separator: "・")
        guard count > 0 else { return String(localized: "「\(scope)」に該当する明細はありません。") }

        let locale = Locale.current
        let currencyStyle: CurrencyFormatStyleConfiguration.Presentation =
            locale.language.languageCode == .japanese ? .fullName : .isoCode
        let calendar = Calendar.current
        let now = Date.now
        let monthDay = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        let singleDetail = count == 1 && (kind != .both || name != nil)
        let visible = showAll ? rows[...] : rows.prefix(3)
        let details = zip(visible, items).map { row, entry in
            let (item, value) = entry
            let date: String
            if case .expense(let expense) = item, expense.date == nil {
                date = String(localized: "日付不明")
            } else {
                let sameYear = calendar.isDate(item.date, equalTo: now, toGranularity: .year)
                date = item.date.formatted(sameYear ? monthDay : monthDay.year())
            }
            let original = value.original.formatted(.currency(code: value.source).presentation(currencyStyle))
            let amount = value.conversion(presentation: currencyStyle).map { String(localized: "\(original)（\($0)）") } ?? original
            if singleDetail {
                return String(localized: "\(date)の「\(row.title)」は\(amount)の\(item.kind.label)です。")
            }
            let sign = kind == .both ? (item.kind == .expense ? "−" : "+") : ""
            return String(localized: "• \(date)　\(row.title)（\(sign)\(amount)）")
        }

        if singleDetail, let detail = details.first {
            // The sentence already names the transaction.
            let context = [sheetName, period, member, category, filterLabel].compactMap { $0 }.joined(separator: "・")
            return String(localized: "\(detail)（\(context)）")
        }

        let summary: String
        switch kind {
        case .expense:
            summary = String(localized: "「\(scope)」の支出は\(formatted(expenseTotals, missing: missingExpense, presentation: currencyStyle))です。")
        case .income:
            summary = String(localized: "「\(scope)」の収入は\(formatted(incomeTotals, missing: missingIncome, presentation: currencyStyle))です。")
        case .both:
            let net = formatted(netAmounts, missing: missingExpense.union(missingIncome), presentation: currencyStyle)
            let income = formatted(incomeTotals, missing: missingIncome, presentation: currencyStyle)
            let expense = formatted(expenseTotals, missing: missingExpense, presentation: currencyStyle)
            summary = String(localized: "「\(scope)」の収支は\(net)です。\n収入は\(income)、支出は\(expense)です。")
        }

        var paragraphs = [summary, details.joined(separator: "\n")]
        let remaining = count - visible.count
        if remaining > 0 {
            paragraphs.append(String(localized: "ほかに\(remaining)件あります。"))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private var netAmounts: [String: Decimal] {
        incomeTotals.merging(expenseTotals.mapValues { -$0 }, uniquingKeysWith: +)
    }

    private func formatted(_ totals: [String: Decimal], missing: Set<String>, presentation: CurrencyFormatStyleConfiguration.Presentation = .isoCode) -> String {
        let codes = missing.sorted().joined(separator: ", ")
        if totals.isEmpty && !missing.isEmpty { return String(localized: "換算不可（\(codes)）") }
        let values = totals.isEmpty ? [currency: Decimal.zero] : totals
        let amount = values.sorted { $0.key < $1.key }.map { code, amount in
            amount.formatted(.currency(code: code).presentation(presentation))
        }.formatted(.list(type: .and))
        return missing.isEmpty ? amount : String(localized: "\(amount)（\(codes)のレートがないため除外）")
    }

    static func forEach(sheet: ExpenseSheet, access: IntentSheetAccess, interval: DateInterval?,
                        includeExpenses: Bool, includeIncome: Bool, expenseName: String? = nil, categoryName: String? = nil,
                        relatedMerchantNames: Set<String> = [], currency: SiriLedgerCurrency = .init(), matchesPayer: (LedgerItem) -> Bool = { _ in true },
                        visit: (LedgerItem, SiriTransactionValue) -> Void) throws {
        let record = try access.resolve(sheet.objectID.uriRepresentation().absoluteString)
        try visitItems(in: record, access: access, interval: interval, includeExpenses: includeExpenses, includeIncome: includeIncome,
                       expenseName: expenseName, categoryName: categoryName, relatedMerchantNames: relatedMerchantNames,
                       currency: currency, matchesPayer: matchesPayer, visit: visit)
    }

    /// Give the on-device model only unresolved names from readable transactions in this scope.
    static func relatedMerchantNames(for group: String, sheet: ExpenseSheet, access: IntentSheetAccess,
                                     interval: DateInterval?, includeExpenses: Bool, includeIncome: Bool) async throws -> Set<String> {
        guard LedgerMerchantClassifier.isAvailable, TransactionSearchTerm.spendingGroup(group) != nil else { return [] }
        let term = TransactionSearchTerm.ledgerName(group)
        var dates: [String: Date] = [:]
        try forEach(sheet: sheet, access: access, interval: interval, includeExpenses: includeExpenses, includeIncome: includeIncome) { item, _ in
            let title: String
            switch item {
            case .expense(let expense):
                guard !term.matchesNameOrCategory(of: expense) else { return }
                title = expense.displayTitle
            case .occurrence(let occurrence):
                guard !term.matchesNameOrCategory(of: occurrence) else { return }
                title = occurrence.title
            }
            guard !title.isEmpty, !TransactionSearchTerm.isKnownUnrelatedMerchant(title, for: group) else { return }
            dates[title] = max(dates[title] ?? .distantPast, item.date)
        }
        let candidates = dates.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map(\.key)
        return try await LedgerMerchantClassifier.matchingTitles(for: group, candidates: candidates)
    }

    private static func visitItems(in record: ExpenseSheet, access: IntentSheetAccess, interval: DateInterval?,
                                   includeExpenses: Bool, includeIncome: Bool, expenseName: String?, categoryName: String?,
                                   relatedMerchantNames: Set<String>, currency: SiriLedgerCurrency, matchesPayer: (LedgerItem) -> Bool,
                                   visit: (LedgerItem, SiriTransactionValue) -> Void) throws {
        let base = record.resolvedDefaultCurrencyCode.uppercased()
        let target = currency.targetCurrency ?? base
        let request = NSFetchRequest<Expense>(entityName: "Expense")
        var predicates = [NSPredicate(format: "sheet == %@", record)]
        if let interval {
            predicates.append(NSPredicate(format: "date >= %@ AND date < %@", interval.start as NSDate, interval.end as NSDate))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.fetchBatchSize = 64
        let term = TransactionSearchTerm.ledgerName(expenseName ?? "")
        let category = TransactionSearchTerm(categoryName ?? "")
        func collect(_ item: LedgerItem) {
            guard (item.kind == .expense ? includeExpenses : includeIncome), matchesPayer(item) else { return }
            switch item {
            case .expense(let row):
                guard category.isEmpty || category.matchesCategory(row.categoryDisplayName),
                      term.isEmpty || term.matchesNameOrCategory(of: row) || relatedMerchantNames.contains(row.displayTitle) else { return }
            case .occurrence(let occurrence):
                guard category.isEmpty || category.matchesCategory(occurrence.categoryDisplayName),
                      term.isEmpty || term.matchesNameOrCategory(of: occurrence) || relatedMerchantNames.contains(occurrence.title) else { return }
            }
            let source = item.currencyCode.uppercased()
            guard currency.sourceCurrency.map({ $0 == source }) ?? true, !currency.foreignOnly || source != base else { return }
            visit(item, SiriTransactionValue(item, target: target))
        }
        for row in try access.context.fetch(request) where !row.isSkipped {
            if let editing = access.viewContext.registeredObject(for: row.objectID) as? Expense,
               editing.isDeleted || editing.isSkipped || editing.hasPersistentChangedValues || editing.sheet?.objectID != record.objectID {
                continue
            }
            collect(.expense(row))
        }

        // An occurrence being edited in the foreground must agree with what its detail link can open.
        var changedRules: Set<UUID> = []
        var pendingSlots: [UUID: Set<Date>] = [:]
        if access.viewContext.hasChanges {
            let rules = record.recurringRules as? Set<RecurringRule> ?? []
            var changedFamilies: Set<UUID> = []
            for rule in rules {
                if let live = access.viewContext.registeredObject(for: rule.objectID),
                   live.isDeleted || live.hasPersistentChangedValues, let family = rule.recurringSeriesID {
                    changedFamilies.insert(family)
                }
            }
            let pending = access.viewContext.insertedObjects.union(access.viewContext.updatedObjects)
            for object in pending {
                if let rule = object as? RecurringRule, rule.sheet?.objectID == record.objectID, let family = rule.recurringSeriesID {
                    changedFamilies.insert(family)
                } else if let row = object as? Expense, row.sheet?.objectID == record.objectID,
                          let ruleID = row.generatedFromRuleID, let day = row.scheduledDate ?? row.date {
                    pendingSlots[ruleID, default: []].insert(Calendar.current.startOfDay(for: day))
                }
            }
            changedRules = Set(rules.compactMap { rule in
                guard let family = rule.recurringSeriesID, changedFamilies.contains(family) else { return nil }
                return rule.id
            })
        }
        let range = interval.map { $0.start...$0.end }
        for occurrence in RecurringOccurrenceService.virtualOccurrences(for: record, in: range, includeFuture: false) {
            if let interval, occurrence.date >= interval.end { continue }
            if changedRules.contains(occurrence.ruleID) || pendingSlots[occurrence.ruleID]?.contains(occurrence.scheduledDate) == true {
                continue
            }
            collect(.occurrence(occurrence))
        }
    }

    static func read(sheet: ExpenseSheet, access: IntentSheetAccess, interval: DateInterval?,
                     includeExpenses: Bool, includeIncome: Bool, expenseName: String? = nil, categoryName: String? = nil,
                     relatedMerchantNames: Set<String> = [], allRows: Bool = false, currency: SiriLedgerCurrency = .init(),
                     matchesPayer: (LedgerItem) -> Bool = { _ in true }) throws -> Self {
        let record = try access.resolve(sheet.objectID.uriRepresentation().absoluteString)
        var expenses: [String: Decimal] = [:]
        var income: [String: Decimal] = [:]
        var missingExpense = Set<String>()
        var missingIncome = Set<String>()
        var count = 0
        var newest: [(item: LedgerItem, value: SiriTransactionValue)] = []
        try visitItems(in: record, access: access, interval: interval, includeExpenses: includeExpenses, includeIncome: includeIncome,
                       expenseName: expenseName, categoryName: categoryName, relatedMerchantNames: relatedMerchantNames,
                       currency: currency, matchesPayer: matchesPayer) { item, value in
            count += 1
            let code = currency.groupByOriginal ? value.source : value.target
            if let amount = currency.groupByOriginal ? value.original : value.converted {
                if item.kind == .expense { expenses[code, default: 0] += amount }
                else { income[code, default: 0] += amount }
            } else if item.kind == .expense { missingExpense.insert(value.source) }
            else { missingIncome.insert(value.source) }
            if allRows {
                newest.append((item, value))
            } else {
                let index = newest.firstIndex { isNewer(item, than: $0.item) } ?? newest.count
                if index < 5 {
                    newest.insert((item, value), at: index)
                    if newest.count > 5 { newest.removeLast() }
                }
            }
        }
        if allRows { newest.sort { isNewer($0.item, than: $1.item) } }
        let backing = VirtualRowBacking()
        lazy var isSolo = !record.hasAcceptedOtherMembers()
        let rows: [SiriExpenseCardRow] = newest.enumerated().map { index, entry in
            let (item, value) = entry
            let includePhoto = index < 8
            switch item {
            case .expense(let row):
                return .from(row, in: record, isSoloSheet: isSolo, includePayerPhoto: includePhoto, valuation: value)
            case .occurrence(let occurrence):
                return .from(backing.displayExpense(for: occurrence, sheet: record), in: record, isSoloSheet: isSolo,
                             virtualIdentifier: SiriVirtualExpenseLink.identifier(for: occurrence, in: record), includePayerPhoto: includePhoto, valuation: value)
            }
        }
        return Self(count: count, rows: rows, expenseTotals: expenses, incomeTotals: income,
                    items: newest, currency: currency.targetCurrency ?? record.resolvedDefaultCurrencyCode, filterLabel: currency.filterLabel,
                    missingExpense: missingExpense, missingIncome: missingIncome)
    }

    private static func isNewer(_ item: LedgerItem, than other: LedgerItem) -> Bool {
        if item.date != other.date { return item.date > other.date }
        switch (item, other) {
        case (.expense(let lhs), .expense(let rhs)):
            let left = lhs.createdAt ?? .distantPast
            let right = rhs.createdAt ?? .distantPast
            if left != right { return left > right }
        case (.expense, .occurrence): return true
        case (.occurrence, .expense): return false
        case (.occurrence, .occurrence): break
        }
        return item.id < other.id
    }
}
#endif

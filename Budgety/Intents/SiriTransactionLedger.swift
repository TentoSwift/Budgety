#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation

/// A read-only ledger for Siri. Keep amounts in the original currency of each transaction.
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
@MainActor
struct SiriTransactionLedger {
    let count: Int
    let rows: [SiriExpenseCardRow]
    let expenseTotals: [String: Decimal]
    let incomeTotals: [String: Decimal]
    private let currency: String

    var expenseTotal: String { formatted(expenseTotals) }
    var incomeTotal: String { formatted(incomeTotals) }
    var netTotal: String {
        formatted(incomeTotals.merging(expenseTotals.mapValues { -$0 }, uniquingKeysWith: +))
    }

    private func formatted(_ totals: [String: Decimal]) -> String {
        let values = totals.isEmpty ? [currency: Decimal.zero] : totals
        return values.sorted { $0.key < $1.key }.map { code, amount in
            amount.formatted(.currency(code: code).presentation(.isoCode))
        }.formatted(.list(type: .and))
    }

    static func read(sheet: ExpenseSheet, access: IntentSheetAccess, interval: DateInterval?,
                     includeExpenses: Bool, includeIncome: Bool, expenseName: String? = nil, categoryName: String? = nil,
                     previewOnly: Bool = true,
                     matchesPayer: (LedgerItem) -> Bool = { _ in true }) throws -> Self {
        let record = try access.resolve(sheet.objectID.uriRepresentation().absoluteString)
        let request = NSFetchRequest<Expense>(entityName: "Expense")
        var predicates = [NSPredicate(format: "sheet == %@", record)]
        if let interval {
            predicates.append(NSPredicate(format: "date >= %@ AND date < %@", interval.start as NSDate, interval.end as NSDate))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.fetchBatchSize = 64
        let term = TransactionSearchTerm(expenseName ?? "")
        let category = TransactionSearchTerm(categoryName ?? "")
        var expenses: [String: Decimal] = [:]
        var income: [String: Decimal] = [:]
        var count = 0
        var newest: [LedgerItem] = []
        func collect(_ item: LedgerItem) {
            guard (item.kind == .expense ? includeExpenses : includeIncome), matchesPayer(item) else { return }
            switch item {
            case .expense(let row):
                guard category.isEmpty || category.matchesCategory(row.categoryDisplayName),
                      term.isEmpty || term.matchesNameOrCategory(of: row) else { return }
            case .occurrence(let occurrence):
                guard category.isEmpty || category.matchesCategory(occurrence.categoryDisplayName),
                      term.isEmpty || term.matchesNameOrCategory(of: occurrence) else { return }
            }
            let code = item.currencyCode.uppercased()
            if item.kind == .expense { expenses[code, default: 0] += item.amountDecimal }
            else { income[code, default: 0] += item.amountDecimal }
            count += 1
            guard previewOnly else { newest.append(item); return }
            let index = newest.firstIndex { isNewer(item, than: $0) } ?? newest.count
            if index < 5 {
                newest.insert(item, at: index)
                if newest.count > 5 { newest.removeLast() }
            }
        }
        for row in try access.context.fetch(request) where !row.isSkipped {
            collect(.expense(row))
        }
        let range = interval.map { $0.start...$0.end }
        for occurrence in RecurringOccurrenceService.virtualOccurrences(for: record, in: range, includeFuture: false) {
            if let interval, occurrence.date >= interval.end { continue }
            collect(.occurrence(occurrence))
        }
        if !previewOnly { newest.sort { isNewer($0, than: $1) } }
        let backing = VirtualRowBacking()
        lazy var isSolo = !record.hasAcceptedOtherMembers()
        let rows: [SiriExpenseCardRow] = newest.map { item in
            switch item {
            case .expense(let row):
                return .from(row, in: record, isSoloSheet: isSolo)
            case .occurrence(let occurrence):
                return .from(backing.displayExpense(for: occurrence, sheet: record), in: record, isSoloSheet: isSolo,
                             virtualIdentifier: SiriVirtualExpenseLink.identifier(for: occurrence, in: record))
            }
        }
        return Self(count: count, rows: rows, expenseTotals: expenses, incomeTotals: income,
                    currency: record.resolvedDefaultCurrencyCode)
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

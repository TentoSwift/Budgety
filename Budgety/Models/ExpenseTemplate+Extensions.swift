//
//  ExpenseTemplate+Extensions.swift
//  Expenso
//

import Foundation
import CoreData

extension ExpenseTemplate {
    var displayTitle: String { title?.isEmpty == false ? title! : String(localized: "(無題)") }

    var amountDecimal: Decimal {
        get { (amount ?? 0) as Decimal }
        set { amount = NSDecimalNumber(decimal: newValue) }
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw ?? "") ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var resolvedCurrencyCode: String {
        if let c = currencyCode, !c.isEmpty { return c }
        if let s = sheet?.resolvedDefaultCurrencyCode, !s.isEmpty { return s }
        return CurrencyCatalog.defaultCode
    }

    var beneficiaryIDList: [String] {
        get {
            (beneficiaryProfileIDs ?? "")
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            beneficiaryProfileIDs = cleaned.joined(separator: ",")
        }
    }

    var formattedAmount: String {
        CurrencyCatalog.format(amountDecimal, code: resolvedCurrencyCode)
    }

    /// 同シート内のカテゴリを名前 + kind で引いて返す。
    var resolvedCategory: ExpenseCategory? {
        guard let raw = categoryRaw, !raw.isEmpty,
              let cats = sheet?.categories as? Set<ExpenseCategory> else { return nil }
        return cats.first(where: { $0.name == raw && $0.kind == kind })
            ?? cats.first(where: { $0.name == raw })
    }
}

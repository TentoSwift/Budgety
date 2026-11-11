import CoreData
import SwiftUI

struct SheetBudgetCurrencyChange {
    struct Terms: Equatable {
        let from: String
        let to: String
        let original: Decimal
        let kept: Decimal
    }

    struct Approval {
        let terms: Terms
        let budget: Decimal
    }

    let terms: Terms
    let converted: Decimal?
    private let belowMinimum: Bool

    var keep: Approval { Approval(terms: terms, budget: terms.kept) }
    var convert: Approval? { converted.map { Approval(terms: terms, budget: $0) } }

    /// Returns a quote without modifying the sheet, or applies both draft fields for the caller's single save.
    @MainActor
    static func apply(to sheet: ExpenseSheet, initialCurrency: String, currency: String,
                      initialBudget: String, budget: String, approval: Approval? = nil) -> Self? {
        let from = sheet.resolvedDefaultCurrencyCode
        if approval != nil, from == currency { return nil }
        let changingCurrency = initialCurrency != currency && from != currency
        let editedBudget = initialBudget != budget
        let amount = editedBudget ? Decimal(string: budget) : sheet.monthlyBudgetDecimal
        if !sheet.isInserted, changingCurrency, let original = sheet.monthlyBudgetDecimal, let amount, amount > 0 {
            let terms = Terms(from: from, to: currency, original: original, kept: amount)
            // A synced change can invalidate a visible quote. A rate refresh alone does not change an approved amount.
            guard let approval, approval.terms == terms else { return Self(terms: terms) }
            sheet.monthlyBudgetDecimal = approval.budget
        } else if editedBudget {
            sheet.monthlyBudgetDecimal = amount
        }
        if changingCurrency { sheet.defaultCurrencyCode = currency }
        return nil
    }

    @MainActor
    private init(terms: Terms) {
        self.terms = terms
        guard var result = FXRatesService.shared.convert(terms.original, from: terms.from, to: terms.to),
              !result.isNaN, result > 0 else {
            converted = nil
            belowMinimum = false
            return
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, CurrencyCatalog.fractionDigits(for: terms.to), .plain)
        belowMinimum = rounded == 0
        converted = rounded > 0 ? rounded : nil
    }

    var message: String {
        // A kept amount may contain fractions even if the new currency normally has no minor unit.
        let format = Decimal.FormatStyle.number.precision(.fractionLength(0...38))
        let kept = "\(terms.kept.formatted(format)) \(terms.to)"
        if let converted {
            let old = "\(terms.original.formatted(format)) \(terms.from)"
            let new = "\(converted.formatted(format)) \(terms.to)"
            return String(localized: "現在の月予算は\(old)です。換算すると\(new)、数値を維持すると\(kept)になります。")
        }
        if belowMinimum {
            return String(localized: "換算後の月予算は\(terms.to)の最小単位未満です。数値を維持すると\(kept)になります。")
        }
        return String(localized: "\(terms.from)から\(terms.to)への為替レートがないため、月予算を換算できません。数値を維持すると\(kept)になります。")
    }
}

extension View {
    func sheetBudgetCurrencyAlert(_ pending: Binding<SheetBudgetCurrencyChange?>,
                                  save: @escaping (SheetBudgetCurrencyChange.Approval) -> Void) -> some View {
        alert("月予算も換算しますか？", isPresented: Binding(
            get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }
        ), presenting: pending.wrappedValue) { change in
            if let conversion = change.convert {
                Button("換算して保存") { save(conversion) }
            }
            Button("数値を維持して保存") { save(change.keep) }
            Button("キャンセル", role: .cancel) {}
        } message: { change in
            Text(verbatim: change.message)
        }
    }
}

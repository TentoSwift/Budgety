//
//  SettlementRecord+Extensions.swift
//  Expenso
//
//  「実際に行われた送金」レコード。SettlementCalculator が期間内 Expense から
//  計算する想定送金プランに対して、ユーザーが「送金済み」を確定するための一次データ。
//
//  - fromProfileID → toProfileID に amount (currencyCode) を送った、という事実
//  - SettlementCalculator は balance に逆向き加算して送金後の残額を計算する
//  - 親シートと同じストア (Private / Shared) に置かれ、CKShare zone で同期する
//

import Foundation
import CoreData

extension SettlementRecord {
    var amountDecimal: Decimal {
        get { (amount ?? 0) as Decimal }
        set { amount = NSDecimalNumber(decimal: newValue) }
    }

    /// 通貨コード (空なら親シートの既定 → JPY)
    var resolvedCurrencyCode: String {
        if let c = currencyCode, !c.isEmpty { return c }
        if let s = sheet?.resolvedDefaultCurrencyCode, !s.isEmpty { return s }
        return CurrencyCatalog.defaultCode
    }

    /// 通貨記号付きの金額表示
    var formattedAmount: String {
        CurrencyCatalog.format(amountDecimal, code: resolvedCurrencyCode)
    }
}

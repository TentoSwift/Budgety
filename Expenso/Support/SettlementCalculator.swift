//
//  SettlementCalculator.swift
//  Expenso
//
//  支出群から精算結果を計算する純粋関数群。
//  - 支出のみ対象 (収入はスキップ)
//  - 各 Expense は payer から beneficiaries に均等割りで負担を発生させる
//  - 通貨はシートの既定通貨に FX 換算して合算
//  - 出力: 各メンバーの net 残高 + greedy minimum cash flow に基づく送金提案
//

import Foundation

/// 1 メンバーの net 残高 (= 立て替えた金額 - 自分の負担)。
/// `> 0` なら受け取り、`< 0` なら支払いが必要。
struct MemberBalance: Identifiable, Hashable {
    let profileID: String
    let amount: Decimal
    var id: String { profileID }
    var isCreditor: Bool { amount > 0 }
    var isDebtor: Bool { amount < 0 }
    var isSettled: Bool { amount == 0 }
}

/// 「A → B: ¥X」の送金提案。
struct SettlementTransfer: Identifiable, Hashable {
    let fromProfileID: String
    let toProfileID: String
    let amount: Decimal
    var id: String { "\(fromProfileID)->\(toProfileID):\(amount)" }
}

struct SettlementResult {
    let currencyCode: String
    let balances: [MemberBalance]
    let transfers: [SettlementTransfer]
    /// FX 換算でレートが見つからずスキップした通貨
    let missingRateCurrencies: Set<String>
    /// 計算に使用した支出件数 (収入はカウントされない)
    let includedExpenseCount: Int
}

enum SettlementCalculator {
    /// 主入口: シートに紐づく支出を精算する。
    /// - Parameter dateRange: 集計対象の期間 (両端含む)。`nil` なら全期間。
    @MainActor
    static func calculate(for sheet: ExpenseSheet, in dateRange: ClosedRange<Date>? = nil) -> SettlementResult {
        let target = sheet.resolvedDefaultCurrencyCode
        let fx = FXRatesService.shared
        let allExpenses = (sheet.expenses as? Set<Expense>) ?? []
        let expenses = allExpenses.filter { e in
            guard e.kind == .expense else { return false }
            if let range = dateRange {
                guard let d = e.date else { return false }
                return range.contains(d)
            }
            return true
        }

        // メンバー集合を確定。Expense に出てくる payer/beneficiary もここに含めることで、
        // 既にシートを退出した参加者の残高もきちんと反映される。
        var memberOrder: [String] = sheet.allMemberProfileIDs()
        var memberSet = Set(memberOrder)
        for e in expenses {
            if let p = e.payerProfileID, !p.isEmpty, memberSet.insert(p).inserted {
                memberOrder.append(p)
            }
            for b in e.beneficiaryIDList where memberSet.insert(b).inserted {
                memberOrder.append(b)
            }
        }

        var balances: [String: Decimal] = [:]
        for m in memberOrder { balances[m] = 0 }

        var missing: Set<String> = []
        var includedCount = 0

        for e in expenses {
            let from = e.resolvedCurrencyCode
            guard let converted = fx.convert(e.amountDecimal, from: from, to: target) else {
                missing.insert(from)
                continue
            }
            let beneficiaries = e.resolvedBeneficiaryIDs()
            guard !beneficiaries.isEmpty else { continue }
            // payer 不明 (legacy / インポート) の支出はスキップ
            guard let payer = e.payerProfileID, !payer.isEmpty else { continue }

            let count = Decimal(beneficiaries.count)
            let perShare = roundToCurrency(converted / count, code: target)
            // 端数で converted と完全一致しない場合、payer は perShare * count しか回収できず、
            // 差分は cash 上の損失として吸収する (= 残高は perShare * count で計算)
            let allocatedTotal = perShare * count

            balances[payer, default: 0] += allocatedTotal
            for b in beneficiaries {
                balances[b, default: 0] -= perShare
            }
            includedCount += 1
        }

        let memberBalances: [MemberBalance] = memberOrder.map { id in
            MemberBalance(profileID: id, amount: balances[id] ?? 0)
        }

        let nonZero = memberBalances.filter { !$0.isSettled }
        let transfers = computeMinimumTransfers(balances: nonZero, currencyCode: target)

        return SettlementResult(
            currencyCode: target,
            balances: memberBalances,
            transfers: transfers,
            missingRateCurrencies: missing,
            includedExpenseCount: includedCount
        )
    }

    /// 通貨ごとの最小単位で残高を丸める (JPY/KRW 等は整数、それ以外は小数 2 桁)。
    private static func roundToCurrency(_ value: Decimal, code: String) -> Decimal {
        let scale: Int = ["JPY", "KRW", "VND", "IDR"].contains(code) ? 0 : 2
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, .bankers)
        return output
    }

    /// Greedy 最小回数送金: 大きな debtor と大きな creditor をマッチさせて少送金で精算する。
    /// (理論上の最小回数より多くなる場合があるが、O(N^2 log N) で十分実用的)
    private static func computeMinimumTransfers(balances: [MemberBalance], currencyCode: String) -> [SettlementTransfer] {
        var creditors = balances.filter { $0.isCreditor }
            .map { (id: $0.profileID, amount: $0.amount) }
        var debtors = balances.filter { $0.isDebtor }
            .map { (id: $0.profileID, amount: -$0.amount) }  // 正の数として扱う

        var transfers: [SettlementTransfer] = []
        // 1 通貨単位 (= 丸め誤差) 以下は 0 とみなす
        let epsilon = roundToCurrency(Decimal(1) / Decimal(100), code: currencyCode)

        while !creditors.isEmpty, !debtors.isEmpty {
            creditors.sort { $0.amount > $1.amount }
            debtors.sort { $0.amount > $1.amount }
            var c = creditors[0]
            var d = debtors[0]
            let pay = min(c.amount, d.amount)
            let rounded = roundToCurrency(pay, code: currencyCode)
            if rounded > 0 {
                transfers.append(SettlementTransfer(
                    fromProfileID: d.id,
                    toProfileID: c.id,
                    amount: rounded
                ))
            }
            c.amount -= pay
            d.amount -= pay
            if c.amount <= epsilon { creditors.removeFirst() } else { creditors[0] = c }
            if d.amount <= epsilon { debtors.removeFirst() } else { debtors[0] = d }
        }
        return transfers
    }
}

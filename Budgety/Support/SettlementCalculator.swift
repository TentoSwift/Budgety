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
import CloudKit

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

        // 「自分」の複数 ID (旧 userRecordName / canonical / cross-device で書かれた別 ID)
        // を一つの canonical に畳む。これで履歴的に複数 ID で記録された自分の expense が
        // 一人として正しく集計される。
        let share: CKShare? = {
            #if !os(watchOS)
            return ShareCoordinator.shared.existingShare(for: sheet)
            #else
            return nil
            #endif
        }()
        // 自分の ID 集合 = canonicalSelfIDs (canonical + 旧 userRecordName + knownSelfIDs)
        // 名前 / 写真ベースのヒューリスティックは別アカウント誤検出を生むため使わない。
        // 重複は精算画面の context menu 「自分に統合」で明示的に解消 → 統合された ID は
        // knownSelfIDs に記憶され、以後自動的に self として扱われる。
        let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
        let selfCanonical = UserProfileStore.shared.canonicalSelfID(forShare: share)
            ?? UserProfileStore.shared.userRecordName
            ?? ""
        let normalize: (String) -> String = { pid in
            (!selfCanonical.isEmpty && selfIDs.contains(pid)) ? selfCanonical : pid
        }

        // メンバー集合 = 「現在のシートの参加者」だけ。
        // - 自分の canonical (sheet が無くても userRecordName fallback)
        // - 同シート配下の ParticipantProfile から拾った recordName
        // Expense.payerProfileID が現参加者に無い (= 退出した参加者 / 旧 ID) 支出は
        // この精算では対象外として skip する。
        var memberOrder: [String] = []
        var memberSet = Set<String>()
        if !selfCanonical.isEmpty,
           memberSet.insert(selfCanonical).inserted {
            memberOrder.append(selfCanonical)
        }
        let pps = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
        for pp in pps.sorted(by: { ($0.displayName ?? "") < ($1.displayName ?? "") }) {
            guard let rn = pp.recordName, !rn.isEmpty,
                  rn != "_defaultOwner_", rn != "__defaultOwner__" else { continue }
            let nid = normalize(rn)
            if memberSet.insert(nid).inserted { memberOrder.append(nid) }
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
            // 受益者 = expense.payerProfileID 由来の current 参加者のみ。
            // 範囲外 ID は除外。残りが空なら skip。
            let beneficiaries = e.resolvedBeneficiaryIDs()
                .map(normalize)
                .filter { memberSet.contains($0) }
            guard !beneficiaries.isEmpty else { continue }
            // payer 不明 (legacy / インポート) や 現参加者に居ない payer はスキップ
            guard let rawPayer = e.payerProfileID, !rawPayer.isEmpty else { continue }
            let payer = normalize(rawPayer)
            guard memberSet.contains(payer) else { continue }

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

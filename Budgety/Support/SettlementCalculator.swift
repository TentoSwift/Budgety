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
import CoreData
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
    /// 計算過程のデバッグ情報 (DEBUG ビルドでのみ populate)
    let debugInfo: SettlementDebugInfo?
}

/// 精算ロジックのデバッグ情報。各 expense の集計過程を可視化する。
struct SettlementDebugInfo {
    /// 現在のシートのメンバー集合 (= 精算対象になる ID)
    let memberSet: [String]
    /// 自分の canonical
    let selfCanonical: String
    /// 自分とみなす ID 集合 (canonicalSelfIDs)
    let selfIDs: [String]
    /// 各 expense の集計過程
    let expenseRows: [ExpenseRow]

    struct ExpenseRow {
        let id: String  // objectID URI など
        let date: Date
        let title: String
        let rawPayer: String
        let normalizedPayer: String
        let amount: Decimal
        let currencyCode: String
        let convertedAmount: Decimal?
        let rawBeneficiaries: [String]
        let normalizedBeneficiaries: [String]
        let perShare: Decimal?
        let included: Bool
        let skipReason: String?
    }
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
        // ShareCalendarApp 方式: CKShare の participants から取れる URN を真実として
        // メンバーを構築する。email/phone ベースの旧 ID や PP.recordName の重複は
        // ここで全部 URN に畳む (= 同じ人が複数行に分裂しない)。
        let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
        // selfCanonical は必ず URN を使う (PublicProfileSync のキーと一致するため)
        let selfCanonical = UserProfileStore.shared.userRecordName
            ?? UserProfileStore.shared.canonicalSelfID(forShare: share)
            ?? ""
        let selfMemberID = UserProfileStore.shared.selfMemberID
        let selfEmailID: String? = {
            if let e = UserProfileStore.shared.selfEmail?.lowercased(), !e.isEmpty {
                return "email:" + e
            }
            return nil
        }()

        // ── email/旧URN → URN マッピングを CKShare から構築 ──
        // share.participants[i].userIdentity から (URN, email) のペアを取って
        // 旧 "email:foo@bar.com" 形式 ID から正しい URN を逆引きできるようにする。
        var emailToURN: [String: String] = [:]
        if let share = share {
            for p in share.participants {
                guard let urn = p.userIdentity.userRecordID?.recordName,
                      !urn.isEmpty,
                      !UserProfileStore.isSelfPlaceholderRecordName(urn) else { continue }
                if let email = p.userIdentity.lookupInfo?.emailAddress?.lowercased(),
                   !email.isEmpty {
                    emailToURN["email:" + email] = urn
                }
            }
        }
        if let selfEmailID, !selfCanonical.isEmpty {
            emailToURN[selfEmailID] = selfCanonical
        }

        /// "ID を URN に正規化":
        /// - 自分の全 ID は selfCanonical に
        /// - email:foo は emailToURN マップで URN に置換
        /// - それ以外はそのまま
        let normalize: (String) -> String = { pid in
            if !selfCanonical.isEmpty, selfIDs.contains(pid) { return selfCanonical }
            if !selfCanonical.isEmpty, selfEmailID != nil, pid == selfEmailID { return selfCanonical }
            if let urn = emailToURN[pid] { return urn }
            return pid
        }
        /// Expense の payer を解決:
        /// 1. canonicalSelfIDs / selfEmail にあれば self
        /// 2. Expense.payerMemberID == 自分の selfMemberID も self
        /// 3. email→URN マップに該当すれば URN に
        /// 4. それ以外は raw のまま
        let resolvePayer: (Expense) -> String? = { e in
            guard let pid = e.payerProfileID, !pid.isEmpty else { return nil }
            if !selfCanonical.isEmpty {
                if selfIDs.contains(pid) { return selfCanonical }
                if let selfEmailID, pid == selfEmailID { return selfCanonical }
                if let mid = selfMemberID, e.payerMemberID == mid { return selfCanonical }
            }
            if let urn = emailToURN[pid] { return urn }
            return pid
        }

        // メンバー集合 = CKShare.participants の URN + 自分 + PP の URN
        // ShareCalendarApp と同様、URN ベースで dedup。
        var memberOrder: [String] = []
        var memberSet = Set<String>()
        if !selfCanonical.isEmpty,
           memberSet.insert(selfCanonical).inserted {
            memberOrder.append(selfCanonical)
        }
        // CKShare の他参加者 (URN) を優先で追加 (= source of truth)
        if let share = share {
            for p in share.participants {
                guard let urn = p.userIdentity.userRecordID?.recordName,
                      !urn.isEmpty,
                      !UserProfileStore.isSelfPlaceholderRecordName(urn),
                      memberSet.insert(urn).inserted else { continue }
                memberOrder.append(urn)
            }
        }
        // PP からも補完 (CKShare 未取得時のフォールバック、normalize 経由で email→URN)
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
        var debugRows: [SettlementDebugInfo.ExpenseRow] = []

        for e in expenses {
            let from = e.resolvedCurrencyCode
            let rawPayer = e.payerProfileID ?? ""
            let rawBeneficiaries = e.resolvedBeneficiaryIDs()
            let convertedOpt = fx.convert(e.amountDecimal, from: from, to: target)
            var included = false
            var skipReason: String? = nil
            var normalizedPayer: String = ""
            var normalizedBeneficiaries: [String] = []
            var perShareOpt: Decimal? = nil

            // 1) FX 換算
            guard let converted = convertedOpt else {
                missing.insert(from)
                skipReason = "FX レート未取得 (\(from))"
                debugRows.append(.init(
                    id: e.objectID.uriRepresentation().absoluteString,
                    date: e.date ?? .now, title: e.displayTitle,
                    rawPayer: rawPayer, normalizedPayer: "",
                    amount: e.amountDecimal, currencyCode: from,
                    convertedAmount: nil,
                    rawBeneficiaries: rawBeneficiaries, normalizedBeneficiaries: [],
                    perShare: nil, included: false, skipReason: skipReason))
                continue
            }

            // 2) 受益者の正規化 + 現参加者フィルタ + dedup
            // dedup は必須: 旧 URN と canonical が同じ人物にマップされる場合に
            // 同じ人を 2 回カウントしないため。
            do {
                var seen = Set<String>()
                normalizedBeneficiaries = rawBeneficiaries
                    .map(normalize)
                    .filter { memberSet.contains($0) && seen.insert($0).inserted }
            }
            guard !normalizedBeneficiaries.isEmpty else {
                skipReason = "受益者が現参加者に居ない"
                debugRows.append(.init(
                    id: e.objectID.uriRepresentation().absoluteString,
                    date: e.date ?? .now, title: e.displayTitle,
                    rawPayer: rawPayer, normalizedPayer: normalize(rawPayer),
                    amount: e.amountDecimal, currencyCode: from,
                    convertedAmount: converted,
                    rawBeneficiaries: rawBeneficiaries, normalizedBeneficiaries: [],
                    perShare: nil, included: false, skipReason: skipReason))
                continue
            }

            // 3) payer 解決
            guard let payer = resolvePayer(e) else {
                skipReason = "payerProfileID が空"
                debugRows.append(.init(
                    id: e.objectID.uriRepresentation().absoluteString,
                    date: e.date ?? .now, title: e.displayTitle,
                    rawPayer: rawPayer, normalizedPayer: "",
                    amount: e.amountDecimal, currencyCode: from,
                    convertedAmount: converted,
                    rawBeneficiaries: rawBeneficiaries, normalizedBeneficiaries: normalizedBeneficiaries,
                    perShare: nil, included: false, skipReason: skipReason))
                continue
            }
            normalizedPayer = payer
            guard memberSet.contains(payer) else {
                skipReason = "payer が現参加者に居ない"
                debugRows.append(.init(
                    id: e.objectID.uriRepresentation().absoluteString,
                    date: e.date ?? .now, title: e.displayTitle,
                    rawPayer: rawPayer, normalizedPayer: payer,
                    amount: e.amountDecimal, currencyCode: from,
                    convertedAmount: converted,
                    rawBeneficiaries: rawBeneficiaries, normalizedBeneficiaries: normalizedBeneficiaries,
                    perShare: nil, included: false, skipReason: skipReason))
                continue
            }

            // 4) 集計
            let count = Decimal(normalizedBeneficiaries.count)
            let perShare = roundToCurrency(converted / count, code: target)
            perShareOpt = perShare
            let allocatedTotal = perShare * count
            balances[payer, default: 0] += allocatedTotal
            for b in normalizedBeneficiaries {
                balances[b, default: 0] -= perShare
            }
            included = true
            includedCount += 1
            debugRows.append(.init(
                id: e.objectID.uriRepresentation().absoluteString,
                date: e.date ?? .now, title: e.displayTitle,
                rawPayer: rawPayer, normalizedPayer: normalizedPayer,
                amount: e.amountDecimal, currencyCode: from,
                convertedAmount: converted,
                rawBeneficiaries: rawBeneficiaries, normalizedBeneficiaries: normalizedBeneficiaries,
                perShare: perShareOpt, included: included, skipReason: nil))
        }

        let memberBalances: [MemberBalance] = memberOrder.map { id in
            MemberBalance(profileID: id, amount: balances[id] ?? 0)
        }

        let nonZero = memberBalances.filter { !$0.isSettled }
        let transfers = computeMinimumTransfers(balances: nonZero, currencyCode: target)

        let debug: SettlementDebugInfo?
        #if DEBUG
        debug = SettlementDebugInfo(
            memberSet: memberOrder,
            selfCanonical: selfCanonical,
            selfIDs: Array(selfIDs).sorted(),
            expenseRows: debugRows
        )
        #else
        debug = BuildInfo.isInternalBuild ? SettlementDebugInfo(
            memberSet: memberOrder,
            selfCanonical: selfCanonical,
            selfIDs: Array(selfIDs).sorted(),
            expenseRows: debugRows
        ) : nil
        #endif

        return SettlementResult(
            currencyCode: target,
            balances: memberBalances,
            transfers: transfers,
            missingRateCurrencies: missing,
            includedExpenseCount: includedCount,
            debugInfo: debug
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

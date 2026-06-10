//
//  SettlementCalculator.swift
//  Expenso
//
//  支出群から精算結果を計算する純粋関数群。
//  - 支出のみ対象 (収入はスキップ)
//  - 各 Expense は payer から beneficiaries に均等割りで負担を発生させる
//  - 通貨はシートの既定通貨に FX 換算して合算
//  - 出力: 各メンバーの net 残高 + 実際の貸し借り (ペアごとのネット) に沿った送金提案。
//    相互の貸し借りと循環 (A→B→C→A) は相殺し、残った実債務をそのまま提案する。
//    送金回数の最小化より「借りた相手に返す」直感を優先する。
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
    /// カテゴリ別の集計 (totalAmount 降順)。期間フィルタ適用後のもの。
    let categoryBreakdowns: [CategoryBreakdown]
    /// 計算過程のデバッグ情報 (DEBUG ビルドでのみ populate)
    let debugInfo: SettlementDebugInfo?
}

/// カテゴリ別の合計支出 (シート既定通貨に換算済み)。
struct CategoryBreakdown: Identifiable, Hashable {
    let categoryName: String   // displayName または "未分類"
    let symbol: String
    let colorHex: String?      // 表示色 hex。nil ならグレーフォールバック
    let totalAmount: Decimal
    let expenseCount: Int
    var id: String { categoryName }
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
        let share: CKShare? = ShareCoordinator.shared.existingShare(for: sheet)
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
        // self placeholder (__defaultOwner__) のエントリも、その email を
        // selfCanonical に紐づけて map に入れる (= 自分の旧 email-based payerProfileID
        // を正しく URN 解決できるようにする)。
        var emailToURN: [String: String] = [:]
        if let share = share {
            for p in share.participants {
                let urnRaw = p.userIdentity.userRecordID?.recordName ?? ""
                let resolvedURN: String
                if UserProfileStore.isSelfPlaceholderRecordName(urnRaw) {
                    // self placeholder → 自分の URN に置き換え
                    guard !selfCanonical.isEmpty else { continue }
                    resolvedURN = selfCanonical
                } else {
                    guard !urnRaw.isEmpty else { continue }
                    resolvedURN = urnRaw
                }
                if let email = p.userIdentity.lookupInfo?.emailAddress?.lowercased(),
                   !email.isEmpty {
                    emailToURN["email:" + email] = resolvedURN
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

        // メンバー集合 = 自分 + CKShare.participants の URN
        // ShareCalendarApp と同様、URN ベースで dedup。
        //
        // 重要: CKShare がロード済みなら participants を **唯一の source of truth** とする。
        // PP には共有解除済のメンバーが残るケースがあり、それを混ぜると balances にも
        // 解除済みメンバーが出続けてしまうので、CKShare が取れている時は PP を補完
        // しない。CKShare が取れていない時 (= 未ロード or solo シート) のみ PP を使う。
        var memberOrder: [String] = []
        var memberSet = Set<String>()
        if !selfCanonical.isEmpty,
           memberSet.insert(selfCanonical).inserted {
            memberOrder.append(selfCanonical)
        }
        if let share = share {
            // CKShare ロード済 → participants を信用
            // 招待中で未参加 (.pending) のメンバーは精算対象に含めない。
            for p in share.participants {
                guard p.acceptanceStatus == .accepted else { continue }
                guard let urn = p.userIdentity.userRecordID?.recordName,
                      !urn.isEmpty,
                      !UserProfileStore.isSelfPlaceholderRecordName(urn),
                      memberSet.insert(urn).inserted else { continue }
                memberOrder.append(urn)
            }
            // バーチャルメンバーは CKShare に出ないので PP から精算対象に追加する。
            let virtualPPs = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
            // 同名が複数いると displayName だけでは順序が不安定 (Set 列挙順依存) になり
            // 残高タイルが入れ替わってチカチカするため、recordName をタイブレークに使う。
            for pp in virtualPPs.sorted(by: {
                ($0.displayName ?? "", $0.recordName ?? "") < ($1.displayName ?? "", $1.recordName ?? "")
            }) {
                guard let rn = pp.recordName, UserProfileStore.isVirtualRecordName(rn) else { continue }
                let nid = normalize(rn)
                if memberSet.insert(nid).inserted { memberOrder.append(nid) }
            }
        } else {
            // 共有なし (CKShare が無い) 時はバーチャルメンバーのみ精算対象に追加する。
            // 非バーチャルの PP は「共有していたが抜けた参加者」の残骸であることが
            // あるため含めない (抜けた人の精算は出さない)。これにより、
            // 共有していなくてもバーチャルメンバーが居れば精算が表示される。
            let pps = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
            // 同名タイブレークは recordName で (上記コメント参照)。
            for pp in pps.sorted(by: {
                ($0.displayName ?? "", $0.recordName ?? "") < ($1.displayName ?? "", $1.recordName ?? "")
            }) {
                guard let rn = pp.recordName, UserProfileStore.isVirtualRecordName(rn) else { continue }
                let nid = normalize(rn)
                if memberSet.insert(nid).inserted { memberOrder.append(nid) }
            }
        }

        // アーカイブ済み (削除された) バーチャルメンバーの正規化 ID 集合。
        // 残高が 0 (精算済み) のときだけ残高表示から除外するために使う。
        let archivedMemberIDs: Set<String> = Set(
            ((sheet.participantProfiles as? Set<ParticipantProfile>) ?? [])
                .filter { $0.archived }
                .compactMap { $0.recordName }
                .map(normalize)
        )

        var balances: [String: Decimal] = [:]
        for m in memberOrder { balances[m] = 0 }
        // ペアごとの貸し借りネット。送金プランを「実際に誰が誰に借りたか」に
        // 沿って出すために、net 残高とは別にペア単位でも集計する。
        var pairDebts: [PairKey: Decimal] = [:]

        var missing: Set<String> = []
        var includedCount = 0
        var debugRows: [SettlementDebugInfo.ExpenseRow] = []

        // カテゴリ別集計用 (key = displayName)。fx 換算後の金額を加算する。
        struct CategoryAggregator {
            var symbol: String
            var colorHex: String?
            var total: Decimal
            var count: Int
        }
        var categoryAgg: [String: CategoryAggregator] = [:]

        for e in expenses {
            let from = e.resolvedCurrencyCode
            let rawPayer = e.payerProfileID ?? ""
            let rawBeneficiaries = e.resolvedBeneficiaryIDs()
            // FX スナップショットがあればそれを優先 (= 記録時の target 換算額を
            // 凍結することで為替変動による残高ドリフトを防ぐ)。無ければ
            // 現行 FX で換算 (旧データの後方互換性)。
            let convertedOpt: Decimal? = {
                if let snap = e.snapshotConvertedAmount(forTarget: target) {
                    return snap
                }
                return fx.convert(e.amountDecimal, from: from, to: target)
            }()
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
            // 受益者が空 (= 割り勘オフ / 支払者単独負担) はスキップせず、
            // カテゴリ集計だけ行う (= 残高は変動させない)。
            do {
                var seen = Set<String>()
                normalizedBeneficiaries = rawBeneficiaries
                    .map(normalize)
                    .filter { memberSet.contains($0) && seen.insert($0).inserted }
            }
            if !rawBeneficiaries.isEmpty && normalizedBeneficiaries.isEmpty {
                // 明示的に受益者がセットされていたが、現在の参加者に居ない
                // (= 退室済み or 別 ID にマイグレート) → 集計対象外
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
            // 受益者が空 (= 割り勘オフ / 支払者単独負担) は残高変動なし。
            // カテゴリ集計のみ続行する。
            if !normalizedBeneficiaries.isEmpty {
                let count = Decimal(normalizedBeneficiaries.count)
                let perShare = roundToCurrency(converted / count, code: target)
                perShareOpt = perShare
                // 精算は SettlementRecord (= 送金プランからの記録) のみで行う。
                // per-expense の settled フラグは廃止済みなので、ここでは全受益者を
                // そのまま残高に反映する。
                let allocatedTotal = perShare * Decimal(normalizedBeneficiaries.count)
                balances[payer, default: 0] += allocatedTotal
                for b in normalizedBeneficiaries {
                    balances[b, default: 0] -= perShare
                }
                // ペア集計: 受益者 (payer 自身を除く) は payer に perShare を借りる
                for b in normalizedBeneficiaries where b != payer {
                    addPairDebt(&pairDebts, from: b, to: payer, amount: perShare)
                }
                // 精算対象としてカウントするのは「割り勘設定された (= 受益者がいる)」
                // 支出のみ。割り勘オフ (= 支払者単独負担) は残高に影響しないので
                // 「対象支出」の件数には数えない。
                includedCount += 1
            }
            included = true

            // 5) カテゴリ別集計 (期間フィルタ適用後の支出のみ加算)
            let catName = e.resolvedCategory?.displayName
                ?? (e.categoryRaw?.isEmpty == false ? e.categoryRaw! : "カテゴリなし")
            let catSymbol = e.resolvedCategory?.displaySymbol ?? "list.bullet"
            let catColor = e.resolvedCategory?.colorHex
            if var agg = categoryAgg[catName] {
                agg.total += converted
                agg.count += 1
                categoryAgg[catName] = agg
            } else {
                categoryAgg[catName] = CategoryAggregator(
                    symbol: catSymbol,
                    colorHex: catColor,
                    total: converted,
                    count: 1
                )
            }
            debugRows.append(.init(
                id: e.objectID.uriRepresentation().absoluteString,
                date: e.date ?? .now, title: e.displayTitle,
                rawPayer: rawPayer, normalizedPayer: normalizedPayer,
                amount: e.amountDecimal, currencyCode: from,
                convertedAmount: converted,
                rawBeneficiaries: rawBeneficiaries, normalizedBeneficiaries: normalizedBeneficiaries,
                perShare: perShareOpt, included: included, skipReason: nil))
        }

        // 4.5) 未実体化の定期 occurrence (仮想) も同じロジックで集計する (完全仮想化)。
        //   - includeFuture:false → 今日まで。未来分は債務に含めない。
        //   - 実在行がある日付は virtualOccurrences 側で除外済み (= 二重計上しない)。
        //   - FX スナップショットは無いので現行レートで換算 (定期は凍結しない方針)。
        let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let resolvePayerID: (String?) -> String? = { pid in
            guard let pid, !pid.isEmpty else { return nil }
            if !selfCanonical.isEmpty {
                if selfIDs.contains(pid) { return selfCanonical }
                if let selfEmailID, pid == selfEmailID { return selfCanonical }
            }
            if let urn = emailToURN[pid] { return urn }
            return pid
        }
        let virtualOccurrences = RecurringOccurrenceService.virtualOccurrences(
            for: sheet, in: dateRange, includeFuture: false
        )
        for occ in virtualOccurrences where occ.kind == .expense {
            guard let converted = fx.convert(occ.amount, from: occ.currencyCode, to: target) else {
                missing.insert(occ.currencyCode)
                continue
            }
            // 受益者: CSV → 正規化 + 現参加者フィルタ + dedup (Expense ループと同じ扱い)
            var seen = Set<String>()
            let normalizedBeneficiaries = occ.beneficiaryProfileIDs
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(normalize)
                .filter { memberSet.contains($0) && seen.insert($0).inserted }
            // payer 解決 (現参加者でなければスキップ)
            guard let payer = resolvePayerID(occ.payerProfileID), memberSet.contains(payer) else {
                continue
            }
            // 残高: 受益者がいる時のみ (割り勘オフは残高変動なし、カテゴリ集計のみ)
            if !normalizedBeneficiaries.isEmpty {
                let perShare = roundToCurrency(converted / Decimal(normalizedBeneficiaries.count), code: target)
                balances[payer, default: 0] += perShare * Decimal(normalizedBeneficiaries.count)
                for b in normalizedBeneficiaries { balances[b, default: 0] -= perShare }
                for b in normalizedBeneficiaries where b != payer {
                    addPairDebt(&pairDebts, from: b, to: payer, amount: perShare)
                }
                includedCount += 1
            }
            // カテゴリ集計 (Expense ループと同じく displayName をキーに)
            let cat = cats.first(where: { $0.name == occ.categoryRaw })
            let catName = cat?.displayName ?? (occ.categoryRaw.isEmpty ? "カテゴリなし" : occ.categoryRaw)
            if var agg = categoryAgg[catName] {
                agg.total += converted
                agg.count += 1
                categoryAgg[catName] = agg
            } else {
                categoryAgg[catName] = CategoryAggregator(
                    symbol: cat?.displaySymbol ?? "list.bullet",
                    colorHex: cat?.colorHex,
                    total: converted,
                    count: 1
                )
            }
        }

        // 5) ユーザーが記録した実送金 (SettlementRecord) を反映。
        //    「A → B に X 払った」= A の債務が減る = A の balance を +X、B を -X。
        //    期間フィルタは Expense と同じ条件 (record.date が dateRange に含まれる)。
        let allSettlements = (sheet.settlements as? Set<SettlementRecord>) ?? []
        let settlementsInRange = allSettlements.filter { s in
            if let range = dateRange {
                guard let d = s.date else { return false }
                return range.contains(d)
            }
            return true
        }
        for s in settlementsInRange {
            let rawFrom = s.fromProfileID ?? ""
            let rawTo = s.toProfileID ?? ""
            guard !rawFrom.isEmpty, !rawTo.isEmpty else { continue }
            let from = normalize(rawFrom)
            let to = normalize(rawTo)
            guard memberSet.contains(from), memberSet.contains(to), from != to else { continue }
            // 1) FX スナップショット (= 記録時に解決された target 換算額) があれば
            //    それを優先する。為替変動で「精算済みのはずなのに送金プランに
            //    再表示される」現象を防ぐため。
            // 2) スナップショット非対応の古い記録 (= 旧バージョンで作成) は
            //    fallback で現行 FX レートを使って換算する。
            let amt = s.amountDecimal
            guard amt > 0 else { continue }
            let convertedOpt: Decimal? = {
                if let snap = s.snapshotConvertedAmount(forTarget: target) {
                    return snap
                }
                return fx.convert(amt, from: s.resolvedCurrencyCode, to: target)
            }()
            guard let converted = convertedOpt else {
                missing.insert(s.resolvedCurrencyCode)
                continue
            }
            let rounded = roundToCurrency(converted, code: target)
            balances[from, default: 0] += rounded
            balances[to,   default: 0] -= rounded
            // ペア集計: 「from が to に払った」= from の to への債務が減る
            addPairDebt(&pairDebts, from: from, to: to, amount: -rounded)
        }

        let memberBalances: [MemberBalance] = memberOrder.compactMap { id in
            let amount = balances[id] ?? 0
            // アーカイブ済みメンバーは精算済み (残高 0) なら残高に表示しない。
            // 残高が残っている場合は表示し続ける (まだ精算が必要なため)。
            if amount == 0, archivedMemberIDs.contains(id) { return nil }
            return MemberBalance(profileID: id, amount: amount)
        }

        let transfers = computeDebtFollowingTransfers(
            pairDebts: pairDebts, memberOrder: memberOrder, currencyCode: target)

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

        let categoryBreakdowns: [CategoryBreakdown] = categoryAgg
            .map { (name, agg) in
                CategoryBreakdown(
                    categoryName: name,
                    symbol: agg.symbol,
                    colorHex: agg.colorHex,
                    totalAmount: roundToCurrency(agg.total, code: target),
                    expenseCount: agg.count
                )
            }
            .sorted { $0.totalAmount > $1.totalAmount }

        return SettlementResult(
            currencyCode: target,
            balances: memberBalances,
            transfers: transfers,
            missingRateCurrencies: missing,
            includedExpenseCount: includedCount,
            categoryBreakdowns: categoryBreakdowns,
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

    /// ペア (順序なし) の貸し借りネットのキー。`a < b` (辞書順) に正規化して保持し、
    /// 値が正なら「a が b に借りている」、負なら「b が a に借りている」。
    private struct PairKey: Hashable {
        let a: String
        let b: String
    }

    /// 「debtor が creditor に amount 借りた」をペアネットへ加算する。
    /// 相互の貸し借りは同じキーで符号が打ち消し合い、自動的に相殺される。
    private static func addPairDebt(
        _ debts: inout [PairKey: Decimal],
        from debtor: String, to creditor: String, amount: Decimal
    ) {
        guard debtor != creditor else { return }
        if debtor < creditor {
            debts[PairKey(a: debtor, b: creditor), default: 0] += amount
        } else {
            debts[PairKey(a: creditor, b: debtor), default: 0] -= amount
        }
    }

    /// 実際の貸し借り (ペアごとのネット) に沿った送金プランを作る。
    /// 1. 相互の貸し借りはペアネットの時点で相殺済み。
    /// 2. 循環 (A→B→C→A のように一周するお金) は動かす意味が無いので相殺する。
    ///    全員精算済み (全 net 残高 0) なら必ず空プランに収束する。
    /// 3. 残った債務エッジをそのまま「borrower → lender」の送金として提案する。
    ///    送金回数の最小化より「借りた相手に返す」直感を優先する (= greedy の
    ///    「借りていない相手へ送金」が出ない)。途中に立つメンバー (借りて貸した人) は
    ///    受け取りと支払いの両方が提案される。
    private static func computeDebtFollowingTransfers(
        pairDebts: [PairKey: Decimal],
        memberOrder: [String],
        currencyCode: String
    ) -> [SettlementTransfer] {
        // 1 通貨単位 (= 丸め誤差) 以下は 0 とみなす
        let epsilon = roundToCurrency(Decimal(1) / Decimal(100), code: currencyCode)
        var orderIndex: [String: Int] = [:]
        for (i, id) in memberOrder.enumerated() where orderIndex[id] == nil { orderIndex[id] = i }
        func rank(_ id: String) -> (Int, String) { (orderIndex[id] ?? Int.max, id) }

        // 有向グラフ: debtor → creditor (正の金額のみ)
        var edges: [String: [String: Decimal]] = [:]
        for (key, value) in pairDebts {
            if value > epsilon {
                edges[key.a, default: [:]][key.b, default: 0] += value
            } else if -value > epsilon {
                edges[key.b, default: [:]][key.a, default: 0] += -value
            }
        }

        // 循環の検出 (色付き DFS、近傍は memberOrder 順で決定的に辿る)。
        // 返り値は [n0, n1, ..., n0] のような閉路ノード列。
        func detectCycle() -> [String]? {
            var color: [String: Int] = [:]   // 0=未訪問, 1=訪問中, 2=完了
            var path: [String] = []
            var found: [String]?
            func dfs(_ u: String) {
                guard found == nil else { return }
                color[u] = 1
                path.append(u)
                let neighbors = (edges[u] ?? [:]).keys.sorted { rank($0) < rank($1) }
                for v in neighbors {
                    guard found == nil else { return }
                    switch color[v] ?? 0 {
                    case 1:
                        if let i = path.firstIndex(of: v) {
                            found = Array(path[i...]) + [v]
                        }
                        return
                    case 0:
                        dfs(v)
                    default:
                        break
                    }
                }
                path.removeLast()
                color[u] = 2
            }
            for n in edges.keys.sorted(by: { rank($0) < rank($1) }) where (color[n] ?? 0) == 0 {
                dfs(n)
                if let found { return found }
            }
            return nil
        }

        // 閉路上の最小額を全エッジから差し引く。1 回ごとに最低 1 本エッジが消えるので必ず停止する。
        while let cycle = detectCycle() {
            var minAmount = Decimal.greatestFiniteMagnitude
            for i in 0..<(cycle.count - 1) {
                minAmount = min(minAmount, edges[cycle[i]]?[cycle[i + 1]] ?? 0)
            }
            for i in 0..<(cycle.count - 1) {
                let f = cycle[i], t = cycle[i + 1]
                let remaining = (edges[f]?[t] ?? 0) - minAmount
                if remaining > epsilon {
                    edges[f]?[t] = remaining
                } else {
                    edges[f]?[t] = nil
                    if edges[f]?.isEmpty == true { edges[f] = nil }
                }
            }
        }

        // 残った債務エッジ = 送金プラン。金額降順 (同額は memberOrder 順) で安定に並べる。
        var transfers: [SettlementTransfer] = []
        for (from, tos) in edges {
            for (to, amount) in tos {
                let rounded = roundToCurrency(amount, code: currencyCode)
                guard rounded > 0 else { continue }
                transfers.append(SettlementTransfer(fromProfileID: from, toProfileID: to, amount: rounded))
            }
        }
        transfers.sort { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            if lhs.fromProfileID != rhs.fromProfileID { return rank(lhs.fromProfileID) < rank(rhs.fromProfileID) }
            return rank(lhs.toProfileID) < rank(rhs.toProfileID)
        }
        return transfers
    }
}

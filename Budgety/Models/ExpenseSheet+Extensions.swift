//
//  ExpenseSheet+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI
import CloudKit

extension ExpenseSheet {
    var displayName: String { name ?? "" }
    var displayColorHex: String { colorHex ?? "#5B8DEF" }
    var displaySymbol: String {
        let s = symbol ?? ""
        return s.isEmpty ? "person.2.fill" : s
    }

    /// シートのアクセントカラー (UI 全体の差し色として使う)
    var tint: SwiftUI.Color {
        SwiftUI.Color(hex: displayColorHex) ?? .indigo
    }

    var resolvedDefaultCurrencyCode: String {
        if let c = defaultCurrencyCode, !c.isEmpty { return c }
        return CurrencyCatalog.defaultCode
    }

    /// 月予算 (= 既定通貨換算で支出が超えないように管理する目標額)。
    /// `0` または未設定なら「予算なし」(`nil` を返す)。
    var resolvedMonthlyBudget: Decimal? {
        guard let v = monthlyBudget as Decimal? else { return nil }
        return v > 0 ? v : nil
    }

    /// 月予算が設定されていれば値を返し、無ければ `nil`。setter は 0 で空 (= 未設定) 扱い。
    var monthlyBudgetDecimal: Decimal? {
        get { resolvedMonthlyBudget }
        set {
            if let v = newValue, v > 0 {
                monthlyBudget = NSDecimalNumber(decimal: v)
            } else {
                monthlyBudget = nil
            }
        }
    }

    /// このシートが Private ストアにあれば所有者、Shared ストアにあれば参加者。
    var isOwnedByCurrentUser: Bool {
        let pc = PersistenceController.shared
        guard let privateStore = pc.privateStore,
              let currentStore = objectID.persistentStore else {
            return true // 判定できなければ所有者扱い (新規作成時など)
        }
        return currentStore == privateStore
    }

    var sortedExpenses: [Expense] {
        let set = (expenses as? Set<Expense>) ?? []
        return set.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - 換算合計 (FX レートを使って既定通貨に統一)

    /// 全期間 + 全通貨を既定通貨に換算した合計 (支出, 収入)。
    /// レートが見つからない通貨は除外する。
    @MainActor
    func convertedTotals(_ filter: (Expense) -> Bool = { _ in true }) -> (expense: Decimal, income: Decimal, missing: Set<String>) {
        let target = resolvedDefaultCurrencyCode
        let fx = FXRatesService.shared
        var expenseSum: Decimal = 0
        var incomeSum: Decimal = 0
        var missing: Set<String> = []
        let set = (expenses as? Set<Expense>) ?? []
        for e in set where filter(e) {
            let from = e.resolvedCurrencyCode
            guard let converted = fx.convert(e.amountDecimal, from: from, to: target) else {
                missing.insert(from)
                continue
            }
            switch e.kind {
            case .expense: expenseSum += converted
            case .income:  incomeSum += converted
            }
        }
        return (expenseSum, incomeSum, missing)
    }

    @MainActor
    func convertedMonthlyTotals(month: Date = .now) -> (expense: Decimal, income: Decimal, missing: Set<String>) {
        let cal = Calendar.current
        return convertedTotals { e in
            cal.isDate(e.date ?? .distantPast, equalTo: month, toGranularity: .month)
        }
    }

    // MARK: - Members (精算機能用)

    /// シートに紐づく全メンバーの profileID リスト (= Expense.payerProfileID と同じ識別子空間)。
    /// 自分 (canonicalSelfID = オーナーなら userRecordName、参加者なら "email:...")
    /// と ParticipantProfile.recordName を結合して返す。
    /// 受益者未指定の Expense を「全員均等割り」として扱う際の母集合。
    ///
    /// 注意: 自分は **canonical** で入れる。`userRecordName` を使うと参加者側で
    /// 自分の PP.recordName (= canonical = "email:...") と別文字列になり dedup
    /// できず、フォールバック時に自分が 2 重カウントされて perShare がズレる。
    @MainActor
    func allMemberProfileIDs() -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        #if !os(watchOS)
        let share = ShareCoordinator.shared.existingShare(for: self)
        #else
        let share: CKShare? = nil
        #endif
        let selfID = UserProfileStore.shared.canonicalSelfID(forShare: share)
            ?? UserProfileStore.shared.userRecordName
        if let me = selfID, !me.isEmpty, seen.insert(me).inserted {
            result.append(me)
        }
        // 旧 userRecordName が canonical と異なる場合も seen に入れて 2 重カウントを防ぐ
        // (PP recordName がまだ旧 URN のままの相手がいた場合の保険)
        if let urn = UserProfileStore.shared.userRecordName, !urn.isEmpty {
            seen.insert(urn)
        }

        let profiles = (participantProfiles as? Set<ParticipantProfile>) ?? []
        let sortedProfiles = profiles.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
        for pp in sortedProfiles {
            guard let rn = pp.recordName, !rn.isEmpty,
                  rn != "_defaultOwner_", rn != "__defaultOwner__" else { continue }
            if seen.insert(rn).inserted {
                result.append(rn)
            }
        }
        return result
    }

    /// profileID を表示用情報に解決する。
    /// 1. 自分 (UserProfileStore.userRecordName 一致) → UserProfileStore
    /// 2. **CKShare の参加者を毎回参照** → Apple ID 名 (nameComponents)
    ///    (iCloud Extended Share Access エンタイトルメントで取れる)
    /// 3. ParticipantProfile.recordName 一致 (= CKShare 取得前のフォールバック)
    /// 4. ローカル Member の recordName / UUID 一致 (旧データ救済)
    /// いずれにも一致しなければ "メンバー" の汎用表示。
    ///
    /// 名前は PP に書き溜めず、その都度 CKShare から取得する方針。
    /// 色は CKShare からは取れないので PP の colorHex を併用する (なければ既定灰)。
    @MainActor
    func memberDisplayInfo(for profileID: String) -> (name: String, colorHex: String, photoData: Data?) {
        // 自分判定: URN だけでなく canonical (email:..) や旧 ID も含めて広く拾う。
        // これにより旧 "email:tento1209@icloud.com" などで保存された自分の行も
        // "メンバー" にフォールバックされず "自分" 表示になる。
        #if !os(watchOS)
        let share = ShareCoordinator.shared.existingShare(for: self)
        #else
        let share: CKShare? = nil
        #endif
        let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
        let selfEmailID: String? = {
            if let e = UserProfileStore.shared.selfEmail?.lowercased(), !e.isEmpty {
                return "email:" + e
            }
            return nil
        }()
        let isSelf = selfIDs.contains(profileID)
            || (selfEmailID != nil && profileID == selfEmailID)
        if isSelf {
            let store = UserProfileStore.shared
            return (
                name: store.resolvedDisplayName,
                colorHex: store.avatarBgColorHex ?? "#5B8DEF",
                photoData: nil
            )
        }
        let profiles = (participantProfiles as? Set<ParticipantProfile>) ?? []
        let ppMatch = profiles.first(where: { $0.recordName == profileID })
        let fallbackColor = (ppMatch?.colorHex?.isEmpty == false ? ppMatch!.colorHex! : "#8E8E93")

        // 2) CKShare から都度引き直す (Apple ID 名)
        #if !os(watchOS)
        if let share = share,
           let liveName = nameFromShare(share, profileID: profileID),
           !liveName.isEmpty {
            return (name: liveName, colorHex: fallbackColor, photoData: nil)
        }
        #endif

        // 3) PP フォールバック (CKShare 未取得タイミング用)
        if let pp = ppMatch {
            return (
                name: pp.displayName?.isEmpty == false ? pp.displayName! : "メンバー",
                colorHex: fallbackColor,
                photoData: nil
            )
        }
        // ローカル Member へのフォールバック (recordName / UUID)
        let ctx = managedObjectContext ?? PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<Member>(entityName: "Member")
        if let uuid = UUID(uuidString: profileID) {
            req.predicate = NSPredicate(format: "recordName == %@ OR id == %@", profileID, uuid as CVarArg)
        } else {
            req.predicate = NSPredicate(format: "recordName == %@", profileID)
        }
        req.fetchLimit = 1
        if let m = (try? ctx.fetch(req))?.first {
            return (
                name: m.displayName,
                colorHex: m.displayColorHex,
                photoData: m.photoData
            )
        }
        return (name: "メンバー", colorHex: "#8E8E93", photoData: nil)
    }

    #if !os(watchOS)
    /// `share` の owner / participants から `profileID` (URN) と一致するエントリを探し、
    /// その `userIdentity.nameComponents` をフォーマットして返す。
    /// `__defaultOwner__` placeholder の自分は別途 UserProfileStore で扱うので無視。
    @MainActor
    private func nameFromShare(_ share: CKShare, profileID: String) -> String? {
        let fmt = PersonNameComponentsFormatter()
        fmt.style = .default
        // owner
        let ownerRN = share.owner.userIdentity.userRecordID?.recordName ?? ""
        if !UserProfileStore.isSelfPlaceholderRecordName(ownerRN), ownerRN == profileID,
           let comps = share.owner.userIdentity.nameComponents {
            return fmt.string(from: comps)
        }
        // participants
        for p in share.participants {
            let rn = p.userIdentity.userRecordID?.recordName ?? ""
            if UserProfileStore.isSelfPlaceholderRecordName(rn) { continue }
            if rn == profileID, let comps = p.userIdentity.nameComponents {
                return fmt.string(from: comps)
            }
        }
        return nil
    }
    #endif
}

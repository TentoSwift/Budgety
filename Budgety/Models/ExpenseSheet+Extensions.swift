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

        let share = ShareCoordinator.shared.existingShare(for: self)
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
        let sortedProfiles = profiles.sorted { ($0.displayName ?? "", $0.recordName ?? "") < ($1.displayName ?? "", $1.recordName ?? "") }
        for pp in sortedProfiles {
            guard let rn = pp.recordName, !rn.isEmpty,
                  rn != "_defaultOwner_", rn != "__defaultOwner__",
                  !pp.archived else { continue }
            if seen.insert(rn).inserted {
                result.append(rn)
            }
        }
        return result
    }

    /// 割り勘・支払者の候補とする「現在のメンバー」の profileID。
    /// = 自分 + CKShare の **受諾済み** 参加者 + バーチャルメンバー。
    /// CKShare 未ロード時は受諾判定できないので非バーチャル PP で代替する。
    /// `allMemberProfileIDs()` と違い、招待中 (.pending)・解除済みの参加者は含めない。
    @MainActor
    func acceptedMemberProfileIDs() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let share = ShareCoordinator.shared.existingShare(for: self)
        // 自分
        let selfID = UserProfileStore.shared.canonicalSelfID(forShare: share)
            ?? UserProfileStore.shared.userRecordName
        if let me = selfID, !me.isEmpty, seen.insert(me).inserted {
            result.append(me)
        }
        if let urn = UserProfileStore.shared.userRecordName, !urn.isEmpty {
            seen.insert(urn)
        }
        let profiles = (participantProfiles as? Set<ParticipantProfile>) ?? []
        let sorted = profiles.sorted { ($0.displayName ?? "", $0.recordName ?? "") < ($1.displayName ?? "", $1.recordName ?? "") }
        if let share {
            for p in share.participants {
                guard p.acceptanceStatus == .accepted,
                      let rn = p.userIdentity.userRecordID?.recordName, !rn.isEmpty,
                      !UserProfileStore.isSelfPlaceholderRecordName(rn),
                      seen.insert(rn).inserted else { continue }
                result.append(rn)
            }
        } else {
            // CKShare 未ロード (= solo シート or 未同期) のフォールバック
            for pp in sorted {
                guard let rn = pp.recordName, !rn.isEmpty,
                      rn != "_defaultOwner_", rn != "__defaultOwner__",
                      !UserProfileStore.isVirtualRecordName(rn),
                      seen.insert(rn).inserted else { continue }
                result.append(rn)
            }
        }
        // バーチャルメンバーは CKShare に出ないので常に PP から追加する。
        // アーカイブ済みは新規の割り勘候補に出さない。
        for pp in sorted {
            guard let rn = pp.recordName, UserProfileStore.isVirtualRecordName(rn),
                  !pp.archived,
                  seen.insert(rn).inserted else { continue }
            result.append(rn)
        }
        return result
    }

    /// このシートのバーチャルメンバー (ParticipantProfile) を名前順で返す。
    /// アーカイブ済み (削除されたが過去の支出で使われている) は除外する。
    var virtualMemberProfiles: [ParticipantProfile] {
        let profiles = (participantProfiles as? Set<ParticipantProfile>) ?? []
        return profiles
            .filter { UserProfileStore.isVirtualRecordName($0.recordName ?? "") && !$0.archived }
            .sorted { ($0.displayName ?? "", $0.recordName ?? "") < ($1.displayName ?? "", $1.recordName ?? "") }
    }

    /// バーチャルメンバーのアバター配色パレット。
    static let virtualMemberPalette: [String] = [
        "#FF9500", "#34C759", "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00", "#A2845E"
    ]

    /// バーチャルメンバーを追加し、その profileID (recordName) を返す。
    @MainActor
    @discardableResult
    func addVirtualMember(name: String, colorHex: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let ctx = managedObjectContext,
              let store = objectID.persistentStore else { return nil }
        let rn = UserProfileStore.virtualRecordPrefix + UUID().uuidString
        let pp = ParticipantProfile(context: ctx)
        ctx.assign(pp, to: store)
        pp.recordName = rn
        pp.sheet = self
        pp.displayName = trimmed
        let palette = Self.virtualMemberPalette
        pp.colorHex = colorHex ?? palette[virtualMemberProfiles.count % palette.count]
        pp.updatedAt = .now
        PersistenceController.shared.save()
        return rn
    }

    /// シートが「アーカイブ済み」か。Core Data 上は Bool (scalar) なので
    /// `archived` を直接参照すれば良いが、命名統一のため computed property も用意。
    /// 既存データには `archived` が無いため Core Data の default (NO) が返る。
    var isArchived: Bool { archived }

    /// アーカイブ状態をトグルする。CloudKit にも同期される。
    @MainActor
    func setArchived(_ value: Bool) {
        guard archived != value else { return }
        archived = value
        PersistenceController.shared.save()
    }

    /// バーチャルメンバーを削除する (バーチャル以外は無視)。
    /// 支出 (受益者 or 支払者) で使われている場合は、過去の精算を壊さないよう
    /// アーカイブ (= 新規候補・メンバー一覧から隠すが履歴・精算には残す)。
    /// どの支出でも使われていなければ完全削除する。
    @MainActor
    func deleteVirtualMember(profileID: String) {
        guard UserProfileStore.isVirtualRecordName(profileID),
              let ctx = managedObjectContext else { return }
        let profiles = (participantProfiles as? Set<ParticipantProfile>) ?? []
        guard let pp = profiles.first(where: { $0.recordName == profileID }) else { return }
        let used = ((expenses as? Set<Expense>) ?? []).contains { e in
            (e.payerProfileID == profileID) || e.beneficiaryIDList.contains(profileID)
        }
        if used {
            pp.archived = true
            pp.updatedAt = .now
        } else {
            ctx.delete(pp)
        }
        PersistenceController.shared.save()
    }

    /// 参加済の他メンバー (= 自分以外で acceptanceStatus == .accepted) が居るか。
    /// CKShare ロード済ならそれで判定、未ロードなら ParticipantProfile で判定。
    /// オーナーも「自分でなければ他メンバー」として数える（参加者デバイスで
    /// オーナーを除外してソロ扱いにしないため）。
    @MainActor
    func hasAcceptedOtherMembers() -> Bool {
        // バーチャルメンバーは CKShare に出ないので、(アーカイブ済みを除き) 居れば
        // 常に「他メンバーあり」。
        let profilesAll = (participantProfiles as? Set<ParticipantProfile>) ?? []
        if profilesAll.contains(where: {
            UserProfileStore.isVirtualRecordName($0.recordName ?? "") && !$0.archived
        }) {
            return true
        }
        if let share = ShareCoordinator.shared.existingShare(for: self) {
            let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
            return share.participants.contains { p in
                guard p.acceptanceStatus == .accepted else { return false }
                let rn = p.userIdentity.userRecordID?.recordName ?? ""
                guard !rn.isEmpty, !UserProfileStore.isSelfPlaceholderRecordName(rn) else { return false }
                return !selfIDs.contains(rn)
            }
        }
        guard let profiles = participantProfiles as? Set<ParticipantProfile> else { return false }
        let myRN = UserProfileStore.shared.userRecordName ?? ""
        return profiles.contains { p in
            let rn = p.recordName ?? ""
            return !rn.isEmpty && rn != myRN
        }
    }

    /// profileID を表示用情報に解決する。
    /// 1. 自分 → UserProfileStore (カスタム設定が最優先)
    /// 2. **Public DB の UserProfile (カスタムプロフィール)** ← 他人もここを最優先
    /// 3. CKShare の participant.nameComponents (Apple ID 名)
    /// 4. ParticipantProfile.recordName 一致 (CKShare 未取得時のフォールバック)
    /// 5. ローカル Member の recordName / UUID 一致 (旧データ救済)
    /// いずれにも一致しなければ "メンバー" の汎用表示。
    ///
    /// カスタムプロフィール (Public DB) > Apple ID 名 > "メンバー" の優先順位。
    /// 写真は Public DB のみ提供 (Apple ID アバターは API 非公開)。
    @MainActor
    func memberDisplayInfo(for profileID: String) -> (name: String, colorHex: String, photoData: Data?) {
        // 自分判定: URN だけでなく canonical (email:..) や旧 ID も含めて広く拾う。
        let share = ShareCoordinator.shared.existingShare(for: self)
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
                photoData: store.photoData
            )
        }
        let profiles = (participantProfiles as? Set<ParticipantProfile>) ?? []
        let ppMatch = profiles.first(where: { $0.recordName == profileID })

        // 2) Public DB のカスタムプロフィール (最優先で他人にも適用)
        if let custom = PublicProfileSync.shared.profileOrPrefetch(for: profileID),
           !custom.displayName.isEmpty {
            let color = custom.colorHex
                ?? (ppMatch?.colorHex?.isEmpty == false ? ppMatch!.colorHex! : "#8E8E93")
            return (name: custom.displayName, colorHex: color, photoData: custom.photoData)
        }

        let fallbackColor = (ppMatch?.colorHex?.isEmpty == false ? ppMatch!.colorHex! : "#8E8E93")
        let photoFromCache = PublicProfileSync.shared.cachedProfile(for: profileID)?.photoData

        // 3) CKShare の Apple ID 名 (カスタム未設定時)
        if let share = share,
           let liveName = nameFromShare(share, profileID: profileID),
           !liveName.isEmpty {
            return (name: liveName, colorHex: fallbackColor, photoData: photoFromCache)
        }

        // 4) PP フォールバック
        // バーチャルメンバーは Public DB に居ないので、PP に保存した photoData を優先で使う。
        if let pp = ppMatch {
            return (
                name: pp.displayName?.isEmpty == false ? pp.displayName! : String(localized: "メンバー"),
                colorHex: fallbackColor,
                photoData: pp.photoData ?? photoFromCache
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
        return (name: String(localized: "メンバー"), colorHex: "#8E8E93", photoData: nil)
    }

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
}

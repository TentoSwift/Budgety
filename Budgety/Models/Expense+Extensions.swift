//
//  Expense+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI
import CloudKit

extension Expense {
    var displayTitle: String { title ?? "" }

    /// 支払者の表示名。`payerProfileID` (canonical) から動的に解決する。
    /// 解決順 (memberDisplayInfo と一致させる):
    /// 1. 自分 → UserProfileStore.resolvedDisplayName
    /// 2. **PublicProfileSync の cache (= Public DB カスタム名)** ← 最優先
    /// 3. CKShare 参加者 → iCloud nameComponents (都度取得)
    /// 4. ParticipantProfile.displayName (= フォールバック)
    /// 5. ローカル Member.displayName
    /// 6. 保存時の `paidBy` 文字列 (= 旧データ用 fallback)
    @MainActor
    var displayPaidBy: String {
        if let n = resolvedSelfDisplayName(), !n.isEmpty { return n }
        if let n = resolvedPublicProfileName(), !n.isEmpty { return n }
        if let n = resolvedSharedParticipantName(), !n.isEmpty { return n }
        if let n = resolvedParticipantProfile?.displayName, !n.isEmpty { return n }
        if let n = resolvedPayer?.displayName, !n.isEmpty { return n }
        return paidBy ?? ""
    }
    @MainActor
    var payerTint: Color {
        if let hex = resolvedParticipantProfile?.displayColorHex, !hex.isEmpty,
           let c = Color(hex: hex) {
            return c
        }
        if isPayerSelf {
            return UserProfileStore.shared.bgColor
        }
        return resolvedPayer?.tint ?? .secondary
    }
    @MainActor
    var payerPhotoData: Data? {
        if let pp = resolvedParticipantProfile?.photoData { return pp }
        if isPayerSelf { return UserProfileStore.shared.photoData }
        // Public DB cache から他参加者の photo を取得
        if let pid = payerProfileID, !pid.isEmpty,
           let cached = PublicProfileSync.shared.cachedProfile(for: pid),
           let photo = cached.photoData {
            return photo
        }
        return resolvedPayer?.photoData
    }

    /// Public DB に登録された他参加者のカスタム表示名 (= ProfileEditView で設定したもの)。
    @MainActor
    private func resolvedPublicProfileName() -> String? {
        guard let pid = payerProfileID, !pid.isEmpty else { return nil }
        // 自分は resolvedSelfDisplayName で処理済みなのでスキップ
        if isPayerSelf { return nil }
        guard let cached = PublicProfileSync.shared.profileOrPrefetch(for: pid),
              !cached.displayName.isEmpty else { return nil }
        return cached.displayName
    }

    /// `payerProfileID` が「自分」を指しているか。
    @MainActor
    var isPayerSelf: Bool {
        guard let pid = payerProfileID, !pid.isEmpty else { return false }
        #if !os(watchOS)
        let share: CKShare? = sheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
        #else
        let share: CKShare? = nil
        #endif
        return UserProfileStore.shared.canonicalSelfIDs(forShare: share).contains(pid)
    }

    /// payerProfileID が自分なら UserProfileStore の displayName を返す。
    @MainActor
    private func resolvedSelfDisplayName() -> String? {
        guard isPayerSelf else { return nil }
        return UserProfileStore.shared.resolvedDisplayName
    }

    /// payerProfileID が CKShare の参加者 (オーナー含む) なら iCloud nameComponents を返す。
    /// URN マッチを優先、email/phone ベース canonical (旧データ) もフォールバックで照合。
    @MainActor
    private func resolvedSharedParticipantName() -> String? {
        #if !os(watchOS)
        guard let pid = payerProfileID, !pid.isEmpty,
              let sheet = sheet,
              let share = ShareCoordinator.shared.existingShare(for: sheet) else { return nil }
        // オーナー: URN 一致
        let ownerRN = share.owner.userIdentity.userRecordID?.recordName ?? ""
        if !UserProfileStore.isSelfPlaceholderRecordName(ownerRN), ownerRN == pid {
            return nameFromIdentity(share.owner.userIdentity)
        }
        // 参加者: URN 一致を優先、無ければ budgetyCanonicalID (email 等) もチェック
        for p in share.participants {
            let rn = p.userIdentity.userRecordID?.recordName ?? ""
            if !UserProfileStore.isSelfPlaceholderRecordName(rn), rn == pid {
                return nameFromIdentity(p.userIdentity)
            }
            if let cid = p.budgetyCanonicalID, cid == pid {
                return nameFromIdentity(p.userIdentity)
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    #if !os(watchOS)
    @MainActor
    private func nameFromIdentity(_ identity: CKUserIdentity) -> String? {
        if let nc = identity.nameComponents {
            let formatted = PersonNameComponentsFormatter().string(from: nc)
            if !formatted.isEmpty { return formatted }
        }
        if let email = identity.lookupInfo?.emailAddress, !email.isEmpty {
            return email
        }
        return nil
    }
    #endif

    /// 支払者の Member を引く。Member は Private ストアにしか存在しないが、
    /// id / recordName / 名前のいずれかで見つかれば Shared ストアの Expense でも返す
    /// (= 自分が払った共有支出や、他端末で作られた支出を編集するときに支払者が解決できるように)。
    @MainActor
    var resolvedPayer: Member? {
        // 支払者の identity は payerProfileID で判定する。共有シートの場合は
        // canonicalSelfIDs (シート用 canonical + 旧 userRecordName) と照合し、
        // 旧 ID が残っていても「自分」として解決できるようにする。
        let pc = PersistenceController.shared
        let ctx = managedObjectContext ?? pc.container.viewContext
        guard let pid = payerProfileID, !pid.isEmpty else { return nil }

        // 1) 自分: payerProfileID が canonical self ID 群のいずれかと一致 → selfMember
        #if !os(watchOS)
        let share: CKShare? = sheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
        #else
        let share: CKShare? = nil
        #endif
        let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
        if selfIDs.contains(pid),
           let selfID = UserProfileStore.shared.selfMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", selfID as CVarArg)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first { return m }
        }
        // 2) 他人: Member.recordName == payerProfileID
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.predicate = NSPredicate(format: "recordName == %@", pid)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    /// `generatedFromRuleID` から元の RecurringRule を引く (定期から生成された支出のみ非 nil)。
    var relatedRule: RecurringRule? {
        guard let id = generatedFromRuleID else { return nil }
        let ctx = managedObjectContext ?? PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<RecurringRule>(entityName: "RecurringRule")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    /// 同シート配下の ParticipantProfile を引く。recordName 一致 → displayName 一致の順。
    var resolvedParticipantProfile: ParticipantProfile? {
        guard let sheet = sheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        // 1) recordName 一致
        if let pid = payerProfileID, !pid.isEmpty,
           let pp = profiles.first(where: { $0.recordName == pid }) {
            return pp
        }
        // 2) displayName 一致 (旧データ移行用)
        guard let name = paidBy, !name.isEmpty else { return nil }
        return profiles.first(where: { $0.displayName == name })
    }

    var amountDecimal: Decimal {
        get { (amount ?? 0) as Decimal }
        set { amount = NSDecimalNumber(decimal: newValue) }
    }

    /// 受益者の profileID リスト (誰の負担として扱うか)。
    /// 内部表現: `beneficiaryProfileIDs` カンマ区切り文字列。空文字 = 「シートの全メンバーで均等割り」。
    var beneficiaryIDList: [String] {
        get {
            (beneficiaryProfileIDs ?? "")
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            // 重複と空文字を除去してから join
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            beneficiaryProfileIDs = cleaned.joined(separator: ",")
        }
    }

    /// 精算計算で使う実効受益者リスト。
    /// 空 (= 未指定 / 旧データ) ならシートの全メンバー、設定済ならそのまま返す。
    @MainActor
    func resolvedBeneficiaryIDs() -> [String] {
        let list = beneficiaryIDList
        if !list.isEmpty { return list }
        return sheet?.allMemberProfileIDs() ?? []
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw ?? "") ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// 通貨コード (空なら親シートの既定 → JPY)
    var resolvedCurrencyCode: String {
        if let c = currencyCode, !c.isEmpty { return c }
        if let s = sheet?.resolvedDefaultCurrencyCode, !s.isEmpty { return s }
        return CurrencyCatalog.defaultCode
    }

    /// 通貨記号付きの金額表示 (符号は kind に応じて変える呼び出し元で扱う)
    var formattedAmount: String {
        CurrencyCatalog.format(amountDecimal, code: resolvedCurrencyCode)
    }

    /// 符号付き表示 (収入は正、支出は負として表現)
    var formattedSignedAmount: String {
        let sign = kind == .expense ? "-" : "+"
        return sign + formattedAmount
    }

    /// `category` リレーションが nil でも、`categoryRaw` (名前) とシートのカテゴリ集合から
    /// 一致するものを引いて返すフォールバック付きアクセサ。
    /// Shared/Private のクロスストアで linkage が外れたケースでも、表示が正しく出るようにする。
    var resolvedCategory: ExpenseCategory? {
        if let c = category { return c }
        guard let raw = categoryRaw, !raw.isEmpty,
              let sheet = sheet,
              let cats = sheet.categories as? Set<ExpenseCategory> else { return nil }
        return cats.first(where: { $0.name == raw })
    }

    var categoryDisplayName: String {
        resolvedCategory?.displayName ?? (categoryRaw?.isEmpty == false ? categoryRaw! : "未分類")
    }

    var categoryTint: Color {
        resolvedCategory?.tint ?? .gray
    }

    var categorySymbol: String {
        resolvedCategory?.displaySymbol ?? "list.bullet"
    }
}

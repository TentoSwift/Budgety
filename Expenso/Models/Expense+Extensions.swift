//
//  Expense+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI

extension Expense {
    var displayTitle: String { title ?? "" }

    /// 表示名 / 色 / 写真: ParticipantProfile を優先する。
    /// ParticipantProfile はシートに紐付き CloudKit Sharing で常に最新が同期されるため、
    /// ローカル Member の denormalized キャッシュ (古い写真や旧名) より信頼できる。
    /// ParticipantProfile が無い場合だけ Member → 保存時の paidBy にフォールバックする。
    @MainActor
    var displayPaidBy: String {
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
        return resolvedPayer?.tint ?? .secondary
    }
    @MainActor
    var payerPhotoData: Data? {
        resolvedParticipantProfile?.photoData ?? resolvedPayer?.photoData
    }

    /// 支払者の Member を引く。Member は Private ストアにしか存在しないが、
    /// id / recordName / 名前のいずれかで見つかれば Shared ストアの Expense でも返す
    /// (= 自分が払った共有支出や、他端末で作られた支出を編集するときに支払者が解決できるように)。
    @MainActor
    var resolvedPayer: Member? {
        let pc = PersistenceController.shared
        let ctx = managedObjectContext ?? pc.container.viewContext
        // 1) payerMemberID (UUID) で直接 fetch (作成時に保存される最も信頼できる識別子)
        if let mid = payerMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", mid as CVarArg)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first { return m }
        }
        // 2) payerProfileID が UUID ならそれで fetch (旧データ救済)
        if let pid = payerProfileID, !pid.isEmpty,
           let uuid = UUID(uuidString: pid) {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first { return m }
        }
        // 3) payerProfileID が CK recordName で、それが自分の userRecordName と一致 → selfMember
        if let pid = payerProfileID, !pid.isEmpty,
           let rn = UserProfileStore.shared.userRecordName, rn == pid,
           let selfID = UserProfileStore.shared.selfMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", selfID as CVarArg)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first { return m }
        }
        // 4) payerProfileID が CK recordName と一致する Member.recordName
        if let pid = payerProfileID, !pid.isEmpty {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "recordName == %@", pid)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first { return m }
        }
        // 5) 名前一致 (旧データ移行用)
        guard let name = paidBy, !name.isEmpty else { return nil }
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.predicate = NSPredicate(format: "name == %@", name)
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
        resolvedCategory?.displaySymbol ?? "ellipsis.circle"
    }
}

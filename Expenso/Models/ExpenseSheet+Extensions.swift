//
//  ExpenseSheet+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI

extension ExpenseSheet {
    var displayName: String { name ?? "" }
    var displayColorHex: String { colorHex ?? "#5B8DEF" }

    /// シートのアクセントカラー (UI 全体の差し色として使う)
    var tint: SwiftUI.Color {
        SwiftUI.Color(hex: displayColorHex) ?? .indigo
    }

    var resolvedDefaultCurrencyCode: String {
        if let c = defaultCurrencyCode, !c.isEmpty { return c }
        return CurrencyCatalog.defaultCode
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
    /// 自分 (UserProfileStore.userRecordName) と ParticipantProfile.recordName を結合して返す。
    /// 受益者未指定の Expense を「全員均等割り」として扱う際の母集合。
    @MainActor
    func allMemberProfileIDs() -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        if let myRN = UserProfileStore.shared.userRecordName, !myRN.isEmpty,
           seen.insert(myRN).inserted {
            result.append(myRN)
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
    /// 1. 自分 (UserProfileStore.userRecordName 一致)
    /// 2. ParticipantProfile.recordName 一致 (= 共有相手のプロフィール)
    /// 3. ローカル Member の recordName 一致
    /// 4. ローカル Member の id (UUID) 一致 (旧データ救済)
    /// いずれにも一致しなければ "メンバー" の汎用表示。
    @MainActor
    func memberDisplayInfo(for profileID: String) -> (name: String, colorHex: String, photoData: Data?) {
        if let myRN = UserProfileStore.shared.userRecordName, profileID == myRN {
            let store = UserProfileStore.shared
            return (
                name: store.resolvedDisplayName,
                colorHex: store.avatarBgColorHex ?? "#5B8DEF",
                photoData: store.photoData
            )
        }
        let profiles = (participantProfiles as? Set<ParticipantProfile>) ?? []
        if let pp = profiles.first(where: { $0.recordName == profileID }) {
            return (
                name: pp.displayName?.isEmpty == false ? pp.displayName! : "メンバー",
                colorHex: pp.colorHex?.isEmpty == false ? pp.colorHex! : "#8E8E93",
                photoData: pp.photoData
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
}

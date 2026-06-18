//
//  SplitNotificationManager.swift
//  Budgety
//
//  「自分が割り勘の受益者に割り当てられた」支出を検出してローカル通知を出す。
//
//  契機:
//   - 起動時 (`.task`) … baseline の確定 + 既存データのサイレント既読化
//   - CloudKit のリモート変更 (`.NSPersistentStoreRemoteChange`) … 他メンバーの追加を検出
//   - バックグラウンドのサイレントプッシュ (AppDelegate.didReceiveRemoteNotification)
//
//  方針 (新規ぶんのみ通知):
//   - `baseline` (= 機能を初めて使った時刻) より後に作成された支出だけを対象にする。
//     これにより導入前の既存支出や、共有参加時に流れ込む過去ぶんで通知が溢れない。
//   - 通知済みの支出 (objectID URI) は記録し、二度と通知しない。
//   - 1 度の検出で複数件出た場合はまとめて 1 通 (= 大量通知を防ぐ)。
//

import Foundation
import CoreData
import UserNotifications

@MainActor
final class SplitNotificationManager {
    static let shared = SplitNotificationManager()

    private let center = UNUserNotificationCenter.current()

    /// 通知済み支出 (objectID URI 文字列)。重複通知を防ぐ。baseline 以降のものだけ溜まる。
    private static let notifiedKey = "BudgetySplitNotifiedExpenseIDs"
    /// この日時より後に作成された支出のみ通知する。初回アクセス時に「今」を記録。
    private static let baselineKey = "BudgetySplitNotifBaseline"

    private var notifiedIDs: Set<String>

    private init() {
        notifiedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
    }

    /// 通知の baseline。初回アクセスで「今」を確定し、以降は固定。
    private var baseline: Date {
        if let d = UserDefaults.standard.object(forKey: Self.baselineKey) as? Date { return d }
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.baselineKey)
        return now
    }

    private func persistNotifiedIDs() {
        // 無制限に増えないよう、上限を超えたら古いものから捨てる (順序は問わないので適当に間引く)。
        if notifiedIDs.count > 500 {
            notifiedIDs = Set(notifiedIDs.prefix(400))
        }
        UserDefaults.standard.set(Array(notifiedIDs), forKey: Self.notifiedKey)
    }

    // MARK: - 許可

    /// 通知許可を一度だけ要求する (未決定の時のみ)。
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - 検出

    /// リモート変更後などに呼ぶ。新しく自分に割り当てられた割り勘を検出して通知する。
    /// `baseline` 以降に作成され、まだ通知していない支出だけが対象。
    func processChanges(in context: NSManagedObjectContext) {
        let baselineDate = baseline
        let selfIDs = selfMatchIDs()
        guard !selfIDs.isEmpty else { return } // 自分の ID 不明 → 判定不能
        let selfMemberID = UserProfileStore.shared.selfMemberID

        let req = NSFetchRequest<Expense>(entityName: "Expense")
        // 支出 (収入は対象外) / 定期生成でない / baseline 以降に作成。
        req.predicate = NSPredicate(
            format: "kindRaw == %@ AND generatedFromRuleID == nil AND createdAt >= %@",
            "expense", baselineDate as NSDate
        )
        guard let expenses = try? context.fetch(req), !expenses.isEmpty else { return }

        var pending: [Expense] = []
        var changed = false

        for e in expenses {
            guard !e.objectID.isTemporaryID else { continue }
            let key = e.objectID.uriRepresentation().absoluteString
            guard !notifiedIDs.contains(key) else { continue }
            guard isAssignedToMe(e, selfIDs: selfIDs, selfMemberID: selfMemberID) else { continue }

            notifiedIDs.insert(key)
            changed = true
            pending.append(e)
        }

        if changed { persistNotifiedIDs() }
        guard !pending.isEmpty else { return }

        let payloads = pending.map { makePayload(for: $0) }
        Task { await postNotifications(payloads) }
    }

    /// 「自分とみなす」ID 集合 (URN + canonical + email)。
    private func selfMatchIDs() -> Set<String> {
        var ids = UserProfileStore.shared.canonicalSelfIDs(forShare: nil)
        if let email = UserProfileStore.shared.selfEmail?.lowercased(), !email.isEmpty {
            ids.insert("email:" + email)
        }
        return ids
    }

    /// この支出が「他メンバーから自分に割り当てられた割り勘」か。
    /// 条件: 自分が受益者 かつ 支払者が自分以外 (= 自分の支出ではない)。
    private func isAssignedToMe(_ e: Expense, selfIDs: Set<String>, selfMemberID: UUID?) -> Bool {
        let beneficiaries = Set(e.resolvedBeneficiaryIDs())
        guard !selfIDs.isDisjoint(with: beneficiaries) else { return false }

        let payer = e.payerProfileID ?? ""
        // 支払者が自分なら自分の支出 → 通知しない。
        if selfIDs.contains(payer) { return false }
        if let smid = selfMemberID, e.payerMemberID == smid { return false }
        // 支払者が一切不明なら「誰かに割り当てられた」と断定できない → 通知しない。
        if payer.isEmpty && e.payerMemberID == nil { return false }
        return true
    }

    // MARK: - 通知文面

    private struct Payload {
        let key: String
        let sheetName: String
        let payerName: String
        let title: String
        let shareText: String
    }

    private func makePayload(for e: Expense) -> Payload {
        let sheet = e.sheet
        let ids = e.resolvedBeneficiaryIDs()
        let share = e.amountDecimal / Decimal(max(ids.count, 1))
        let shareText = CurrencyCatalog.format(share, code: e.resolvedCurrencyCode)
        let payerName = sheet?.memberDisplayInfo(for: e.payerProfileID ?? "").name ?? String(localized: "メンバー")
        let title = e.displayTitle.isEmpty ? e.categoryDisplayName : e.displayTitle
        return Payload(
            key: e.objectID.uriRepresentation().absoluteString,
            sheetName: sheet?.displayName ?? String(localized: "シート"),
            payerName: payerName,
            title: title,
            shareText: shareText
        )
    }

    private func postNotifications(_ payloads: [Payload]) async {
        // 許可が無ければ何もしない (要求済みで拒否されている等)。
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default

        let identifier: String
        if payloads.count == 1 {
            let p = payloads[0]
            content.title = p.sheetName
            content.body = String(localized: "\(p.payerName)さんが「\(p.title)」であなたに \(p.shareText) を割り当てました")
            identifier = "split-\(p.key)"
        } else {
            content.title = String(localized: "新しい割り勘")
            content.body = String(localized: "あなたに \(payloads.count) 件の割り勘が割り当てられました")
            content.badge = NSNumber(value: payloads.count)
            identifier = "split-summary-\(Int(Date().timeIntervalSince1970))"
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }
}

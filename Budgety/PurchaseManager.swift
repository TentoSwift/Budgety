//
//  PurchaseManager.swift
//  Expenso
//

import Foundation
import StoreKit
import Combine
import CoreData
import os

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    enum Plan: String, CaseIterable, Identifiable {
        case monthly = "com.tento.Budgety.subscription.monthly"
        case yearly  = "com.tento.Budgety.subscription.yearly"
        case lifetime = "com.tento.Budgety.premium.lifetime"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .monthly: "月額"
            case .yearly: "年額"
            case .lifetime: "買い切り"
            }
        }

        var subtitle: String {
            switch self {
            case .monthly: "毎月自動更新"
            case .yearly: "毎年自動更新 (2ヶ月分お得)"
            case .lifetime: "一度の支払いで永続"
            }
        }
    }

    static let premiumProductIDs: Set<String> = Set(Plan.allCases.map(\.rawValue))
    private static let isPremiumKey = "ExpensoIsPremium"
    /// Premium が切れた時に共有解除をリトライするためのフラグ。
    /// `revokeAllOwnedShares` が成功するまで立ち続ける。
    private static let sharesRevocationPendingKey = "ExpensoSharesRevocationPending"

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedIDs: Set<String> = []
    @Published var isProcessing: Bool = false
    @Published var lastError: String?

    private var updateListener: Task<Void, Never>?

    static var isPremiumCached: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EXPENSO_PREMIUM"] == "1" { return true }
        #endif
        return UserDefaults.standard.bool(forKey: isPremiumKey)
    }

    var isPremium: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EXPENSO_PREMIUM"] == "1" { return true }
        #endif
        return !purchasedIDs.intersection(Self.premiumProductIDs).isEmpty
    }

    var activePlan: Plan? {
        Plan.allCases.first { purchasedIDs.contains($0.rawValue) }
    }

    func product(for plan: Plan) -> Product? {
        products.first { $0.id == plan.rawValue }
    }

    init() {
        updateListener = Task { @MainActor [weak self] in
            await self?.refreshEntitlements()
            await self?.listenForUpdates()
        }
    }

    deinit {
        updateListener?.cancel()
    }

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.premiumProductIDs)
            self.products = loaded.sorted { lhs, rhs in
                let order: [String: Int] = [
                    Plan.lifetime.rawValue: 0,
                    Plan.yearly.rawValue: 1,
                    Plan.monthly.rawValue: 2
                ]
                return (order[lhs.id] ?? 99) < (order[rhs.id] ?? 99)
            }
        } catch {
            lastError = "商品の読み込みに失敗しました: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        // 防御的ガード: 既に Premium を所有しているなら二重購入させない。
        // 通常は PaywallView 側で購入 UI を隠しているが、別経路から呼ばれても
        // 重複購入が通らないよう、モデル層でも弾く (買い切り×サブスク併売対策)。
        guard !isPremium else { return false }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    return true
                case .unverified:
                    lastError = "購入の検証に失敗しました。"
                    return false
                }
            case .userCancelled:
                return false
            case .pending:
                lastError = "購入処理が保留中です。承認後に反映されます。"
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "購入できませんでした: \(error.localizedDescription)"
            return false
        }
    }

    func restore() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = "購入の復元に失敗しました: \(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        let wasPremium = UserDefaults.standard.bool(forKey: Self.isPremiumKey)

        var ids: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.revocationDate == nil {
                    ids.insert(transaction.productID)
                }
            }
        }
        purchasedIDs = ids
        let nowPremium = !ids.intersection(Self.premiumProductIDs).isEmpty
        UserDefaults.standard.set(nowPremium, forKey: Self.isPremiumKey)

        // Premium → 非 Premium に切り替わった時:
        // 1) AppStore.sync で再確認 (transient 失敗で誤判定しないよう保険)
        // 2) それでも非 Premium が確定 → revokeAllOwnedShares で全 CKShare の
        //    参加者を削除 + 公開リンクを無効化
        // 3) 通知を投げて UI に「Premium が終了しました。共有を解除しました」を出す
        // 注: 「毎回の refresh で必ず走る」ような Core Data 書き込みは、招待中の
        //     persistUpdatedShare とぶつかって main actor がデッドロックする
        //     (= 過去に確認済み) ので、必ず transition (wasPremium && !nowPremium)
        //     の時だけ走らせる。
        Self.purchaseLog.debug("refreshEntitlements: was=\(wasPremium) now=\(nowPremium) ids=\(ids.joined(separator: ","))")

        // 解除すべき状態を 2 種類検知:
        //   A. 真の transition (wasPremium && !nowPremium) — toast を出す
        //   B. 状態不整合 (!nowPremium かつ active な共有 or ロック済みシートが残っている)
        //      — 過去に transition を取りこぼしている、または前回 revoke が失敗
        //      → 黙って revoke を再試行
        //
        // どちらも `confirmExpiry()` (= AppStore.sync 後の再確認) を挟むので
        // transient な StoreKit 失敗で誤検知して revoke してしまうのを防ぐ。
        //
        // 重要: 前回 revoke が transient failure (ネットワーク等) で失敗した場合に
        // 必ず再試行されるよう、`!nowPremium` の間は毎回 hasActiveOwnedShares を
        // チェックする (= ローカルの fast-path skip だけに頼らない)。
        if !nowPremium {
            let isTransition = wasPremium
            Task { @MainActor in
                // 必ず active な共有の有無をリモートでも確認 (= revoke 再試行のトリガ)
                let hasActiveShares = await ShareCoordinator.shared.hasActiveOwnedShares()
                guard isTransition || hasActiveShares else {
                    Self.purchaseLog.debug("non-premium but nothing to clean; skip")
                    return
                }
                let confirmedExpired = await Self.confirmExpiry()
                Self.purchaseLog.debug("non-premium with residue; confirmExpiry → \(confirmedExpired)")
                guard confirmedExpired else { return }
                let revokedOK = await Self.performExpiryRevoke()
                if !revokedOK {
                    // revoke 失敗 → 次回 refresh で再試行されるよう、ここでは
                    // 通知は出さない (UI に「終了しました」と出しても共有が
                    // 残っているのは矛盾するため)。
                    Self.purchaseLog.error("performExpiryRevoke failed; will retry on next refresh")
                    return
                }
                if isTransition {
                    NotificationCenter.default.post(name: .expensoPremiumExpired, object: nil)
                }
            }
        }
    }

    /// 期限切れ確定時の共有解除処理。テスト用に Settings から
    /// `runExpiryRevokeForDebug()` でも呼べるよう独立メソッドにしてある。
    /// - 共有 (CKShare) の解除のみ行う。シートのパスワードロックは Premium が切れても
    ///   そのまま維持する (= ユーザーが設定したロックを勝手に外さない)。新規ロックの追加は
    ///   UI 側で Premium gate される。既存ロックはパスワードで通常どおり解錠できる。
    /// - Returns: 共有解除が成功したか。`false` の場合、`refreshEntitlements` 側で次回再試行される。
    @MainActor
    @discardableResult
    static func performExpiryRevoke() async -> Bool {
        let ok = await ShareCoordinator.shared.revokeAllOwnedShares()
        purchaseLog.debug("revokeAllOwnedShares returned \(ok)")
        return ok
    }

    #if DEBUG
    /// デバッグ用: 「Premium が切れた時の解除フロー」を強制的に走らせる。
    /// 実際の StoreKit 状態は触らない。
    @MainActor
    static func runExpiryRevokeForDebug() async {
        purchaseLog.debug("DEBUG: runExpiryRevokeForDebug invoked")
        await performExpiryRevoke()
        NotificationCenter.default.post(name: .expensoPremiumExpired, object: nil)
    }
    #endif

    private static let purchaseLog = Logger(subsystem: "com.tento.Expenso", category: "purchase")

    /// `AppStore.sync()` で App Store と同期し直してから、もう 1 度
    /// `Transaction.currentEntitlements` を走査して本当に Premium が無いか確認する。
    /// transient な StoreKit エラー (= 一時的に entitlement が空) で誤って
    /// 共有を消さないための二段確認。
    /// - Returns: 再確認しても非 Premium なら `true` (= 解除して OK)
    @MainActor
    private static func confirmExpiry() async -> Bool {
        try? await AppStore.sync()
        var ids: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil {
                ids.insert(t.productID)
            }
        }
        let stillNotPremium = ids.intersection(premiumProductIDs).isEmpty
        if !stillNotPremium {
            // transient だった → Premium 状態を再確立
            UserDefaults.standard.set(true, forKey: isPremiumKey)
            shared.purchasedIDs = ids
        }
        return stillNotPremium
    }

    private func listenForUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                await refreshEntitlements()
            }
        }
    }
}

extension Notification.Name {
    static let expensoPremiumExpired = Notification.Name("ExpensoPremiumExpired")
}

// MARK: - Free-tier gating

/// 無料プランの上限値。Premium がいれば常に無効化される。
enum FreeTierLimits {
    /// 1 シートあたりのカテゴリ最大数 (デフォルト seed 15 + 5 のゆとり)
    static let categoriesPerSheet: Int = 20
    /// 自分が「所有」できるシートの最大数 (= 自分が作成したシートのみカウント、
    /// 共有受け入れシートは数えない)
    static let ownedSheets: Int = 3
}

extension PurchaseManager {
    /// 自分自身が Premium なら true。propagatePremiumFlag が UserDefaults に
    /// キャッシュしているのでメインスレッド外でも参照できる。
    static var isCurrentUserPremium: Bool { isPremiumCached }

    /// このシート上で課金機能 (カテゴリ無制限・エクスポート・プレミアムアイコン等) が
    /// 使えるか。
    /// 1. 自分が Premium → どのシートでも使える。
    /// 2. 共有されたシート (= 自分が所有者でない参加者側のシート) → 使える。
    ///    シートを共有するにはオーナーが Premium である必要があるため、その共有
    ///    シートに参加しているユーザーも、そのシート上では課金機能を使える。
    static func hasPremiumAccess(to sheet: ExpenseSheet) -> Bool {
        if isCurrentUserPremium { return true }
        // 自分が所有していない = Shared ストアにある = Premium オーナーが共有した
        // シート。参加者も課金機能を使える。
        if !sheet.isOwnedByCurrentUser { return true }
        return false
    }

    /// 指定シートに新しいカテゴリを 1 つ追加できるか。
    /// 上限は `FreeTierLimits.categoriesPerSheet`。
    /// シートが課金アクセス可 (自分が Premium、または共有シート) なら上限を無視できる。
    static func canAddCategory(to sheet: ExpenseSheet) -> Bool {
        if hasPremiumAccess(to: sheet) { return true }
        let count = (sheet.categories as? Set<ExpenseCategory>)?.count ?? 0
        return count < FreeTierLimits.categoriesPerSheet
    }

    /// 新しい (= 自分所有の) シートを作成できるかの 4 値ゲート。
    /// - `.allowed`: そのまま作成して OK
    /// - `.waitingForSync`: CloudKit からの初回 import がまだ → ブロック
    /// - `.offline`: ネット未接続。Free tier では multi-device race を防ぐため
    ///   オンライン時のみ作成許可 → 接続を促す
    /// - `.overLimit`: Free 上限到達 → Paywall 案内
    enum SheetCreationGate {
        case allowed
        case notSignedIn
        case waitingForSync
        case offline
        case overLimit
    }

    @MainActor
    static func sheetCreationGate() -> SheetCreationGate {
        // iCloud 未サインインでは (Premium 有無に関わらず) シートを作成させない。
        if !PersistenceController.shared.iCloudAccountAvailable { return .notSignedIn }
        if isCurrentUserPremium { return .allowed }
        // 初回 import がまだ完了していない時は、既に CloudKit 上に上限分の
        // シートがある可能性を排除できないので保守的に block する。
        if !PersistenceController.shared.initialSyncComplete {
            return .waitingForSync
        }
        // Free tier はオフライン作成不可 (= 別端末との race window を縮小)。
        if !NetworkMonitor.shared.isOnline {
            return .offline
        }
        let ctx = PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(req)) ?? []
        let owned = sheets.filter { $0.isOwnedByCurrentUser }.count
        return owned < FreeTierLimits.ownedSheets ? .allowed : .overLimit
    }

    @MainActor
    static func canCreateOwnedSheet() -> Bool {
        sheetCreationGate() == .allowed
    }
}

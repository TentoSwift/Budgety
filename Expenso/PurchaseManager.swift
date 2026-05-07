//
//  PurchaseManager.swift
//  Expenso
//

import Foundation
import StoreKit
import Combine
import CoreData

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    enum Plan: String, CaseIterable, Identifiable {
        case monthly = "com.tento.Expenso.premium.monthly"
        case yearly  = "com.tento.Expenso.premium.yearly"
        case lifetime = "com.tento.Expenso.premium.lifetime"

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

        // Premium が切れた検出時は通知だけ出して、既存の共有は触らない。
        // 自動 revoke は StoreKit の transient 失敗 (currentEntitlements が一時的に空) で
        // 本物の Premium ユーザーの共有を誤って消すリスクが大きい。
        // 新規共有作成は UI 側で `isPremium` ゲートしているので、課金が切れた状態で
        // 共有が増えることはない。
        if wasPremium && !nowPremium {
            NotificationCenter.default.post(name: .expensoPremiumExpired, object: nil)
        }

        // 自分の Premium 状態を Core Data 側にミラー:
        //   - 自分が所有するシート → ExpenseSheet.ownerIsPremium
        //   - 参加中シートの自分の ParticipantProfile.isPremium
        // CloudKit 同期で他参加者にも届くので、彼らの「シート上限・カテゴリ上限」
        // 判定にも使える。
        await Self.propagatePremiumFlag(nowPremium)
    }

    /// 全シートを走査し、自分の Premium 状態をミラーリングする。
    /// `viewContext` を main で触るので `@MainActor` 必須。
    @MainActor
    private static func propagatePremiumFlag(_ premium: Bool) async {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext
        let myRecordName = UserProfileStore.shared.userRecordName ?? ""

        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(req)) ?? []

        var dirty = false
        for sheet in sheets {
            // 自分が所有するシート (Private store) は ownerIsPremium をミラー。
            if sheet.isOwnedByCurrentUser {
                if sheet.ownerIsPremium != premium {
                    sheet.ownerIsPremium = premium
                    dirty = true
                }
            }
            // すべてのシートで、自分の ParticipantProfile に isPremium を反映。
            // (オーナーでも自分の ParticipantProfile を持つ運用)
            if !myRecordName.isEmpty,
               let profiles = sheet.participantProfiles as? Set<ParticipantProfile>,
               let mine = profiles.first(where: { $0.recordName == myRecordName }) {
                if mine.isPremium != premium {
                    mine.isPremium = premium
                    mine.updatedAt = .now
                    dirty = true
                }
            }
        }
        if dirty {
            pc.save()
        }
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
    static let ownedSheets: Int = 5
}

extension PurchaseManager {
    /// 自分自身が Premium なら true。propagatePremiumFlag が UserDefaults に
    /// キャッシュしているのでメインスレッド外でも参照できる。
    static var isCurrentUserPremium: Bool { isPremiumCached }

    /// 指定シートに新しいカテゴリを 1 つ追加できるか。
    /// 上限は `FreeTierLimits.categoriesPerSheet`。
    /// シート上に Premium が 1 人でもいれば (= ownerIsPremium or
    /// 任意の participantProfile.isPremium) 上限を無視できる。
    static func canAddCategory(to sheet: ExpenseSheet) -> Bool {
        if isCurrentUserPremium { return true }
        if sheet.ownerIsPremium { return true }
        if let profiles = sheet.participantProfiles as? Set<ParticipantProfile>,
           profiles.contains(where: { $0.isPremium }) {
            return true
        }
        let count = (sheet.categories as? Set<ExpenseCategory>)?.count ?? 0
        return count < FreeTierLimits.categoriesPerSheet
    }

    /// 新しい (= 自分所有の) シートを作成できるかの 3 値ゲート。
    /// - `.allowed`: そのまま作成して OK
    /// - `.waitingForSync`: CloudKit からの初回 import がまだ。後から既存シート
    ///    が降ってきて上限超過になる恐れがあるので一旦ブロック
    /// - `.overLimit`: Free 上限到達 → Paywall 案内
    enum SheetCreationGate {
        case allowed
        case waitingForSync
        case overLimit
    }

    @MainActor
    static func sheetCreationGate() -> SheetCreationGate {
        if isCurrentUserPremium { return .allowed }
        // 初回 import がまだ完了していない時は、既に CloudKit 上に上限分の
        // シートがある可能性を排除できないので保守的に block。
        if !PersistenceController.shared.initialSyncComplete {
            return .waitingForSync
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

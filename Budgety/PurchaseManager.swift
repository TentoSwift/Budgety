import Combine
import Foundation

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()
    let isPremium = true
    nonisolated static let isPremiumCached = true
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
    nonisolated static let isCurrentUserPremium = true
    static func hasPremiumAccess(to sheet: ExpenseSheet) -> Bool { true }
    static func canAddCategory(to sheet: ExpenseSheet) -> Bool { true }
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
        return .allowed
    }
    @MainActor
    static func canCreateOwnedSheet() -> Bool {
        sheetCreationGate() == .allowed
    }
}

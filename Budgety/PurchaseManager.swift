import Combine
import Foundation

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()
    let isPremium = true
}
extension Notification.Name {
    static let expensoPremiumExpired = Notification.Name("ExpensoPremiumExpired")
}

extension PurchaseManager {
    nonisolated static let isCurrentUserPremium = true
    static func hasPremiumAccess(to sheet: ExpenseSheet) -> Bool { true }
}

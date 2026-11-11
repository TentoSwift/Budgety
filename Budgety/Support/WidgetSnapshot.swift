#if os(iOS)
import Foundation
import Security

nonisolated struct WidgetSheetSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    // Optional so selections cached by earlier releases remain readable until the app next publishes.
    let symbol: String?
    let colorHex: String?
    let monthStart: Date
    let expense: Decimal
    let income: Decimal
    let currency: String
    let missingRates: Bool
}

nonisolated enum WidgetSheetStore {
    static let kind = "BudgetySheetWidget"

    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BudgetyWidgetAccessGroup") as? String,
              !group.isEmpty else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: "BudgetySheetWidget",
            kSecAttrAccount as String: "snapshots",
            kSecAttrSynchronizable as String: false
        ]
    }

    private static func storedData(_ query: [String: Any]) -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func read() -> [WidgetSheetSnapshot] {
        guard let query, let data = storedData(query),
              let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return [] }
        return (try? JSONDecoder().decode([WidgetSheetSnapshot].self, from: json)) ?? []
    }

    /// A single compressed item keeps replacement atomic for both picker and timeline readers.
    static func replace(with sheets: [WidgetSheetSnapshot]) -> Bool {
        guard let query else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let json = try encoder.encode(sheets)
            let data = try (json as NSData).compressed(using: .lzfse) as Data
            if storedData(query) == data { return false }
            let values: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecSuccess { return true }
            if status == errSecItemNotFound {
                let item = query.merging(values) { _, new in new }
                if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return true }
            }
        } catch {
            // Fall through to removing any stale data, especially after a lock change.
        }
        SecItemDelete(query as CFDictionary)
        return true
    }
}
#endif

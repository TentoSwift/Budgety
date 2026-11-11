#if os(iOS)
import Foundation
import Security

/// The widget and app read the same scheme, distinct for development installations.
nonisolated enum WidgetSheetLink {
    private static var scheme: String? {
        Bundle.main.object(forInfoDictionaryKey: "BudgetyWidgetURLScheme") as? String
    }

    static func url(for identifier: String) -> URL? {
        guard let scheme, isSheetURI(identifier) else { return nil }
        var link = URLComponents()
        link.scheme = scheme
        link.host = "sheet"
        link.queryItems = [URLQueryItem(name: "id", value: identifier)]
        return link.url
    }

    static func sheetIdentifier(from url: URL) -> String? {
        guard let scheme, let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              link.scheme == scheme, link.host == "sheet", link.path.isEmpty,
              link.user == nil, link.password == nil, link.port == nil, link.fragment == nil,
              let items = link.queryItems, items.count == 1, items[0].name == "id",
              let id = items[0].value, isSheetURI(id) else { return nil }
        return id
    }

    private static func isSheetURI(_ value: String) -> Bool {
        guard let uri = URL(string: value), uri.scheme == "x-coredata", uri.host != nil,
              uri.pathComponents.count == 3, uri.pathComponents[1] == "ExpenseSheet",
              uri.query == nil, uri.fragment == nil else { return false }
        return true
    }
}

nonisolated struct WidgetSheetSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    // Optional so selections cached by earlier releases remain readable until the app next publishes.
    let symbol: String?
    let colorHex: String?
    var monthStart: Date
    var expense: Decimal
    var income: Decimal
    let currency: String
    var missingRates: Bool

    // Optional fields let installed widgets read snapshots published by earlier versions.
    var dailyExpenses: [Decimal]?
    var recentExpenses: [WidgetExpenseRow]?
    var recentExpenseCount: Int?
    var ledger: WidgetLedgerWindow?

    /// Resolve against the entry's calendar day, including midnight and month changes
    /// when the app is suspended. Nothing scheduled after that day enters the widget.
    func displayed(at date: Date, calendar: Calendar = .current) -> Self? {
        guard let ledger else {
            return calendar.isDate(monthStart, equalTo: date, toGranularity: .month) ? self : nil
        }
        let today = calendar.startOfDay(for: date)
        guard ledger.timeZoneID == calendar.timeZone.identifier, today.compare(ledger.firstDisplayDay) != .orderedAscending,
              today.compare(ledger.lastDisplayDay) != .orderedDescending, let month = calendar.dateInterval(of: .month, for: today),
              let firstRecent = calendar.date(byAdding: .day, value: 1 - WidgetLedgerWindow.recentDayCount, to: today),
              let slot = calendar.ordinality(of: .day, in: .month, for: today) else { return nil }

        var result = self
        result.ledger = nil
        result.monthStart = month.start
        result.expense = 0
        result.income = 0
        result.missingRates = false
        var daily = Array(repeating: Decimal.zero, count: slot)
        var rows: [WidgetExpenseRow] = []
        var count = 0
        // Ledger days and each day's rows are sorted newest first.
        for day in ledger.days where day.date.compare(today) != .orderedDescending {
            if day.date.compare(month.start) != .orderedAscending, let daySlot = calendar.ordinality(of: .day, in: .month, for: day.date),
               daily.indices.contains(daySlot - 1) {
                daily[daySlot - 1] = day.expense
                result.expense += day.expense
                result.income += day.income
                result.missingRates = result.missingRates || day.missingRates
            }
            if day.date.compare(firstRecent) != .orderedAscending {
                count += day.count
                rows.append(contentsOf: day.rows.prefix(WidgetExpenseRow.limit - rows.count))
            }
        }
        result.dailyExpenses = daily
        result.recentExpenses = rows
        result.recentExpenseCount = count
        return result
    }
}

nonisolated struct WidgetExpenseRow: Codable, Equatable, Sendable {
    static let limit = 4
    let date: Date
    let title: String
    let category: String
    let symbol: String
    let colorHex: String
    let amount: Decimal
    let currency: String
    var payerName: String?
    var payerColorHex: String?
    var payerThumbnail: Data?
}

nonisolated struct WidgetLedgerDay: Codable, Equatable, Sendable {
    let date: Date
    var expense: Decimal = 0
    var income: Decimal = 0
    var missingRates = false
    var count = 0
    var rows: [WidgetExpenseRow] = []
}

nonisolated struct WidgetLedgerWindow: Codable, Equatable, Sendable {
    static let recentDayCount = 30
    let firstDisplayDay: Date
    let lastDisplayDay: Date
    let timeZoneID: String
    let days: [WidgetLedgerDay]
}

nonisolated enum WidgetSheetStore {
    static let kind = "BudgetySheetWidget"
    static let chartKind = "BudgetyExpenseChartWidget"

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

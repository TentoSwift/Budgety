#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import Foundation

@available(iOS 27.3, *)
enum SiriExpensePeriod: String, AppEnum {
    case thisMonth, lastMonth, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "検索期間"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .thisMonth: "今月", .lastMonth: "先月", .allTime: "全期間"
    ]

    func month(relativeTo now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .thisMonth: return now
        case .lastMonth: return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .allTime: return nil
        }
    }
}

@available(iOS 27.3, *)
struct SiriExpenseSearchFilter {
    let name: String?
    let month: Date?

    init(expenseName: String?, month: Date?, period: SiriExpensePeriod?,
         unnamedPeriod: SiriExpensePeriod = .thisMonth, now: Date = .now, calendar: Calendar = .current) {
        let text = (expenseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenPeriod = Self.periodInQuestion(text)
        name = text.isEmpty || spokenPeriod != nil ? nil : text
        let scope = period ?? spokenPeriod ?? (name == nil ? unnamedPeriod : .allTime)
        self.month = month ?? scope.month(relativeTo: now, calendar: calendar)
    }

    // The Home Screen shortcut passes its entire text field as expenseName. Only consume
    // complete questions so names containing a month, such as 「今月のランチ」, remain searchable.
    private static func periodInQuestion(_ text: String) -> SiriExpensePeriod? {
        let question = text.filter { !$0.isWhitespace }
            .trimmingCharacters(in: CharacterSet(charactersIn: "?？。！!"))
            .replacingOccurrences(of: "ししゅつ", with: "支出")
        let phrases: [(String, SiriExpensePeriod)] = [("今月", .thisMonth), ("先月", .lastMonth), ("全期間", .allTime)]
        for (prefix, period) in phrases where question.hasPrefix(prefix) {
            switch question.dropFirst(prefix.count) {
            case "の支出", "の支出は", "の支出はいくら", "の支出はいくらですか", "の支出を教えて", "の支出を見せて":
                return period
            default: break
            }
        }
        return nil
    }
}
#endif

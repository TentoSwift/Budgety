#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import Foundation

@available(iOS 27.3, *)
enum SiriExpensePeriod: String, AppEnum {
    case today, yesterday, thisMonth, lastMonth, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "検索期間"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "今日", .yesterday: "昨日", .thisMonth: "今月", .lastMonth: "先月", .allTime: "全期間"
    ]

    fileprivate var isDay: Bool { self == .today || self == .yesterday }
}

@available(iOS 27.3, *)
struct SiriExpenseScope {
    // Treat the interval as half-open. Keep the bounds and label when Siri redraws the snippet.
    let interval: DateInterval?
    let label: String
    let isDay: Bool
}

@available(iOS 27.3, *)
extension SiriExpenseScope {
    fileprivate init(containing date: Date, isDay: Bool, calendar: Calendar) {
        // Never widen a specific day or month into an all-time search if the date is unrepresentable.
        let interval = calendar.dateInterval(of: isDay ? .day : .month, for: date) ?? DateInterval(start: date, duration: 0)
        let format = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .year().month(.wide)
        self.init(interval: interval, label: date.formatted(isDay ? format.day() : format), isDay: isDay)
    }

    fileprivate init(period: SiriExpensePeriod, now: Date, calendar: Calendar) {
        switch period {
        case .allTime:
            self.init(interval: nil, label: String(localized: "全期間"), isDay: false)
        case .today, .thisMonth:
            self.init(containing: now, isDay: period.isDay, calendar: calendar)
        case .yesterday, .lastMonth:
            let component: Calendar.Component = period.isDay ? .day : .month
            let previous = calendar.date(byAdding: component, value: -1, to: now) ?? now
            self.init(containing: previous, isDay: period.isDay, calendar: calendar)
        }
    }
}

@available(iOS 27.3, *)
struct SiriExpenseSearchFilter {
    let name: String?
    let categoryName: String?
    let scope: SiriExpenseScope

    init(expenseName: String?, categoryName: String? = nil, month: Date?, day: Date? = nil, period: SiriExpensePeriod?,
         unnamedPeriod: SiriExpensePeriod = .thisMonth, now: Date = .now, calendar: Calendar = .current) {
        let text = (expenseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category = (categoryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.categoryName = category.isEmpty ? nil : category
        let question = Self.searchQuestion(text)
        let spokenPeriod = question?.period
        if let question {
            name = question.term
        } else {
            name = text.isEmpty ? nil : text
        }
        if let day {
            scope = SiriExpenseScope(containing: day, isDay: true, calendar: calendar)
        } else if let daily = [period, spokenPeriod].compactMap({ $0 }).first(where: \.isDay) {
            // Siri may also populate the month parameter while interpreting a question about a day.
            scope = SiriExpenseScope(period: daily, now: now, calendar: calendar)
        } else if let month {
            scope = SiriExpenseScope(containing: month, isDay: false, calendar: calendar)
        } else {
            let relative = period ?? spokenPeriod ?? (name == nil && self.categoryName == nil ? unnamedPeriod : .allTime)
            scope = SiriExpenseScope(period: relative, now: now, calendar: calendar)
        }
    }

    // The Home Screen shortcut passes its entire text field as expenseName. Only consume
    // complete questions so names containing a period, such as 「今日のランチ」, remain searchable.
    private static func searchQuestion(_ text: String) -> (period: SiriExpensePeriod, term: String?)? {
        let question = text.trimmingCharacters(in: CharacterSet(charactersIn: "?？。！!"))
        let phrases: [(String, SiriExpensePeriod)] = [
            ("今日", .today), ("きょう", .today), ("本日", .today),
            ("昨日", .yesterday), ("きのう", .yesterday),
            ("今月", .thisMonth), ("先月", .lastMonth), ("全期間", .allTime)
        ]
        for (prefix, period) in phrases where question.hasPrefix(prefix) {
            let rest = question.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard rest.hasPrefix("の") else { continue }
            let subject = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = subject.filter { !$0.isWhitespace }.replacingOccurrences(of: "ししゅつ", with: "支出")
            switch compact {
            case "支出", "支出は", "支出はいくら", "支出はいくらですか", "支出を教えて", "支出を見せて":
                return (period, nil)
            default: break
            }
            // Preserve the literal merchant name and spaces within it unless a question was asked.
            for suffix in ["はいくらですか", "はいくら", "を教えて", "を見せて", "は"] where subject.hasSuffix(suffix) {
                let term = subject.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty { return (period, term) }
            }
        }
        return nil
    }
}
#endif

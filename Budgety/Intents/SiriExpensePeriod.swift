#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import Foundation

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
enum SiriExpensePeriod: String, AppEnum {
    case today, yesterday, thisMonth, lastMonth, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "検索期間"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "今日", .yesterday: "昨日", .thisMonth: "今月", .lastMonth: "先月", .allTime: "全期間"
    ]

    fileprivate var isDay: Bool { self == .today || self == .yesterday }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseScope {
    // Treat the interval as half-open. Keep the bounds and label when Siri redraws the snippet.
    let interval: DateInterval?
    let label: String
    let isDay: Bool
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
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

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriTransactionReplyRequest {
    let search: String?
    let requestsAll: Bool

    init(_ search: String?) {
        let question = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?？。！!"))
        let quantityAtEnd = #/(?:(.+)を)?(?:すべて|全て|全部|全件)(?:を?(?:見せて|表示して|教えて)(?:ください)?)?/#
        if let match = question.wholeMatch(of: quantityAtEnd) {
            self.search = match.output.1.map(String.init)
            requestsAll = true
            return
        }
        let quantityBeforeSubject = #/((?:今日|きょう|本日|昨日|きのう|今月|先月|全期間)の)?(?:すべて|全て|全部|全件)の(明細|取引一覧|取引|支出|収入|収支)(?:を(?:見せて|表示して|教えて)(?:ください)?)?/#
        if let match = question.wholeMatch(of: quantityBeforeSubject) {
            self.search = (match.output.1.map(String.init) ?? "") + match.output.2
            requestsAll = true
            return
        }
        self.search = ["何がある", "何があるの", "どんな明細がある", "一覧にして", "一覧を見せて"].contains(question) ? nil : search
        requestsAll = false
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseSearchFilter {
    let name: String?
    let categoryName: String?
    let spokenKind: SiriTransactionSelection?
    let scope: SiriExpenseScope

    init(expenseName: String?, categoryName: String? = nil, month: Date?, day: Date? = nil, period: SiriExpensePeriod?,
         unnamedPeriod: SiriExpensePeriod = .thisMonth, isSpokenQuery: Bool = false,
         now: Date = .now, calendar: Calendar = .current) {
        let text = (expenseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category = (categoryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.categoryName = category.isEmpty ? nil : category
        let question = Self.searchQuestion(text, isSpokenQuery: isSpokenQuery)
        spokenKind = question?.kind
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
    private static func searchQuestion(_ text: String, isSpokenQuery: Bool) -> (period: SiriExpensePeriod?, term: String?, kind: SiriTransactionSelection?)? {
        let question = text.trimmingCharacters(in: CharacterSet(charactersIn: "?？。！!"))
        let phrases: [(String, SiriExpensePeriod)] = [
            ("今日", .today), ("きょう", .today), ("本日", .today),
            ("昨日", .yesterday), ("きのう", .yesterday),
            ("今月", .thisMonth), ("先月", .lastMonth), ("全期間", .allTime)
        ]
        for (prefix, period) in phrases where question.hasPrefix(prefix) {
            let rest = question.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if isSpokenQuery, rest.isEmpty { return (period, nil, nil) }
            guard rest.hasPrefix("の") else { continue }
            let subject = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            if let kind = transactionKind(in: subject) { return (period, nil, kind) }
            if isLedgerList(subject) { return (period, nil, nil) }
            // Preserve the literal merchant name and spaces within it unless a question was asked.
            for suffix in ["はいくらですか", "はいくら", "を教えて", "を見せて", "は"] where subject.hasSuffix(suffix) {
                let term = subject.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty { return (period, term, nil) }
            }
            if isSpokenQuery, !subject.isEmpty { return (period, subject, nil) }
        }
        if isLedgerList(question) { return (nil, nil, nil) }
        return transactionKind(in: question).map { (nil, nil, $0) }
    }

    private static func isLedgerList(_ subject: String) -> Bool {
        ["明細", "明細一覧", "取引", "取引一覧", "一覧"].contains(where: { name in
            ["", "は", "を見せて", "を教えて", "を一覧にして", "にして"].contains(where: { subject == name + $0 })
        })
    }

    private static func transactionKind(in subject: String) -> SiriTransactionSelection? {
        var text = subject.filter { !$0.isWhitespace }
        for suffix in ["はいくらですか", "はいくら", "を教えてください", "を教えて", "を見せて", "を一覧にして", "は"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        switch text {
        case "支出", "ししゅつ": return .expense
        case "収入", "しゅうにゅう": return .income
        case "収支", "収入と支出", "支出と収入", "収入・支出", "しゅうし": return .both
        default: return nil
        }
    }
}
#endif

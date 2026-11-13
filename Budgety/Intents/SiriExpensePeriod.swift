#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import Foundation

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
enum SiriExpensePeriod: String, AppEnum {
    case today, yesterday, thisMonth, lastMonth, thisYear, lastYear, lastSixMonths, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "検索期間"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "今日", .yesterday: "昨日", .thisMonth: "今月", .lastMonth: "先月", .thisYear: "今年", .lastYear: "昨年", .lastSixMonths: "直近半年（今月を含む6か月）", .allTime: "全期間"
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

    init(period: SiriExpensePeriod, now: Date, calendar: Calendar) {
        switch period {
        case .allTime:
            self.init(interval: nil, label: String(localized: "全期間"), isDay: false)
        case .lastSixMonths:
            let monthStart = calendar.dateInterval(of: .month, for: now)?.start
            let start = monthStart.flatMap { calendar.date(byAdding: .month, value: -5, to: $0) }
            let end = calendar.dateInterval(of: .day, for: now)?.end
            let interval = DateInterval(start: start ?? now, end: end ?? now)
            self.init(interval: interval, label: String(localized: "直近半年（今月を含む6か月）"), isDay: false)
        case .thisYear, .lastYear:
            let anchor = period == .lastYear ? calendar.date(byAdding: .year, value: -1, to: now) ?? now : now
            let interval = calendar.dateInterval(of: .year, for: anchor) ?? DateInterval(start: anchor, duration: 0)
            let label = anchor.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).year())
            self.init(interval: interval, label: label, isDay: false)
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
        let quantityBeforeSubject = #/((?:今日|きょう|本日|昨日|きのう|今月|先月|今年|去年|昨年|全期間)の)?(?:すべて|全て|全部|全件)の(明細|取引一覧|取引|支出|収入|収支)(?:を(?:見せて|表示して|教えて)(?:ください)?)?/#
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
        let candidates: [SiriExpensePeriod] = [period, spokenPeriod].compactMap { $0 }
        let multiMonthPeriods: [SiriExpensePeriod] = [.thisYear, .lastYear, .lastSixMonths]
        if let day {
            scope = SiriExpenseScope(containing: day, isDay: true, calendar: calendar)
        } else if let daily = candidates.first(where: \.isDay) {
            // Siri may also populate the month parameter while interpreting a question about a day.
            scope = SiriExpenseScope(period: daily, now: now, calendar: calendar)
        } else if let months = candidates.first(where: multiMonthPeriods.contains) {
            scope = SiriExpenseScope(period: months, now: now, calendar: calendar)
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
            ("今月", .thisMonth), ("先月", .lastMonth), ("今年", .thisYear), ("昨年", .lastYear), ("去年", .lastYear), ("全期間", .allTime)
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
            ["", "は", "を見せて", "を教えて", "を調べて", "を一覧にして", "にして"].contains(where: { subject == name + $0 })
        })
    }

    private static func transactionKind(in subject: String) -> SiriTransactionSelection? {
        var text = subject.filter { !$0.isWhitespace }
        for suffix in ["はいくらですか", "はいくら", "を教えてください", "を教えて", "を見せて", "を調べて", "には何がある", "を一覧にして", "は"] where text.hasSuffix(suffix) {
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
// A narrow fallback for the complete ranking phrase Siri sometimes places in `name`.
// Explicit AppIntent parameters remain authoritative at the call site.
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriSpokenRankingRequest {
    let rank: Int?
    let limit: Int?
    let sort: SiriAnalysisSort?
    let next: Bool
    let kind: SiriTransactionSelection?
    let period: SiriExpensePeriod?
    var isRanking: Bool { rank != nil || limit != nil || next }

    init(_ text: String?) {
        var phrase = (text ?? "").precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
            .trimmingCharacters(in: CharacterSet(charactersIn: "?？。！!"))
        for suffix in ["を教えてください", "を見せてください", "を表示してください", "を教えて", "を見せて", "を表示して", "はどれですか", "はどれ", "を調べて"] where phrase.hasSuffix(suffix) {
            phrase.removeLast(suffix.count)
            break
        }
        var parsedPeriod: SiriExpensePeriod?
        for (word, value) in [("今日", SiriExpensePeriod.today), ("きょう", .today), ("本日", .today), ("昨日", .yesterday), ("きのう", .yesterday), ("今月", .thisMonth), ("先月", .lastMonth), ("今年", .thisYear), ("去年", .lastYear), ("昨年", .lastYear), ("全期間", .allTime)] where phrase.hasPrefix(word + "の") {
            phrase.removeFirst(word.count + 1)
            parsedPeriod = value
            break
        }
        var parsedKind: SiriTransactionSelection?
        for (word, value) in [("支出", SiriTransactionSelection.expense), ("出費", .expense), ("収入", .income), ("収支", .both), ("取引", .both)] {
            if phrase.hasPrefix(word + "の") {
                phrase.removeFirst(word.count + 1)
                parsedKind = value
                break
            }
            if phrase.hasSuffix(word) {
                phrase.removeLast(word.count)
                if phrase.hasSuffix("の") { phrase.removeLast() }
                parsedKind = value
                break
            }
        }
        let numeral = "([0-9一二三四五六七八九十百千〇零]+)"
        func capture(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$"),
                  let match = expression.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
                  let range = Range(match.range(at: 1), in: phrase) else { return nil }
            return String(phrase[range])
        }
        var parsedRank: Int?
        var parsedLimit: Int?
        var parsedSort: SiriAnalysisSort?
        var parsedNext = false
        for (words, value) in [("高い|多い|大きい", SiriAnalysisSort.highest), ("安い|低い|少ない|小さい", .lowest), ("新しい", .newest), ("古い", .oldest)] {
            if let number = capture(numeral + "(?:番目|番め|つ目|つめ)に(?:" + words + ")") ?? capture("(?:" + words + ")(?:方|ほう)から" + numeral + "(?:番目|番め|つ目|つめ)") {
                parsedRank = Self.positiveInteger(number)
                parsedSort = value
                break
            }
            if let number = capture("(?:" + words + ")順(?:に|で)?" + numeral + "件") {
                parsedLimit = Self.positiveInteger(number)
                parsedSort = value
                break
            }
            if phrase.range(of: "^(?:一番|1番|最も|もっとも)(?:" + words + ")$", options: .regularExpression) != nil {
                parsedRank = 1
                parsedSort = value
                break
            }
            if phrase.range(of: "^(?:次に|その次に)(?:" + words + ")$", options: .regularExpression) != nil {
                parsedNext = true
                parsedSort = value
                break
            }
        }
        if parsedRank == nil, parsedLimit == nil, !parsedNext {
            if let number = capture("上から" + numeral + "(?:番目|番め|つ目|つめ)") {
                parsedRank = Self.positiveInteger(number)
            } else if ["次", "次の明細", "次の取引", "その次"].contains(phrase) {
                parsedNext = true
            }
        }
        let recognized = parsedRank != nil || parsedLimit != nil || parsedNext
        rank = parsedRank
        limit = parsedLimit
        sort = recognized ? parsedSort : nil
        next = parsedNext
        kind = recognized ? parsedKind : nil
        period = recognized ? parsedPeriod : nil
    }

    fileprivate static func positiveInteger(_ text: String) -> Int? {
        if let number = Int(text) { return number > 0 ? number : nil }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        var result = 0
        var digit: Int?
        var previousUnit = 10000
        for character in text {
            if let value = digits[character] {
                // Reject malformed mixed Japanese numerals such as 二三番目.
                guard digit == nil else { return nil }
                digit = value
            } else if let unit = units[character] {
                guard unit < previousUnit, digit != 0 else { return nil }
                result += (digit ?? 1) * unit
                digit = nil
                previousUnit = unit
            } else { return nil }
        }
        result += digit ?? 0
        return result > 0 ? result : nil
    }
}
// A monthly ranking asks about the total for a month, even when the question never says 月別.
// Only accept a complete month question, so a plain merchant name still reaches the ledger search.
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriSpokenMonthlyRanking {
    var period: SiriExpensePeriod?
    var category: String?
    var kind: SiriTransactionSelection?
    let sort: SiriAnalysisSort
    let rank: Int?
    let limit: Int?

    static func clauses(in text: String?) -> [Self] {
        guard let text, !text.isEmpty else { return [] }
        let phrase = text.precomposedStringWithCompatibilityMapping
            .replacing(#/[「」『』]/#, with: "")
            .replacing(#/(何月|どの月|教えて)\s*(?=今年|昨年|去年|直近|過去|全期間)/#) { String($0.1) + "\n" }
            .replacing(#/[?。!\n]+|(?:それから|それと|そして|あわせて|合わせて|あと)[、,]?|(?:と[、,]?|[、,])(?=(?:今年|昨年|去年|直近|過去|全期間))/#, with: "\n")
        let clauses = phrase.split(separator: "\n").map { $0.filter { !$0.isWhitespace } }.filter { !$0.isEmpty }
        let parsed = clauses.compactMap { Self(clause: $0) }
        return parsed.count == clauses.count ? parsed : []
    }

    private init?(clause: String) {
        var phrase = clause.replacing(#/^(?:[、,]|(?:(?i:Budgety)|バジェッティ|バジェティ)[での])+/#, with: "")
        if let periodMatch = phrase.prefixMatch(of: #/(今年|昨年|去年|全期間|(?:直近|過去)(?:の)?(?:半年|[6六][かカヶケ箇]月))(?:間)?(?:の中で|のうち|では|の|で|は)?[、,]?/#) {
            switch periodMatch.1 {
            case "今年": period = .thisYear
            case "昨年", "去年": period = .lastYear
            case "全期間": period = .allTime
            default: period = .lastSixMonths
            }
            phrase.removeSubrange(periodMatch.range)
        }
        let monthlyPhrasing = phrase.hasPrefix("月別") || phrase.hasPrefix("月ごと") || phrase.contains("月別の合計")
        phrase = phrase.replacing(#/^(?:月別|月ごと)(?:に見ると|にみると|では|で|の)?[、,]?/#, with: "")
        guard let match = phrase.firstMatch(of: #/(?:(?:一番|1番|いちばん|最も|もっとも)|([0-9一二三四五六七八九十百千]+)(?:番目|番め)に)?(高かった|高い|多かった|多い|安かった|安い|低かった|低い|少なかった|少ない)/#) else { return nil }
        let subject = String(phrase[..<match.range.lowerBound])
            .replacing(#/(?:が|の|は|で)?(?:月別の合計|合計額|合計|金額)?(?:が|の|は|で)?$/#, with: "")
        switch subject {
        case "支出", "出費": kind = .expense
        case "収入": kind = .income
        case "収支": kind = .both
        case "": break
        default: category = subject
        }
        sort = ["高かった", "高い", "多かった", "多い"].contains(match.2) ? .highest : .lowest
        let tail = String(phrase[match.range.upperBound...])
            .replacing(#/(?:を?(?:教えて|見せて|表示して|挙げて)(?:ください)?|ですか|でしたか)$/#, with: "")
        if let count = tail.wholeMatch(of: #/(月(?:を|は)?|順(?:に|で)?)([0-9一二三四五六七八九十百千]+)(つ|[かカヶケ箇]月|月|件)/#) {
            guard count.1.hasPrefix("月") || count.3.hasSuffix("月") else { return nil }
            guard match.1 == nil, let number = SiriSpokenRankingRequest.positiveInteger(String(count.2)) else { return nil }
            limit = number
            rank = nil
        } else {
            let monthAsked = ["月", "月は", "月はいつ", "月は何月", "月はどの月", "のは何月", "のはどの月", "のはいつの月"].contains(tail)
            guard monthAsked || (monthlyPhrasing && tail == "のはいつ") else { return nil }
            limit = nil
            if let ordinal = match.1 {
                guard let number = SiriSpokenRankingRequest.positiveInteger(String(ordinal)) else { return nil }
                rank = number
            } else { rank = 1 }
        }
    }
}
#endif

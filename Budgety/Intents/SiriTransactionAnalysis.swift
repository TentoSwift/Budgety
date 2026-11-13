#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
enum SiriAnalysisMode: String, AppEnum {
    case total, category, merchant, member, day, month, comparison, categoryIncrease, dailyAverage
    case transactions, currency, originalAmounts, exchangeRates, unconverted

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "集計方法"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .total: "合計だけ", .category: "カテゴリ別", .merchant: "店・明細名別", .member: "支払者・受取者別",
        .day: "日別", .month: "月別", .comparison: "期間を比較", .categoryIncrease: "増えたカテゴリ",
        .dailyAverage: "1日平均", .transactions: "明細一覧", .currency: "元の通貨別",
        .originalAmounts: "明細の元の金額と換算額", .exchangeRates: "換算レート", .unconverted: "換算できない明細"
    ]

    fileprivate var title: String {
        switch self {
        case .total: String(localized: "合計")
        case .category: String(localized: "カテゴリ別")
        case .merchant: String(localized: "店・明細名別")
        case .member: String(localized: "支払者・受取者別")
        case .day: String(localized: "日別")
        case .month: String(localized: "月別")
        case .comparison: String(localized: "期間比較")
        case .categoryIncrease: String(localized: "増えたカテゴリ")
        case .dailyAverage: String(localized: "1日平均")
        case .transactions: String(localized: "明細一覧")
        case .currency: String(localized: "元の通貨別")
        case .originalAmounts: String(localized: "元の金額と換算額")
        case .exchangeRates: String(localized: "換算レート")
        case .unconverted: String(localized: "換算できない明細")
        }
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
enum SiriAnalysisSort: String, AppEnum {
    case highest, lowest, newest, oldest
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "並べ方"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .highest: "金額が高い順", .lowest: "金額が低い順", .newest: "新しい順", .oldest: "古い順"
    ]
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriAnalysisRequest {
    var mode: SiriAnalysisMode
    var kind: SiriTransactionSelection = .expense
    var name: String?
    var category: String?
    var member: SiriSheetMemberEntity?
    var currency: String?
    var targetCurrency: String?
    var foreignOnly = false
    var groupByOriginal = false
    var excludedName: String?
    var excludedCategory: String?
    var excludedTransactionID: String?
    var selectedTransactionID: String?
    var minimum: Decimal?
    var maximum: Decimal?
    var minimumExclusive = false
    var maximumExclusive = false
    var limit: Int?
    /// One-based position in the ordered results; unlike limit, returns only that position.
    var rank: Int?
    var sort: SiriAnalysisSort?

    fileprivate var ranksMonthsByAmount: Bool {
        mode == .month && (sort == .highest || sort == .lowest || (sort == nil && rank != nil))
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriMonthlyRanking {
    let scope: SiriExpenseScope
    let sort: SiriAnalysisSort
    var rank: Int?
    var limit: Int?
    var category: String?
    var kind: SiriTransactionSelection?
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriAnalysisReport {
    enum Artwork {
        case category(symbol: String, colorHex: String)
        case member(name: String, colorHex: String, photo: Data?, isVirtual: Bool)
    }

    struct Row {
        var title: String
        var value: String
        var detail: String?
        var transactionID: String?
        var artwork: Artwork?
    }

    struct Section {
        let title: String
        let summary: String
        let rows: [Row]
        let note: String?
        var artwork: Artwork?
    }

    var title: String
    var scope: String
    var summary: String
    var rows: [Row] = []
    var sections: [Section] = []
    var matchingRowCount = 0
    var requestedRank: Int?

    func omittedRowCount(displayedCount: Int) -> Int {
        requestedRank == nil ? max(0, matchingRowCount - displayedCount) : 0
    }
    var note: String?
    var singleTransactionID: String?

    var dialog: String {
        if !sections.isEmpty {
            let answers = sections.map { [$0.summary, $0.note].compactMap { $0 }.joined(separator: " ") }
            return (answers + [scope, note].compactMap { $0 }).joined(separator: "\n")
        }
        let lines = rows.map { row in
            [row.title, row.value, row.detail].compactMap { $0 }.joined(separator: "　")
        }
        let remaining = omittedRowCount(displayedCount: rows.count)
        let more = remaining > 0 ? String(localized: "ほかに\(remaining)件あります。") : nil
        return ([summary, "\(scope)・\(title)"] + lines + [more, note].compactMap { $0 }).joined(separator: "\n")
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
@MainActor
enum SiriTransactionAnalysis {
    fileprivate struct Group: Hashable {
        let key: String
        let label: String
    }

    fileprivate struct Entry {
        let identifier: String
        let date: Date?
        let title: String
        let category: String
        let member: Group?
        let kind: TransactionKind
        let value: SiriTransactionValue
        var categoryArtwork: SiriAnalysisReport.Artwork?
        var memberArtwork: SiriAnalysisReport.Artwork?
    }

    private enum InputError: Error, CustomLocalizedStringResourceConvertible {
        case limit, rank, rankMode, bounds, comparison, monthlyRanking

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .limit: "表示件数には1以上の数を指定してください。"
            case .rank: "順位には1以上の数を指定してください。"
            case .rankMode: "順位を調べるには明細一覧または項目別の集計を指定してください。"
            case .bounds: "金額には0以上の数を指定し、上限は下限以上にしてください。"
            case .comparison: "比較する2つの期間を指定してください。"
            case .monthlyRanking: "月別の順位を調べる期間と、金額が高い順または低い順を指定してください。"
            }
        }
    }

    static func runMonthlyRankings(sheet: ExpenseSheet, access: IntentSheetAccess, request: SiriAnalysisRequest,
                                   rankings: [SiriMonthlyRanking]) throws -> SiriAnalysisReport {
        guard !rankings.isEmpty else { throw InputError.monthlyRanking }
        let reports = try rankings.map { ranking in
            guard ranking.sort == .highest || ranking.sort == .lowest else { throw InputError.monthlyRanking }
            var query = request
            query.mode = .month
            query.category = ranking.category ?? request.category
            query.kind = ranking.kind ?? request.kind
            query.sort = ranking.sort
            query.rank = ranking.rank
            query.limit = ranking.limit
            return try run(sheet: sheet, access: access, scope: ranking.scope, request: query)
        }
        var report = reports[0]
        if reports.count > 1 {
            report.sections = reports.flatMap(\.sections)
            report.rows = report.sections.flatMap(\.rows)
            report.matchingRowCount = report.rows.count
            report.summary = report.sections.map(\.summary).joined(separator: "\n")
            report.requestedRank = nil
        }
        return report
    }

    static func run(sheet: ExpenseSheet, access: IntentSheetAccess, scope: SiriExpenseScope, request: SiriAnalysisRequest,
                    comparison: SiriExpenseScope? = nil) throws -> SiriAnalysisReport {
        let stored = try access.resolve(sheet.objectID.uriRepresentation().absoluteString)
        if let limit = request.limit, limit <= 0 { throw InputError.limit }
        if let rank = request.rank {
            guard rank > 0 else { throw InputError.rank }
            guard ![.total, .dailyAverage, .comparison, .categoryIncrease].contains(request.mode) else { throw InputError.rankMode }
        }
        if [request.minimum, request.maximum].compactMap({ $0 }).contains(where: { !$0.isFinite || $0 < 0 }) {
            throw InputError.bounds
        }
        if let minimum = request.minimum, let maximum = request.maximum, minimum > maximum { throw InputError.bounds }
        let compares = request.mode == .comparison || request.mode == .categoryIncrease
        if compares && (scope.interval == nil || comparison?.interval == nil) { throw InputError.comparison }

        let currency = try SiriLedgerCurrency(groupByOriginal: request.groupByOriginal, targetCurrency: request.targetCurrency,
                                             sourceCurrency: request.currency, foreignOnly: request.foreignOnly)
        let target = currency.targetCurrency ?? stored.resolvedDefaultCurrencyCode.uppercased()
        func checkedID(_ id: String) throws -> String {
            switch try SiriVirtualExpenseLink.resolve(id, access: access) {
            case .stored(let expense):
                guard expense.sheet?.objectID == stored.objectID, !expense.hasPersistentChangedValues else {
                    throw AppIntentError.expenseUnavailable
                }
                return expense.objectID.uriRepresentation().absoluteString
            case .virtual(let occurrence, let owner, _):
                guard owner.objectID == stored.objectID else { throw AppIntentError.expenseUnavailable }
                return SiriVirtualExpenseLink.identifier(for: occurrence, in: stored)
            }
        }
        let selectedID = try request.selectedTransactionID.map(checkedID)
        let omittedID = try request.excludedTransactionID.map(checkedID)
        let roster = try (request.member != nil || request.mode == .member) ? SiriSheetMemberRoster(sheet: stored, access: access) : nil
        let member = try request.member.flatMap { try roster?.resolve($0) }
        let people = roster.map { roster in
            roster.members.filter { request.mode == .member || $0.id == member?.id }.map { candidate in
                (candidate, SiriMemberTransactionLookup.Payer(member: candidate, roster: roster, sheet: stored))
            }
        } ?? []
        let payer = member.flatMap { selected in people.first { $0.0.id == selected.id }?.1 }
        let legacyRules = (stored.recurringRules as? Set<RecurringRule> ?? [])
        let categories = (stored.categories as? Set<ExpenseCategory> ?? []).sorted {
            $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
        }
        var avatars: [String: SiriAnalysisReport.Artwork] = [:]
        func avatar(_ group: Group, profileID: String?, isSelf: Bool) -> SiriAnalysisReport.Artwork {
            if let cached = avatars[group.key] { return cached }
            let photo: Data?
            let color: String
            if isSelf {
                photo = UserProfileStore.shared.photoData
                color = UserProfileStore.shared.avatarBgColorHex ?? ""
            } else if let profileID, !profileID.isEmpty, !UserProfileStore.isSelfPlaceholderRecordName(profileID) {
                let info = stored.memberDisplayInfo(for: profileID)
                photo = info.photoData
                color = info.colorHex
            } else {
                photo = nil
                color = ""
            }
            let result = SiriAnalysisReport.Artwork.member(name: group.label, colorHex: color,
                                                           photo: SiriExpensePayer.thumbnail(from: photo)?.data,
                                                           isVirtual: UserProfileStore.isVirtualRecordName(profileID ?? ""))
            avatars[group.key] = result
            return result
        }
        let excludedCategory = TransactionSearchTerm(request.excludedCategory ?? "")
        let excludedTerm = TransactionSearchTerm(request.excludedName ?? "")
        // Payroll names are commonly stored under either Japanese spelling.
        let excludedNames = ["給料", "給与"].contains(where: excludedTerm.matchesCategory)
            ? ["給料", "給与"].map(TransactionSearchTerm.init) : [excludedTerm].filter { !$0.isEmpty }
        func entries(in interval: DateInterval?) throws -> [Entry] {
            var result: [Entry] = []
            try SiriTransactionLedger.forEach(sheet: stored, access: access, interval: interval,
                                              includeExpenses: request.kind.includesExpenses, includeIncome: request.kind.includesIncome,
                                              expenseName: request.name, categoryName: request.category, currency: currency,
                                              matchesPayer: { payer?.matches($0) ?? true }) { item, value in
                let title: String, category: String, identifier: String
                let date: Date?, categoryRecord: ExpenseCategory?
                switch item {
                case .expense(let expense):
                    title = expense.displayTitle
                    category = expense.categoryDisplayName
                    categoryRecord = expense.resolvedCategory
                    identifier = expense.objectID.uriRepresentation().absoluteString
                    date = expense.date
                case .occurrence(let occurrence):
                    title = occurrence.title
                    category = occurrence.categoryDisplayName
                    categoryRecord = categories.first { $0.displayName == category && $0.kind == item.kind }
                    identifier = SiriVirtualExpenseLink.identifier(for: occurrence, in: stored)
                    date = occurrence.date
                }
                guard selectedID == nil || selectedID == identifier, omittedID != identifier,
                      !excludedNames.contains(where: { $0.matches(title) || $0.matches(category) }),
                      excludedCategory.isEmpty || !excludedCategory.matchesCategory(category) else { return }
                var group: Group?
                var memberArtwork: SiriAnalysisReport.Artwork?
                if request.mode == .member {
                    if let (person, _) = people.first(where: { $0.1.matches(item) }) {
                        let matched = Group(key: person.id, label: person.name)
                        group = matched
                        memberArtwork = avatar(matched, profileID: person.profileID, isSelf: person.isSelf)
                    } else {
                        // Keep former members and distinct historical payers with identical display names separate.
                        let profileID: String?, localID: UUID?, savedName: String?
                        switch item {
                        case .expense(let expense):
                            profileID = expense.payerProfileID
                            localID = expense.payerMemberID
                            savedName = SiriExpensePayer.snapshot(for: expense, isSoloSheet: false, includePhoto: false)?.name
                        case .occurrence(let occurrence):
                            profileID = occurrence.payerProfileID
                            localID = nil
                            let rule = legacyRules.first { $0.id == occurrence.ruleID }
                            savedName = rule?.paidBy
                        }
                        let label = savedName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "不明")
                        let profile = profileID.flatMap { $0.isEmpty || UserProfileStore.isSelfPlaceholderRecordName($0) ? nil : $0 }
                        let key = profile ?? localID?.uuidString ?? "name:" + label
                        let historical = Group(key: key, label: label)
                        group = historical
                        memberArtwork = avatar(historical, profileID: profile, isSelf: false)
                    }
                }
                result.append(Entry(identifier: identifier, date: date, title: title, category: category,
                                    member: group, kind: item.kind, value: value,
                                    categoryArtwork: .category(symbol: categoryRecord?.displaySymbol ?? "tag.slash",
                                                               colorHex: categoryRecord?.displayColorHex ?? ""),
                                    memberArtwork: memberArtwork))
            }
            return result
        }

        let filters = [stored.displayName, request.ranksMonthsByAmount ? nil : scope.label, member?.name,
                       request.ranksMonthsByAmount ? nil : request.category, request.name, currency.sourceCurrency,
                       request.foreignOnly ? String(localized: "外貨のみ") : nil,
                       request.excludedName.map { String(localized: "「\($0)」以外") },
                       request.excludedCategory.map { String(localized: "「\($0)」以外") },
                       omittedID == nil ? nil : String(localized: "指定の明細を除く")]
        let current = try entries(in: scope.interval)
        let previous = try compares ? entries(in: comparison?.interval) : []
        var report = summarize(current: current, previous: previous, target: target,
                               context: filters.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・"),
                               scope: scope, comparison: comparison, request: request)
        if !report.sections.isEmpty, let name = request.category {
            let term = TransactionSearchTerm(name)
            let matching = categories.filter { category in
                !term.isEmpty && term.matchesCategory(category.displayName)
                    && (category.kind == .expense ? request.kind.includesExpenses : request.kind.includesIncome)
            }
            // Also resolve the icon when the category exists but this period has no matching expenses.
            if let category = matching.first, matching.allSatisfy({
                $0.displaySymbol == category.displaySymbol && $0.displayColorHex == category.displayColorHex
            }) {
                report.sections[0].artwork = .category(symbol: category.displaySymbol, colorHex: category.displayColorHex)
            }
        }
        return report
    }

    private struct Totals {
        var income: Decimal = 0
        var expense: Decimal = 0
        var knownExpenses = 0
        var knownIncome = 0
        var missingExpenses = 0
        var missingIncome = 0
        var missing: Int { missingExpenses + missingIncome }

        mutating func add(_ entry: Entry, original: Bool) {
            let amount = original ? entry.value.original : entry.value.converted
            switch (entry.kind, amount) {
            case (.expense, let amount?):
                expense += amount
                knownExpenses += 1
            case (.income, let amount?):
                income += amount
                knownIncome += 1
            case (.expense, nil): missingExpenses += 1
            case (.income, nil): missingIncome += 1
            }
        }

        func measure(_ kind: SiriTransactionSelection) -> Decimal {
            switch kind {
            case .expense: expense
            case .income: income
            case .both: income - expense
            }
        }

        func formatted(_ kind: SiriTransactionSelection, code: String, days: Int = 1) -> String {
            func amount(_ value: Decimal, known: Int, missing: Int) -> String {
                guard missing == 0 || known > 0 else { return String(localized: "換算できません") }
                let text = money(value / Decimal(days), code)
                return missing == 0 ? text : String(localized: "換算できた分 \(text)")
            }
            let spending = amount(expense, known: knownExpenses, missing: missingExpenses)
            let earnings = amount(income, known: knownIncome, missing: missingIncome)
            switch kind {
            case .expense: return String(localized: "支出 \(spending)")
            case .income: return String(localized: "収入 \(earnings)")
            case .both:
                let net = amount(income - expense, known: knownExpenses + knownIncome, missing: missing)
                return String(localized: "収支 \(net)（収入 \(earnings)、支出 \(spending)）")
            }
        }
    }

    nonisolated private static func money(_ amount: Decimal, _ code: String) -> String {
        amount.formatted(.currency(code: code).presentation(.isoCode))
    }

    private static func totals(_ entries: [Entry], original: Bool) -> Totals {
        entries.reduce(into: Totals()) { $0.add($1, original: original) }
    }

    private static func summarize(current: [Entry], previous: [Entry], target: String, context: String,
                                  scope: SiriExpenseScope, comparison: SiriExpenseScope?, request: SiriAnalysisRequest,
                                  now: Date = .now, calendar: Calendar = .current) -> SiriAnalysisReport {
        let original = request.groupByOriginal || request.mode == .currency
        let display: (Entry) -> String = { original ? $0.value.source : target }
        let threshold = request.minimum != nil || request.maximum != nil
        let effectiveSort = request.sort ?? (request.rank == nil ? .newest : .highest)
        let amountOrder = effectiveSort == .highest || effectiveSort == .lowest
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.dateInterval(of: .day, for: now)?.end ?? now
        let current = request.mode == .dailyAverage ? current.filter { $0.date.map { $0 < tomorrow } == true } : current
        var missing: [String: Int] = [:]

        func qualifying(_ entries: [Entry]) -> [Entry] {
            entries.filter { entry in
                let value = entry.value
                if request.mode == .unconverted && value.converted != nil { return false }
                if value.converted == nil, !original || threshold || amountOrder {
                    missing[value.source, default: 0] += 1
                }
                if threshold {
                    // Its month cannot be ranked if this row might meet the threshold.
                    guard let amount = value.converted else { return request.ranksMonthsByAmount }
                    if let min = request.minimum, request.minimumExclusive ? amount <= min : amount < min { return false }
                    if let max = request.maximum, request.maximumExclusive ? amount >= max : amount > max { return false }
                }
                return true
            }
        }
        let entries = qualifying(current), prior = qualifying(previous)
        let listing = [.transactions, .originalAmounts, .exchangeRates, .unconverted].contains(request.mode)
        var report = SiriAnalysisReport(title: request.mode.title, scope: context, summary: "")
        report.requestedRank = request.rank
        var notes: [String] = []
        if let min = request.minimum {
            notes.append(money(min, target) + (request.minimumExclusive ? String(localized: "超") : String(localized: "以上")))
        }
        if let max = request.maximum {
            notes.append(money(max, target) + (request.maximumExclusive ? String(localized: "未満") : String(localized: "以下")))
        }
        if request.ranksMonthsByAmount {
            let section = monthlyRanking(entries, scope: scope, request: request, target: target, calendar: calendar)
            report.title = String(localized: "月別ランキング")
            report.summary = section.summary
            report.sections = [section]
            report.rows = section.rows
            // The result is exactly the requested selection. Other eligible months are not hidden results.
            report.matchingRowCount = section.rows.count
            notes.append(String(localized: "該当する明細がある月のみを集計。"))
            report.note = notes.joined(separator: "・")
            return report
        }
        func totalText(_ entries: [Entry], days: Int = 1) -> String {
            let groups = Dictionary(grouping: entries, by: display)
            if groups.isEmpty { return Totals().formatted(request.kind, code: original ? (request.currency ?? target) : target, days: days) }
            return groups.keys.sorted().map { code in
                totals(groups[code] ?? [], original: original).formatted(request.kind, code: code, days: days)
            }.joined(separator: " ／ ")
        }
        report.summary = totalText(entries)
        switch request.mode {
        case .total:
            break
        case .dailyAverage:
            let first = scope.interval?.start ?? entries.compactMap(\.date).min()
            let end = min(scope.interval?.end ?? tomorrow, tomorrow)
            if let first, first < end {
                let last = calendar.startOfDay(for: end.addingTimeInterval(-0.001))
                let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: last).day ?? 0) + 1
                report.summary = totalText(entries, days: days)
                let through = min(last, today).formatted(date: .abbreviated, time: .omitted)
                notes.append(String(localized: "\(through)までの\(days)暦日で計算"))
            } else {
                report.summary = String(localized: "平均を計算できる日がありません。")
            }
        case .transactions, .originalAmounts, .exchangeRates, .unconverted:
            let order = effectiveSort
            let comparableSources = Set(entries.map(\.value.source))
            let canRankOriginal = request.rank == nil && request.mode == .unconverted && comparableSources.count == 1
            let sortable = amountOrder && !canRankOriginal ? entries.filter { $0.value.converted != nil } : entries
            if request.mode == .unconverted && amountOrder && comparableSources.count > 1 {
                notes.append(String(localized: "通貨が異なり、金額順に並べるためのレートがありません。"))
            }
            let ordered = sortable.sorted { lhs, rhs in
                let ld = lhs.date ?? .distantPast, rd = rhs.date ?? .distantPast
                if amountOrder, let a = canRankOriginal ? lhs.value.original : lhs.value.converted,
                   let b = canRankOriginal ? rhs.value.original : rhs.value.converted, a != b {
                    return order == .highest ? a > b : a < b
                }
                if ld != rd { return order == .oldest ? ld < rd : ld > rd }
                return lhs.identifier < rhs.identifier
            }
            let shown: [Entry]
            if let rank = request.rank {
                shown = rank <= ordered.count ? [ordered[rank - 1]] : []
                if amountOrder {
                    notes.append(String(localized: "同額は日付が新しい順、同日なら明細ID順で1件ずつ数えます。"))
                }
            } else {
                shown = Array(ordered.prefix(request.limit ?? ordered.count))
            }
            report.rows = shown.map { entry in
                let value = entry.value
                let date = entry.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "日付不明")
                let converted = value.converted.map { money($0, target) } ?? String(localized: "換算できません")
                var detail = [date, entry.kind.label, entry.category]
                let amount: String
                switch request.mode {
                case .exchangeRates:
                    amount = value.rate.map { "1 \(value.source) = \($0.formatted(.number.precision(.significantDigits(1...12)))) \(target)" }
                        ?? String(localized: "レートなし")
                    detail.append(money(value.original, value.source))
                    if value.source != target { detail.append(converted) }
                case .originalAmounts, .unconverted:
                    amount = money(value.original, value.source)
                    if value.source != target { detail.append(converted) }
                default:
                    amount = value.converted == nil || original ? money(value.original, value.source) : converted
                    if value.source != target {
                        detail.append(original || value.converted == nil ? converted : money(value.original, value.source))
                    }
                }
                return .init(title: entry.title.isEmpty ? entry.category : entry.title, value: amount,
                             detail: detail.joined(separator: "・"), transactionID: entry.identifier, artwork: entry.categoryArtwork)
            }
            report.matchingRowCount = ordered.count
            report.summary = ordered.isEmpty ? String(localized: "該当する明細はありません。")
                : (shown.count == ordered.count ? String(localized: "\(shown.count)件") : String(localized: "\(ordered.count)件中\(shown.count)件"))
            if let rank = request.rank {
                report.summary = rankSummary(rank: rank, count: ordered.count, sort: order, found: !shown.isEmpty)
            }
            if request.mode == .exchangeRates, let date = FXRatesService.shared.lastRateDate {
                notes.append(String(localized: "換算レートの基準日 \(date)"))
            }
            if shown.count == 1 { report.singleTransactionID = shown.first?.identifier }
        case .comparison, .categoryIncrease:
            if let comparison {
                report.summary = comparison.label + " → " + scope.label
                let rows = comparisons(entries, prior: prior, target: target, request: request, display: display,
                                       currentLabel: scope.label, priorLabel: comparison.label)
                report.matchingRowCount = rows.count
                report.rows = Array(rows.prefix(request.limit ?? rows.count))
                if report.rows.isEmpty && request.mode == .categoryIncrease {
                    report.summary += "\n" + String(localized: "比較できたカテゴリに増加はありません。")
                }
            }
        case .member, .category, .merchant, .day, .month, .currency:
            let rows = breakdown(entries, request: request, display: display, calendar: calendar)
            report.matchingRowCount = rows.count
            if let rank = request.rank {
                report.rows = rank <= rows.count ? [rows[rank - 1]] : []
                report.summary = rankSummary(rank: rank, count: rows.count, sort: request.sort ?? .highest, found: !report.rows.isEmpty)
            } else {
                report.rows = Array(rows.prefix(request.limit ?? rows.count))
            }
        }
        if !missing.isEmpty && request.mode != .unconverted {
            let text = missing.keys.sorted().map { code in String(localized: "\(code) \(missing[code] ?? 0)件") }.joined(separator: "、")
            notes.append(String(localized: "レートがないため換算対象外（\(text)）"))
        }
        if !notes.isEmpty { report.note = notes.joined(separator: "・") }
        if request.rank == nil && entries.count == 1 && !listing && request.mode != .comparison && request.mode != .categoryIncrease {
            report.singleTransactionID = entries[0].identifier
        }
        return report
    }

    /// Rank the same converted month totals the ledger uses, keeping unknown and absent months out of both extremes.
    private static func monthlyRanking(_ entries: [Entry], scope: SiriExpenseScope, request: SiriAnalysisRequest,
                                       target: String, calendar: Calendar) -> SiriAnalysisReport.Section {
        struct Month {
            let start: Date
            let amount: Decimal
            let count: Int
        }
        var months: [Date: Totals] = [:]
        var undated = 0
        for entry in entries {
            guard let date = entry.date, let start = calendar.dateInterval(of: .month, for: date)?.start else {
                undated += 1
                continue
            }
            months[start, default: Totals()].add(entry, original: false)
        }
        let high = request.sort != .lowest
        let ordered = months.compactMap { start, total -> Month? in
            guard total.missing == 0 else { return nil }
            return Month(start: start, amount: total.measure(request.kind), count: total.knownExpenses + total.knownIncome)
        }.sorted {
            if $0.amount == $1.amount { return $0.start > $1.start }
            return high ? $0.amount > $1.amount : $0.amount < $1.amount
        }
        let chosen: [Month]
        if let rank = request.rank {
            chosen = rank > 0 && rank <= ordered.count ? [ordered[rank - 1]] : []
        } else {
            chosen = Array(ordered.prefix(request.limit ?? ordered.count))
        }
        let monthFormat = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .month(.wide)
        let spansYears = scope.interval.map {
            !calendar.isDate($0.start, equalTo: $0.end.addingTimeInterval(-0.001), toGranularity: .year)
        } ?? true
        let format = spansYears ? monthFormat.year() : monthFormat
        let kind: String
        switch request.kind {
        case .expense: kind = String(localized: "支出")
        case .income: kind = String(localized: "収入")
        case .both: kind = String(localized: "収支差額")
        }
        let subject = request.category.map { request.kind == .expense ? $0 : String(localized: "\($0)の\(kind)") } ?? kind
        let ordinal = request.rank ?? (request.limit == 1 ? 1 : nil)
        let order: String
        if let ordinal {
            if ordinal == 1 { order = high ? String(localized: "一番高かった") : String(localized: "一番低かった") }
            else { order = high ? String(localized: "\(ordinal)番目に高かった") : String(localized: "\(ordinal)番目に低かった") }
        } else {
            order = high ? String(localized: "高かった") : String(localized: "低かった")
        }
        let range = scope.label
        var title = String(localized: "\(range)・\(subject)が\(order)月")
        if ordinal == nil, let count = request.limit {
            title += high ? String(localized: "（上位\(count)か月）") : String(localized: "（下位\(count)か月）")
        }
        let rows = chosen.map { month in
            SiriAnalysisReport.Row(title: month.start.formatted(format), value: CurrencyCatalog.format(month.amount, code: target),
                                   detail: String(localized: "\(month.count)件"))
        }
        func spokenAmount(_ month: Month) -> String {
            month.amount.formatted(.currency(code: target).presentation(.fullName))
        }
        let summary: String
        if let month = chosen.first, ordinal != nil {
            summary = String(localized: "\(range)、\(subject)が\(order)のは\(month.start.formatted(format))で、\(spokenAmount(month))でした。")
        } else if !chosen.isEmpty {
            let list = chosen.map { String(localized: "\($0.start.formatted(format))（\(spokenAmount($0))）") }.joined(separator: "、")
            summary = high ? String(localized: "\(range)、\(subject)が高かった順に\(list)です。")
                : String(localized: "\(range)、\(subject)が低かった順に\(list)です。")
        } else if let ordinal, !ordered.isEmpty {
            summary = String(localized: "\(range)、\(subject)を比較できるのは\(ordered.count)か月で、\(ordinal)番目の月はありません。")
        } else {
            summary = String(localized: "\(range)、\(subject)を比較できる月はありません。")
        }
        var notes: [String] = []
        let incomplete = months.count - ordered.count
        if incomplete > 0 { notes.append(String(localized: "換算できない明細がある\(incomplete)か月は順位から除外しました。")) }
        if undated > 0 { notes.append(String(localized: "日付不明の明細\(undated)件を除外しました。")) }
        if ordinal == nil, let limit = request.limit, !chosen.isEmpty, chosen.count < limit {
            notes.append(String(localized: "比較できる月は\(chosen.count)か月です。"))
        }
        let visibleAmounts = Set(chosen.map(\.amount))
        if ordered.filter({ visibleAmounts.contains($0.amount) }).count > visibleAmounts.count {
            notes.append(String(localized: "同額の月は新しい順です。"))
        }
        return .init(title: title, summary: summary, rows: rows, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func rankSummary(rank: Int, count: Int, sort: SiriAnalysisSort, found: Bool) -> String {
        let order: String
        switch sort {
        case .highest: order = String(localized: "金額が高い順")
        case .lowest: order = String(localized: "金額が低い順")
        case .newest: order = String(localized: "新しい順")
        case .oldest: order = String(localized: "古い順")
        }
        return found ? String(localized: "\(order)で\(rank)番目（対象\(count)件）")
            : String(localized: "対象は\(count)件のため、\(order)で\(rank)番目に該当する項目はありません。")
    }

    private struct Bucket: Hashable {
        let group: Group
        let code: String
    }

    private struct RankedRow {
        let row: SiriAnalysisReport.Row
        let code: String
        let amount: Decimal?
        let date: Date?
        let key: String
    }

    private static func orderedRows(_ rows: [RankedRow], request: SiriAnalysisRequest,
                                    fallback: SiriAnalysisSort) -> [SiriAnalysisReport.Row] {
        let order = request.sort ?? (request.rank == nil ? fallback : .highest)
        let amountOrder = order == .highest || order == .lowest
        let sorted = rows.sorted { lhs, rhs in
            if amountOrder {
                if (lhs.amount == nil) != (rhs.amount == nil) { return rhs.amount == nil }
                if let a = lhs.amount, let b = rhs.amount, a != b { return order == .highest ? a > b : a < b }
            } else if lhs.date != rhs.date {
                guard let a = lhs.date else { return false }
                guard let b = rhs.date else { return true }
                return order == .newest ? a > b : a < b
            }
            if lhs.code != rhs.code { return lhs.code < rhs.code }
            if lhs.row.title != rhs.row.title { return lhs.row.title < rhs.row.title }
            return lhs.key < rhs.key
        }
        // An incomplete group cannot be named the highest or lowest, even if its known subtotal is large.
        let eligible = amountOrder && (request.sort != nil || request.rank != nil) ? sorted.filter { $0.amount != nil } : sorted
        return eligible.map(\.row)
    }

    private static func breakdown(_ entries: [Entry], request: SiriAnalysisRequest,
                                  display: (Entry) -> String, calendar: Calendar) -> [SiriAnalysisReport.Row] {
        let original = request.groupByOriginal || request.mode == .currency
        let buckets = Dictionary(grouping: entries) { entry in
            let group: Group
            switch request.mode {
            case .member: group = entry.member ?? Group(key: "", label: String(localized: "不明"))
            case .merchant:
                let name = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                // A merchant has no separate field on older or current records. Only use the recorded title.
                group = Group(key: name, label: name.isEmpty ? String(localized: "明細名なし") : name)
            case .day, .month:
                if let date = entry.date {
                    let component: Calendar.Component = request.mode == .month ? .month : .day
                    let start = calendar.dateInterval(of: component, for: date)?.start ?? date
                    let format = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
                        .year().month(.abbreviated)
                    group = Group(key: String(start.timeIntervalSince1970), label: date.formatted(component == .day ? format.day() : format))
                } else { group = Group(key: "", label: String(localized: "日付不明")) }
            case .currency: group = Group(key: entry.value.source, label: entry.value.source)
            default: group = Group(key: entry.category, label: entry.category)
            }
            return Bucket(group: group, code: display(entry))
        }
        let ranked = buckets.map { bucket, items in
            let subtotal = totals(items, original: original)
            let converted = original ? totals(items, original: false) : subtotal
            let dates = items.compactMap(\.date)
            let art = request.mode == .member ? items.first?.memberArtwork : (request.mode == .category ? items.first?.categoryArtwork : nil)
            let row = SiriAnalysisReport.Row(title: bucket.group.label, value: subtotal.formatted(request.kind, code: bucket.code),
                                             detail: String(localized: "\(items.count)件"), artwork: art)
            return RankedRow(row: row, code: bucket.code, amount: converted.missing == 0 ? converted.measure(request.kind) : nil,
                             date: request.sort == .oldest ? dates.min() : dates.max(), key: bucket.group.key)
        }
        return orderedRows(ranked, request: request, fallback: [.day, .month].contains(request.mode) ? .oldest : .highest)
    }

    private static func comparisons(_ entries: [Entry], prior: [Entry], target: String, request: SiriAnalysisRequest,
                                    display: (Entry) -> String, currentLabel: String, priorLabel: String) -> [SiriAnalysisReport.Row] {
        let byCategory = request.mode == .categoryIncrease
        let original = request.groupByOriginal
        func buckets(_ items: [Entry]) -> [Bucket: [Entry]] {
            Dictionary(grouping: items) { item in
                let category = byCategory ? item.category : ""
                return Bucket(group: Group(key: category, label: category), code: display(item))
            }
        }
        let this = buckets(entries), last = buckets(prior)
        var keys = Set(this.keys).union(last.keys)
        if !byCategory && keys.isEmpty { keys.insert(Bucket(group: Group(key: "", label: ""), code: target)) }
        var changes: [RankedRow] = []
        for key in keys {
            let newItems = this[key] ?? [], oldItems = last[key] ?? []
            let a = totals(newItems, original: original), b = totals(oldItems, original: original)
            let old = b.measure(request.kind)
            let delta = a.measure(request.kind) - old
            let complete = a.missing == 0 && b.missing == 0
            // Exclude indeterminate categories from an increase claim.
            if byCategory && (!complete || delta <= 0) { continue }
            let change: String
            if complete {
                var text = (delta > 0 ? "+" : "") + money(delta, key.code)
                if old > 0 {
                    let percent = (delta / old).formatted(.percent.precision(.fractionLength(0...1)))
                    text += "（\(delta > 0 ? "+" : "")\(percent)）"
                }
                change = text
            } else { change = String(localized: "増減は不明") }
            let detail = "\(priorLabel) \(b.formatted(request.kind, code: key.code)) → \(currentLabel) \(a.formatted(request.kind, code: key.code))"
            let label = byCategory ? key.group.label : String(localized: "\(key.code)の増減")
            let row = SiriAnalysisReport.Row(title: label, value: change, detail: detail,
                                             artwork: byCategory ? (newItems.first ?? oldItems.first)?.categoryArtwork : nil)
            // Compare magnitudes across original currencies only after valuing them in a single currency.
            let convertedA = original ? totals(newItems, original: false) : a
            let convertedB = original ? totals(oldItems, original: false) : b
            let rank = convertedA.missing == 0 && convertedB.missing == 0
                ? convertedA.measure(request.kind) - convertedB.measure(request.kind) : nil
            let dates = newItems.compactMap(\.date)
            changes.append(RankedRow(row: row, code: key.code, amount: rank,
                                     date: request.sort == .oldest ? dates.min() : dates.max(), key: key.group.key))
        }
        return orderedRows(changes, request: request, fallback: .highest)
    }
}
#endif

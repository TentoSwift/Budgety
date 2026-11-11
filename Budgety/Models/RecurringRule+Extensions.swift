//
//  RecurringRule+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import CloudKit

enum RecurrenceFrequency: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly, monthly, yearly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:   String(localized: "毎日")
        case .weekly:  String(localized: "毎週")
        case .monthly: String(localized: "毎月")
        case .yearly:  String(localized: "毎年")
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .daily:   .day
        case .weekly:  .weekOfYear
        case .monthly: .month
        case .yearly:  .year
        }
    }

    /// 例: "毎月 1 ヶ月ごと" → "毎月", "毎月 3 ヶ月ごと" → "3 ヶ月ごと"
    func summary(interval: Int) -> String {
        let n = max(1, interval)
        if n == 1 { return label }
        switch self {
        case .daily:   return String(localized: "\(n) 日ごと")
        case .weekly:  return String(localized: "\(n) 週ごと")
        case .monthly: return String(localized: "\(n) ヶ月ごと")
        case .yearly:  return String(localized: "\(n) 年ごと")
        }
    }
}

extension RecurringRule {
    var resolvedFrequency: RecurrenceFrequency {
        RecurrenceFrequency(rawValue: frequency ?? "monthly") ?? .monthly
    }

    var resolvedInterval: Int {
        max(1, Int(interval))
    }

    var amountDecimal: Decimal {
        get { (amount ?? 0) as Decimal }
        set { amount = NSDecimalNumber(decimal: newValue) }
    }

    /// 受益者 (誰の負担として扱うか) の profileID リスト。Expense と同じ CSV 表現。
    /// 空 = 割り勘オフ (支払者単独負担)。生成される Expense にそのまま引き継がれる。
    var beneficiaryIDList: [String] {
        get {
            (beneficiaryProfileIDs ?? "")
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            beneficiaryProfileIDs = cleaned.joined(separator: ",")
        }
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw ?? "") ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var resolvedCurrencyCode: String {
        if let c = currencyCode, !c.isEmpty { return c }
        return sheet?.resolvedDefaultCurrencyCode ?? CurrencyCatalog.defaultCode
    }

    var displayTitle: String { title ?? "" }

    var formattedAmount: String {
        CurrencyCatalog.format(amountDecimal, code: resolvedCurrencyCode)
    }

    var recurringSeriesID: UUID? { seriesID ?? id }

    var orderedSeriesSegments: [RecurringRule] {
        guard let family = recurringSeriesID, let rules = sheet?.recurringRules as? Set<RecurringRule>
        else { return isDeleted ? [] : [self] }
        return rules.filter { !$0.isDeleted && $0.recurringSeriesID == family }.sorted {
            if $0.startDate != $1.startDate { return ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }
    }

    func postingDay(for scheduled: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: Int(postingDayOffset), to: scheduled) ?? scheduled
    }

    func scheduledDay(forPostingDay day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -Int(postingDayOffset), to: day) ?? day
    }

    /// A split has its own effective start, but continues counting from the original calendar anchor.
    func scheduledDays(after lower: Date? = nil, until upper: Date, cap: Int = .max,
                       calendar: Calendar = .current) -> [Date] {
        guard let startDate,
              let beforeStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: startDate))
        else { return [] }
        let floor = lower.map { $0.compare(beforeStart) == .orderedDescending ? $0 : beforeStart } ?? beforeStart
        var limit = endDate.map { $0.compare(upper) == .orderedAscending ? $0 : upper } ?? upper
        // CloudKit may deliver overlapping splits from different devices. Only the last
        // effective segment owns a slot, even before its predecessor's end has synced.
        let segments = orderedSeriesSegments
        if let index = segments.firstIndex(of: self), index + 1 < segments.count,
           let boundary = segments[index + 1].startDate,
           let last = calendar.date(byAdding: .day, value: -1, to: boundary),
           last.compare(limit) == .orderedAscending { limit = last }
        return RecurringOccurrenceService.occurrenceDays(start: scheduleAnchor ?? startDate, frequency: resolvedFrequency,
                                                        interval: resolvedInterval, after: floor, until: limit,
                                                        cap: cap, calendar: calendar)
    }

    var nextScheduledOccurrence: Date? {
        let calendar = Calendar.current
        let today = scheduledDay(forPostingDay: calendar.startOfDay(for: .now), calendar: calendar)
        guard let previous = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        let skipped = skippedDaySet
        return scheduledDays(after: previous, until: .distantFuture, cap: skipped.count + 1, calendar: calendar)
            .first { !skipped.contains($0) }
    }

    func lastScheduledOccurrence(onOrBefore day: Date, calendar: Calendar = .current) -> Date? {
        let limit = endDate.map { $0.compare(day) == .orderedAscending ? $0 : day } ?? day
        let skipped = skippedDaySet
        // Looking back one extra calendar interval also covers a clamped February or leap day.
        let (distance, overflow) = resolvedInterval.multipliedReportingOverflow(by: skipped.count + 2)
        let lower = overflow ? nil : calendar.date(byAdding: resolvedFrequency.calendarComponent, value: -distance, to: limit)
        return scheduledDays(after: lower, until: limit, calendar: calendar).last { !skipped.contains($0) }
    }

    var nextOccurrence: Date? { nextScheduledOccurrence.map { postingDay(for: $0) } }

    /// 支払者の Member を引く (Expense.resolvedPayer と同じ解決ロジック)。
    /// payerProfileID が canonical self ID 群と一致すれば selfMember、
    /// それ以外は Member.recordName 一致で解決する。
    #if !os(watchOS)
    @MainActor
    var resolvedPayer: Member? {
        let pc = PersistenceController.shared
        let ctx = managedObjectContext ?? pc.container.viewContext
        guard let pid = payerProfileID, !pid.isEmpty else { return nil }

        let share: CKShare? = sheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
        let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
        if selfIDs.contains(pid),
           let selfID = UserProfileStore.shared.selfMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", selfID as CVarArg)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first { return m }
        }
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.predicate = NSPredicate(format: "recordName == %@", pid)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }
    #endif

    // MARK: - スキップ (削除された occurrence の記録)

    /// スキップ (削除) された occurrence の日付集合 (startOfDay)。
    /// 内部表現: `skippedDates` = startOfDay の timeIntervalSince1970(Int) を "," 区切り。
    /// 完全仮想化で「この回だけ削除」を、Expense を作らずルール側に記録するために使う。
    var skippedDaySet: Set<Date> {
        get {
            let cal = Calendar.current
            return Set((skippedDates ?? "")
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { cal.startOfDay(for: Date(timeIntervalSince1970: $0)) })
        }
        set {
            let cal = Calendar.current
            let ints = newValue.map { Int(cal.startOfDay(for: $0).timeIntervalSince1970) }.sorted()
            skippedDates = ints.map(String.init).joined(separator: ",")
        }
    }

    /// 指定日がスキップ済みか。
    func isSkippedDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        skippedDaySet.contains(calendar.startOfDay(for: date))
    }

    /// 指定日の occurrence をスキップ (削除) として記録する。
    func addSkippedDay(_ date: Date, calendar: Calendar = .current) {
        var s = skippedDaySet
        s.insert(calendar.startOfDay(for: date))
        skippedDaySet = s
    }
}

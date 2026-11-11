//
//  RecurringOccurrenceService.swift
//  Budgety
//
//  RecurringRule から occurrence (繰り返しの各回) の日付を算出する純粋ロジック。
//  drift-free: 各回を「前回の結果」ではなく常に開始日 (anchor) から
//  `anchor + n×interval` で独立計算する。これにより月末 (例: 31日) がクランプ
//  された後も基準日に復帰する (1/31 → 2/28 → 3/31 → 4/30 …)。
//
//  生成 (RecurringExpenseGenerator) と表示 (今後の予定 / nextOccurrence) の両方が
//  この同じ計算を使うことで、両者の occurrence 認識を一致させる。
//

import Foundation
import CoreData

/// ルールから算出される「1回分の定期 occurrence」を表す値型 (Core Data には保存しない)。
/// 完全仮想化方式で、一覧・集計・精算などの表示/計算時に実支出へマージするために使う。
struct RecurringOccurrence: Identifiable {
    let ruleID: UUID
    let scheduledDate: Date             // Original calendar slot, also identifies edits and exclusions.
    let date: Date                      // Posting date shown in the ledger.
    let note: String
    let photoData: Data?
    let title: String
    let amount: Decimal
    let currencyCode: String
    let kind: TransactionKind
    let categoryRaw: String
    var categoryDisplayName: String { categoryRaw.isEmpty ? String(localized: "カテゴリなし") : categoryRaw }
    let payerProfileID: String?
    let beneficiaryProfileIDs: String   // CSV (空 = 割り勘オフ)
    var id: String { "\(ruleID.uuidString)#\(Int(scheduledDate.timeIntervalSince1970))" }
}

/// 一覧表示用の union: 実 Expense か、ルールから算出した仮想 occurrence。
enum LedgerItem: Identifiable {
    case expense(Expense)
    case occurrence(RecurringOccurrence)

    var id: String {
        switch self {
        case .expense(let e):    return "e:" + e.objectID.uriRepresentation().absoluteString
        case .occurrence(let o): return "o:" + o.id
        }
    }
    var date: Date {
        switch self {
        case .expense(let e):    return e.date ?? .distantPast
        case .occurrence(let o): return o.date
        }
    }
    var amountDecimal: Decimal {
        switch self {
        case .expense(let e):    return e.amountDecimal
        case .occurrence(let o): return o.amount
        }
    }
    var kind: TransactionKind {
        switch self {
        case .expense(let e):    return e.kind
        case .occurrence(let o): return o.kind
        }
    }
    var currencyCode: String {
        switch self {
        case .expense(let e):    return e.resolvedCurrencyCode
        case .occurrence(let o): return o.currencyCode
        }
    }
    var isVirtual: Bool {
        if case .occurrence = self { return true }
        return false
    }
}

enum RecurringOccurrenceService {

    private static let maximumSlotsPerRule = 200_000

    /// アプリ、Siri、ショートカットで同じ定期項目を使う。
    static let featureEnabled = true

    /// 既定は仮想表示。以前の実体化モードを明示した端末はその設定を引き継ぐ。
    static let virtualizationKey = "expensoRecurringVirtualization"
    static var virtualizationEnabled: Bool {
        // 既定 ON (常に仮想モード)。デバッグで明示的に OFF にした時だけ false。
        if UserDefaults.standard.object(forKey: virtualizationKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: virtualizationKey)
    }

    /// `start` を anchor として `frequency`×`interval` を n 回 (n = 0,1,2,…) 加算した
    /// drift-free な occurrence 日付列を返す。
    ///
    /// - Parameters:
    ///   - start: 開始日 (anchor)。内部で startOfDay に正規化する。
    ///   - frequency: 繰り返し頻度。
    ///   - interval: 間隔 (1 以上に丸める)。
    ///   - limit: この日 (含む) までの occurrence を返す。内部で startOfDay に正規化。
    ///   - cap: 返す最大件数 (暴走防止)。既定は上限なし。
    ///   - calendar: 計算に使うカレンダー (既定 `.current`)。
    /// - Returns: startOfDay 正規化済みの occurrence 日付列 (昇順)。
    static func occurrenceDays(
        start: Date,
        frequency: RecurrenceFrequency,
        interval: Int,
        after lowerBound: Date? = nil,
        until limit: Date,
        cap: Int = .max,
        calendar: Calendar = .current
    ) -> [Date] {
        guard cap > 0 else { return [] }
        let component = frequency.calendarComponent
        let step = max(1, interval)
        let anchor = calendar.startOfDay(for: start)
        let limitDay = calendar.startOfDay(for: limit)
        guard anchor.compare(limitDay) != .orderedDescending else { return [] }
        let afterDay = lowerBound.map { calendar.startOfDay(for: $0) }
        if let afterDay, afterDay.compare(limitDay) != .orderedAscending { return [] }

        // Count from the original anchor even when the query begins years later.
        // A clamped month/year end can differ by one from Calendar's whole-unit distance.
        let span = calendar.dateComponents([component], from: anchor, to: limitDay).value(for: component) ?? 0
        let maxOffset = span == .max ? span : span + 1
        var first = 0
        if let afterDay, afterDay.compare(anchor) != .orderedAscending {
            let elapsed = calendar.dateComponents([component], from: anchor, to: afterDay).value(for: component) ?? 0
            first = max(0, max(0, elapsed) / step - 1)
        }

        var result: [Date] = []
        // Keep the existing safety limit consistent between all-time, bounded and persisted history.
        for index in min(first, maximumSlotsPerRule)..<maximumSlotsPerRule {
            let (offset, overflow) = index.multipliedReportingOverflow(by: step)
            guard result.count < cap, !overflow, offset <= maxOffset,
                  let raw = calendar.date(byAdding: component, value: offset, to: anchor) else { break }
            let day = calendar.startOfDay(for: raw)
            if day.compare(limitDay) == .orderedDescending { break }
            if let afterDay, day.compare(afterDay) != .orderedDescending { continue }
            result.append(day)
        }
        return result
    }

    /// Inclusive ledger date range for a calendar month or year.
    static func calendarDays(in component: Calendar.Component, containing date: Date, calendar: Calendar = .current) -> ClosedRange<Date>? {
        guard let interval = calendar.dateInterval(of: component, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
        return interval.start...last
    }

    /// 表示用の「次回」。月末を含む予定日は開始日を基準にし、今日・終了日の両方を含める。
    static func nextOccurrenceDay(
        start: Date, onOrAfter reference: Date = .now, frequency: RecurrenceFrequency,
        interval: Int, endDate: Date?, skipping skipped: Set<Date>, calendar: Calendar = .current
    ) -> Date? {
        let today = calendar.startOfDay(for: reference)
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        return occurrenceDays(start: start, frequency: frequency, interval: interval, after: previousDay,
                              until: endDate ?? .distantFuture, cap: skipped.count + 1, calendar: calendar)
            .first { !skipped.contains($0) }
    }

    /// シート配下の全ルールから、まだ実体化されていない occurrence を算出して返す (完全仮想化用)。
    /// - その `(ruleID, scheduledDate)` に**実在行がある日付は除外**する
    ///   (= 既存の生成済み行・override・skip tombstone を尊重し、二重表示しない)。
    /// - `includeFuture == false` なら今日まで。true なら `futureHorizon` まで (予算予測などの先読み用)。
    /// - `range` を渡すとその期間内に絞る (両端含む)。
    /// - 注: 値型を返すだけで Core Data には何も書き込まない。
    @MainActor
    static func virtualOccurrences(
        for sheet: ExpenseSheet,
        in range: ClosedRange<Date>? = nil,
        includeFuture: Bool = false,
        futureHorizon: Date? = nil,
        calendar: Calendar = .current
    ) -> [RecurringOccurrence] {
        guard featureEnabled else { return [] }          // 機能オフ: 仮想ゼロ (既存ルールは休眠)
        guard virtualizationEnabled else { return [] }   // OFF: 完全ハイブリッド (仮想ゼロ)
        let rules = (sheet.recurringRules as? Set<RecurringRule>) ?? []
        guard !rules.isEmpty else { return [] }

        let today = calendar.startOfDay(for: Date())
        // 実体化済み (生成済み/override/skip) の (ruleID, day) 集合。これらの日付は仮想を出さない。
        var familiesByRule: [UUID: UUID] = [:]
        var excludedByFamily: [UUID: Set<Date>] = [:]
        for rule in rules where !rule.isDeleted {
            guard let id = rule.id, let family = rule.recurringSeriesID else { continue }
            familiesByRule[id] = family
            excludedByFamily[family, default: []].formUnion(rule.skippedDaySet)
        }
        var materialized = Set<String>()
        for e in sheet.expenses as? Set<Expense> ?? [] where !e.isDeleted {
            guard let rid = e.generatedFromRuleID else { continue }
            let d = calendar.startOfDay(for: e.scheduledDate ?? e.date ?? .distantPast)
            materialized.insert("\((familiesByRule[rid] ?? rid).uuidString)#\(Int(d.timeIntervalSince1970))")
        }

        var result: [RecurringOccurrence] = []
        for rule in rules {
            guard !rule.isDeleted, let ruleID = rule.id, let family = rule.recurringSeriesID else { continue }
            var limit = includeFuture ? (futureHorizon ?? today) : today
            if let end = range?.upperBound, end.compare(limit) == .orderedAscending { limit = end }
            let after = range.flatMap { window in
                calendar.date(byAdding: .day, value: -1, to: rule.scheduledDay(forPostingDay: calendar.startOfDay(for: window.lowerBound), calendar: calendar))
            }
            let days = rule.scheduledDays(after: after, until: rule.scheduledDay(forPostingDay: limit, calendar: calendar),
                                          calendar: calendar)
            let skipped = excludedByFamily[family] ?? []
            for day in days {
                let posting = rule.postingDay(for: day, calendar: calendar)
                if let range, posting.compare(range.lowerBound) == .orderedAscending { continue }
                if skipped.contains(day) { continue }         // スキップ (削除) 済み → 出さない
                let key = "\(family.uuidString)#\(Int(day.timeIntervalSince1970))"
                if materialized.contains(key) { continue }   // 実在行あり → 仮想は出さない
                result.append(RecurringOccurrence(
                    ruleID: ruleID,
                    scheduledDate: day,
                    date: posting,
                    note: rule.note ?? "",
                    photoData: rule.photoData,
                    title: rule.title ?? "",
                    amount: rule.amountDecimal,
                    currencyCode: rule.resolvedCurrencyCode,
                    kind: rule.kind,
                    categoryRaw: rule.categoryRaw ?? "",
                    payerProfileID: rule.payerProfileID,
                    beneficiaryProfileIDs: rule.beneficiaryProfileIDs ?? ""
                ))
            }
        }
        return result
    }
}

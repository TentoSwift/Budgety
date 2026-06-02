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
    let date: Date                      // 予定スロット日 (startOfDay)
    let title: String
    let amount: Decimal
    let currencyCode: String
    let kind: TransactionKind
    let categoryRaw: String
    let payerProfileID: String?
    let beneficiaryProfileIDs: String   // CSV (空 = 割り勘オフ)
    var id: String { "\(ruleID.uuidString)#\(Int(date.timeIntervalSince1970))" }
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

    /// 完全仮想化のフィーチャーフラグ (既定 OFF)。
    /// ON で「定期 occurrence を保存せず表示時に算出」へ切替: generator は実体化を止め、
    /// 各 consumer は仮想 occurrence を合流する。OFF の間は従来のハイブリッド (生成して保存)。
    /// デバッグ設定からトグルして検証し、全プラットフォーム対応後に既定 ON にする。
    static let virtualizationKey = "expensoRecurringVirtualization"
    static var virtualizationEnabled: Bool {
        UserDefaults.standard.bool(forKey: virtualizationKey)
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
        guard anchor <= limitDay else { return [] }
        // `after` 以下の日付はスキップする (= 生成済み / 削除済みの過去を再生成しない下限)。
        let afterDay = lowerBound.map { calendar.startOfDay(for: $0) }

        var result: [Date] = []
        var n = 0
        // 安全上限: 通常は day > limitDay で break するが、after で大量スキップする
        // 極端なケース (古い daily ルール等) の無駄反復を抑える保険。
        let safetyMax = 200_000
        while result.count < cap && n < safetyMax {
            guard let raw = calendar.date(byAdding: component, value: n * step, to: anchor) else { break }
            let day = calendar.startOfDay(for: raw)
            n += 1
            if day > limitDay { break }
            if let afterDay, day <= afterDay { continue }
            result.append(day)
        }
        return result
    }

    /// `lastGeneratedDate` / `startDate` を起点に、次に来る (今日以降の) occurrence 日付を返す。
    /// 表示用 (「次回 X月Y日」)。endDate を超える場合は nil。
    static func nextOccurrenceDay(
        start: Date,
        after reference: Date?,
        frequency: RecurrenceFrequency,
        interval: Int,
        endDate: Date?,
        calendar: Calendar = .current
    ) -> Date? {
        let limit = endDate ?? .distantFuture
        // reference 以降 (なければ今日以降) の最初の occurrence を探す。
        let floor = calendar.startOfDay(for: reference ?? Date())
        let component = frequency.calendarComponent
        let step = max(1, interval)
        let anchor = calendar.startOfDay(for: start)
        let limitDay = calendar.startOfDay(for: limit)
        var n = 0
        // 暴走防止に十分大きい安全上限。
        let safetyCap = 100_000
        while n < safetyCap {
            guard let raw = calendar.date(byAdding: component, value: n * step, to: anchor) else { return nil }
            let day = calendar.startOfDay(for: raw)
            if day > limitDay { return nil }
            if day > floor { return day }
            n += 1
        }
        return nil
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
        guard virtualizationEnabled else { return [] }   // OFF: 完全ハイブリッド (仮想ゼロ)
        let rules = (sheet.recurringRules as? Set<RecurringRule>) ?? []
        guard !rules.isEmpty else { return [] }

        let today = calendar.startOfDay(for: Date())
        // 実体化済み (生成済み/override/skip) の (ruleID, day) 集合。これらの日付は仮想を出さない。
        var materialized = Set<String>()
        for case let e as Expense in (sheet.expenses as? Set<Expense> ?? []) {
            guard let rid = e.generatedFromRuleID else { continue }
            let d = calendar.startOfDay(for: e.scheduledDate ?? e.date ?? .distantPast)
            materialized.insert("\(rid.uuidString)#\(Int(d.timeIntervalSince1970))")
        }

        var result: [RecurringOccurrence] = []
        for rule in rules {
            guard let start = rule.startDate, let ruleID = rule.id else { continue }
            let ruleEnd = rule.endDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            let upper: Date = {
                let base = includeFuture ? (futureHorizon ?? today) : today
                return min(base, ruleEnd)
            }()
            // range の上限も尊重 (先読みしすぎない)
            let limit = range.map { min(upper, calendar.startOfDay(for: $0.upperBound)) } ?? upper
            guard calendar.startOfDay(for: start) <= limit else { continue }

            let days = occurrenceDays(
                start: start,
                frequency: rule.resolvedFrequency,
                interval: rule.resolvedInterval,
                until: limit,
                cap: 600,
                calendar: calendar
            )
            for day in days {
                if let range, !(range ~= day) { continue }
                let key = "\(ruleID.uuidString)#\(Int(day.timeIntervalSince1970))"
                if materialized.contains(key) { continue }   // 実在行あり → 仮想は出さない
                result.append(RecurringOccurrence(
                    ruleID: ruleID,
                    date: day,
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

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

enum RecurringOccurrenceService {

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

        var result: [Date] = []
        var n = 0
        while result.count < cap {
            guard let raw = calendar.date(byAdding: component, value: n * step, to: anchor) else { break }
            let day = calendar.startOfDay(for: raw)
            if day > limitDay { break }
            result.append(day)
            n += 1
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
}

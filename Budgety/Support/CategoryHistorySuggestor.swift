//
//  CategoryHistorySuggestor.swift
//  Budgety
//
//  ユーザー自身の過去の分類履歴から、入力タイトルに対する最適カテゴリを学習して提案する。
//  例: 「クスリのアオキ」を一度「食費」として登録すると、次回以降も同じ店名で「食費」を提案する
//  (AI の汎用推測=「医療」より、ユーザーの実際の分類を優先する)。
//
//  オンデバイス・同期処理 (Core Data の同シート内 Expense を走査するだけ)。AI と違い即時。
//

import Foundation
import CoreData

enum CategoryHistorySuggestor {

    /// 過去の自分の分類から、タイトルに最も合うカテゴリを返す。履歴が無ければ nil。
    /// - Parameters:
    ///   - title: 入力中のタイトル (店名など)
    ///   - kind: 支出 / 収入 (同種別の履歴のみ対象)
    ///   - sheet: 対象シート (カテゴリはシート固有なので同シート内で集計)
    @MainActor
    static func suggest(title: String, kind: TransactionKind, in sheet: ExpenseSheet) -> ExpenseCategory? {
        let target = normalize(title)
        guard target.count >= 2 else { return nil }
        guard let expenses = sheet.expenses as? Set<Expense> else { return nil }

        // 同 kind・カテゴリあり・タイトル一致 (完全 or 前方一致) の過去 Expense を集める。
        var exact: [Expense] = []
        var prefix: [Expense] = []
        for e in expenses {
            guard e.kind == kind, e.category != nil else { continue }
            let t = normalize(e.title ?? "")
            guard t.count >= 2 else { continue }
            if t == target {
                exact.append(e)
            } else if t.hasPrefix(target) || target.hasPrefix(t) {
                prefix.append(e)
            }
        }
        // 完全一致があればそれだけで集計 (ノイズ回避)。無ければ前方一致で集計。
        let pool = exact.isEmpty ? prefix : exact
        guard !pool.isEmpty else { return nil }

        // カテゴリ別に「頻度」を集計 (同点は最新の日付を優先)。
        var tally: [NSManagedObjectID: (category: ExpenseCategory, count: Int, latest: Date)] = [:]
        for e in pool {
            guard let cat = e.category else { continue }
            let date = e.date ?? .distantPast
            if var entry = tally[cat.objectID] {
                entry.count += 1
                if date > entry.latest { entry.latest = date }
                tally[cat.objectID] = entry
            } else {
                tally[cat.objectID] = (cat, 1, date)
            }
        }

        return tally.values.max { a, b in
            a.count != b.count ? a.count < b.count : a.latest < b.latest
        }?.category
    }

    /// タイトル正規化: 前後空白除去 + 小文字化 + 全角空白→半角。
    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{3000}", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
         .lowercased()
    }
}

//
//  RecurringExpenseGenerator.swift
//  Expenso
//
//  RecurringRule から Expense を展開する。アプリ起動時とフォアグラウンド復帰時に走り、
//  startDate から「今日まで」の未生成 occurrence を作る。
//
//  冪等性: occurrence は `(generatedFromRuleID, scheduledDate)` で一意に識別する。
//  既に同じスロットの行が在れば作らない。これによりマルチデバイスで生成が二重に
//  走っても重複しない (CloudKit はユニーク制約を持てないので、生成側の冪等チェック +
//  収束 dedup で担保する設計)。
//
//  drift-free: occurrence 日付は RecurringOccurrenceService が startDate を anchor に
//  `anchor + n×interval` で各回独立に算出する (月末ドリフトしない)。
//
//  FX: 定期 occurrence は FX スナップショットを取らない (現行レートで精算される)。
//  通常の手入力支出のみ凍結する、という方針 (2026-06-02 決定)。
//
//  暴走防止のため 1 回の generate で 1 ルールあたり 12 件まで新規作成で打ち切る。
//

import Foundation
import CoreData

@MainActor
enum RecurringExpenseGenerator {
    /// 1 回の generate 呼び出しで 1 ルールにつき「新規作成」する最大数。
    /// 数年放置されたルールが起動直後に大量の Expense を作るのを防ぐ。
    static let perRuleCap = 12

    /// viewContext 上の全 RecurringRule を走査して未生成分を作成する。
    /// save まで含む。
    static func generateAll(in ctx: NSManagedObjectContext) {
        // 完全仮想化 ON 時は実体化しない (occurrence は表示時にルールから算出する)。
        guard !RecurringOccurrenceService.virtualizationEnabled else { return }
        let req = NSFetchRequest<RecurringRule>(entityName: "RecurringRule")
        guard let rules = try? ctx.fetch(req), !rules.isEmpty else { return }

        var didChange = false
        for rule in rules {
            if generate(for: rule, in: ctx) > 0 { didChange = true }
        }
        if didChange { try? ctx.save() }
    }

    /// 1 ルールを処理し、新規生成した件数を返す。`save` は呼び出し側で。
    @discardableResult
    static func generate(for rule: RecurringRule, in ctx: NSManagedObjectContext) -> Int {
        guard let startDate = rule.startDate, let sheet = rule.sheet else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let endDate = rule.endDate.map { cal.startOfDay(for: $0) } ?? .distantFuture
        let limit = min(today, endDate)
        guard cal.startOfDay(for: startDate) <= limit else { return 0 }

        // lastGeneratedDate を下限 (floor) に使う。これ以下の日付は再生成しない。
        // → 生成済み occurrence を単発削除しても次回復活しない (= 削除を尊重)。
        // (drift-free 計算 + この floor で、旧来のカーソル方式の「過去は触らない」挙動を維持)
        let floor = rule.lastGeneratedDate

        // 既に実体化済みの occurrence 日付。多端末で先に生成済みのものを冪等にスキップする
        // (floor が CloudKit でまだ同期されていない短い窓の重複対策)。
        // scheduledDate が未設定の旧データは date で代替する (バックフィル前の保険)。
        let materialized = materializedDays(for: rule, in: ctx, cal: cal)

        // drift-free な occurrence 日付列。floor より後 ～ limit までを最大 perRuleCap 件。
        let days = RecurringOccurrenceService.occurrenceDays(
            start: startDate,
            frequency: rule.resolvedFrequency,
            interval: rule.resolvedInterval,
            after: floor,
            until: limit,
            cap: perRuleCap,
            calendar: cal
        )

        let sheetStore = sheet.objectID.persistentStore
        let matchedCategory: ExpenseCategory? = {
            guard let raw = rule.categoryRaw, !raw.isEmpty,
                  let cats = sheet.categories as? Set<ExpenseCategory>,
                  let cat = cats.first(where: { $0.name == raw }),
                  cat.objectID.persistentStore == sheetStore else { return nil }
            return cat
        }()

        var generated = 0
        for day in days {
            if materialized.contains(day) { continue }   // 冪等: 他端末生成済みはスキップ

            let expense = Expense(context: ctx)
            if let store = sheetStore { ctx.assign(expense, to: store) }

            expense.title = rule.title
            expense.amount = rule.amount
            expense.kindRaw = rule.kindRaw
            expense.currencyCode = rule.currencyCode
            expense.categoryRaw = rule.categoryRaw
            // paidBy は denormalized キャッシュなので継承しない。表示は payerProfileID から動的解決。
            expense.paidBy = nil
            expense.payerProfileID = rule.payerProfileID
            // 割り勘 (受益者) を引き継ぐ。空なら割り勘オフ (支払者単独負担) のまま。
            expense.beneficiaryProfileIDs = rule.beneficiaryProfileIDs
            expense.note = rule.note
            expense.date = day
            expense.scheduledDate = day              // ← occurrence 識別キー
            expense.createdAt = .now
            expense.sheet = sheet
            expense.generatedFromRuleID = rule.id
            if let cat = matchedCategory { expense.category = cat }
            // 定期 occurrence は FX スナップショットを取らない (現行レートで精算)。

            rule.lastGeneratedDate = day
            generated += 1
        }

        return generated
    }

    /// このルールから実体化済みの occurrence 日付集合 (startOfDay 正規化)。
    /// 生成済み行・オーバーライド・スキップ tombstone はすべて `generatedFromRuleID` を持つ。
    private static func materializedDays(
        for rule: RecurringRule,
        in ctx: NSManagedObjectContext,
        cal: Calendar
    ) -> Set<Date> {
        guard let id = rule.id else { return [] }
        let req = NSFetchRequest<Expense>(entityName: "Expense")
        req.predicate = NSPredicate(format: "generatedFromRuleID == %@", id as CVarArg)
        req.returnsObjectsAsFaults = false
        let rows = (try? ctx.fetch(req)) ?? []
        var set = Set<Date>()
        for e in rows {
            if let d = e.scheduledDate ?? e.date {
                set.insert(cal.startOfDay(for: d))
            }
        }
        return set
    }
}

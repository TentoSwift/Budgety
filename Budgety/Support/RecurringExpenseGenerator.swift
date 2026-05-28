//
//  RecurringExpenseGenerator.swift
//  Expenso
//
//  RecurringRule から Expense を展開する。アプリ起動時とフォアグラウンド復帰時に走り、
//  startDate / lastGeneratedDate から「今日まで」の未生成 occurrence を作る。
//  暴走防止のため 1 ルールあたり 12 件までで打ち切る。
//

import Foundation
import CoreData

@MainActor
enum RecurringExpenseGenerator {
    /// 1 回の generate 呼び出しで 1 ルールにつき作る最大数。
    /// 数年放置されたルールが起動直後に大量の Expense を作るのを防ぐ。
    static let perRuleCap = 12

    /// viewContext 上の全 RecurringRule を走査して未生成分を作成する。
    /// save まで含む。
    static func generateAll(in ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<RecurringRule>(entityName: "RecurringRule")
        guard let rules = try? ctx.fetch(req), !rules.isEmpty else { return }

        var didChange = false
        for rule in rules {
            if generate(for: rule, in: ctx) > 0 { didChange = true }
        }
        if didChange { try? ctx.save() }
    }

    /// 1 ルールを処理し、生成した件数を返す。`save` は呼び出し側で。
    @discardableResult
    static func generate(for rule: RecurringRule, in ctx: NSManagedObjectContext) -> Int {
        guard let startDate = rule.startDate, let sheet = rule.sheet else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let endDate = rule.endDate.map { cal.startOfDay(for: $0) } ?? .distantFuture

        // 始点 = lastGeneratedDate の次か、未生成なら startDate
        var date: Date
        if let last = rule.lastGeneratedDate {
            date = nextDate(after: last, rule: rule)
        } else {
            date = cal.startOfDay(for: startDate)
        }

        var generated = 0
        let sheetStore = sheet.objectID.persistentStore

        while date <= today, date <= endDate, generated < perRuleCap {
            let expense = Expense(context: ctx)
            if let store = sheetStore { ctx.assign(expense, to: store) }

            expense.title = rule.title
            expense.amount = rule.amount
            expense.kindRaw = rule.kindRaw
            expense.currencyCode = rule.currencyCode
            expense.categoryRaw = rule.categoryRaw
            // paidBy は denormalized キャッシュなので継承しない。表示は payerProfileID から動的解決される。
            expense.paidBy = nil
            expense.payerProfileID = rule.payerProfileID
            // 割り勘 (受益者) を引き継ぐ。空なら割り勘オフ (支払者単独負担) のまま。
            expense.beneficiaryProfileIDs = rule.beneficiaryProfileIDs
            expense.note = rule.note
            expense.date = date
            expense.createdAt = .now
            expense.sheet = sheet
            expense.generatedFromRuleID = rule.id

            // 同シート内で名前一致するカテゴリがあれば紐づける (categoryRaw + 同ストア)
            if let raw = rule.categoryRaw, !raw.isEmpty,
               let cats = sheet.categories as? Set<ExpenseCategory>,
               let cat = cats.first(where: { $0.name == raw }),
               cat.objectID.persistentStore == sheetStore {
                expense.category = cat
            }
            // FX スナップショット (定期生成時の current FX を凍結)
            expense.captureFXSnapshot()

            rule.lastGeneratedDate = date
            generated += 1
            date = nextDate(after: date, rule: rule)
        }

        return generated
    }

    /// 次の occurrence 日付。
    static func nextDate(after date: Date, rule: RecurringRule) -> Date {
        let cal = Calendar.current
        let component = rule.resolvedFrequency.calendarComponent
        let interval = rule.resolvedInterval
        return cal.date(byAdding: component, value: interval, to: date) ?? date
    }
}

//
//  SampleDataGenerator.swift
//  Expenso
//
//  デバッグ用: 「テスト」という名前のシートに直近 30 日のサンプル支出を 30 件挿入する。
//  シートが無ければ自動作成 + デフォルトカテゴリも seed する。
//

import Foundation
import CoreData

enum SampleDataGenerator {
    private struct Sample {
        let title: String
        let amount: Double
        let categoryName: String
    }

    private static let samples: [Sample] = [
        // 食費
        .init(title: String(localized: "ランチ (定食)"), amount: 980, categoryName: "食費"),
        .init(title: "スーパー (まとめ買い)", amount: 4280, categoryName: "食費"),
        .init(title: String(localized: "コーヒー"), amount: 480, categoryName: "食費"),
        .init(title: String(localized: "コンビニ"), amount: 720, categoryName: "食費"),
        .init(title: "焼肉ディナー", amount: 6500, categoryName: "食費"),
        .init(title: "ベーカリー", amount: 540, categoryName: "食費"),
        .init(title: "居酒屋", amount: 4200, categoryName: "食費"),
        .init(title: "回転寿司", amount: 2800, categoryName: "食費"),
        // 交通
        .init(title: String(localized: "電車 (定期)"), amount: 12500, categoryName: "交通"),
        .init(title: "タクシー", amount: 1840, categoryName: "交通"),
        .init(title: "ガソリン", amount: 4200, categoryName: "交通"),
        .init(title: "バス", amount: 240, categoryName: "交通"),
        .init(title: "新幹線", amount: 14500, categoryName: "交通"),
        // 住居
        .init(title: String(localized: "電気代"), amount: 8400, categoryName: "光熱費"),
        .init(title: "ガス代", amount: 4200, categoryName: "光熱費"),
        .init(title: "水道代", amount: 3500, categoryName: "光熱費"),
        // 娯楽
        .init(title: String(localized: "映画"), amount: 1900, categoryName: "娯楽"),
        .init(title: "Netflix", amount: 1490, categoryName: "娯楽"),
        .init(title: "Spotify", amount: 980, categoryName: "娯楽"),
        .init(title: "ゲーム", amount: 7800, categoryName: "娯楽"),
        // 買い物
        .init(title: String(localized: "服 (シャツ)"), amount: 5800, categoryName: "買い物"),
        .init(title: "本", amount: 1980, categoryName: "買い物"),
        .init(title: "Amazon", amount: 3450, categoryName: "買い物"),
        // 医療
        .init(title: String(localized: "ドラッグストア"), amount: 2100, categoryName: "医療"),
        .init(title: "病院 (診察)", amount: 1500, categoryName: "医療"),
        // 教育
        .init(title: String(localized: "書籍 (技術書)"), amount: 3520, categoryName: "教育"),
        // 旅行
        .init(title: String(localized: "宿泊 (1 泊)"), amount: 9800, categoryName: "旅行"),
        // その他
        .init(title: "美容院", amount: 4500, categoryName: "その他"),
        .init(title: "プレゼント", amount: 6800, categoryName: "その他"),
        .init(title: "募金", amount: 1000, categoryName: "その他")
    ]

    /// 「テスト」シートに 30 件のサンプル支出を追加する。
    /// シートが無ければ作成 + デフォルトカテゴリを seed する。
    static func populateTestSheet(in ctx: NSManagedObjectContext) {
        let sheet = ensureTestSheet(in: ctx)
        let categoryByName = lookupCategories(in: sheet)

        let cal = Calendar.current
        let now = Date()
        let myName = UserProfileStore.shared.resolvedDisplayName

        for (i, sample) in samples.enumerated() {
            let daysAgo = i % 30
            let hour = (i * 7 + 9) % 24
            let minute = (i * 13) % 60
            let dayStart = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            let date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart) ?? dayStart

            let expense = Expense(context: ctx)
            expense.amount = NSDecimalNumber(value: sample.amount)
            expense.currencyCode = sheet.resolvedDefaultCurrencyCode
            expense.kindRaw = TransactionKind.expense.rawValue
            expense.date = date
            expense.title = sample.title
            expense.note = ""
            expense.createdAt = .now
            expense.sheet = sheet
            expense.category = categoryByName[sample.categoryName]
            expense.paidBy = myName
            if let myID = UserProfileStore.shared.selfMemberID {
                expense.payerMemberID = myID
            }
            if let store = sheet.objectID.persistentStore {
                ctx.assign(expense, to: store)
            }
        }
        try? ctx.save()
    }

    private static func ensureTestSheet(in ctx: NSManagedObjectContext) -> ExpenseSheet {
        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        req.predicate = NSPredicate(format: "name == %@", "テスト")
        req.fetchLimit = 1
        if let existing = (try? ctx.fetch(req))?.first { return existing }

        let sheet = ExpenseSheet(context: ctx)
        sheet.name = "テスト"
        sheet.symbol = "wand.and.stars"
        sheet.colorHex = "#AF52DE"
        sheet.defaultCurrencyCode = CurrencyCatalog.defaultCode
        sheet.createdAt = .now
        PersistenceController.seedDefaultCategories(for: sheet, in: ctx)
        return sheet
    }

    private static func lookupCategories(in sheet: ExpenseSheet) -> [String: ExpenseCategory] {
        guard let cats = sheet.categories as? Set<ExpenseCategory> else { return [:] }
        var dict: [String: ExpenseCategory] = [:]
        for cat in cats {
            if let n = cat.name, !n.isEmpty {
                dict[n] = cat
            }
        }
        return dict
    }
}

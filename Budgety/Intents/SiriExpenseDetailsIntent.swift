#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation
import SwiftUI

@available(iOS 27.3, *)
struct SiriExpenseDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "支出名で明細を確認"
    static let description = IntentDescription("指定したシートの支出を名前や対象月で探し、件数、通貨別の合計、最新5件までの支出名・日付・金額・カテゴリを返します。支出名と対象月を省略すると最近の支出を確認できます。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "シート名を指定された場合だけ設定します。省略時は最後に開いたシートを使い、特定できなければ選択を求めます。")
    var sheet: ExpenseSheetEntity?

    @Parameter(title: "支出名", description: "「ランチ」や店名など、支出の名前に含まれる言葉。省略するとすべての支出名が対象になります。")
    var expenseName: String?

    @Parameter(title: "対象月", description: "探したい月に含まれる日付。省略すると全期間を対象にします。")
    var month: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Existing personal shortcuts consume this action's text output.
        let result = try await SiriExpenseLookup.run(sheet: sheet, expenseName: expenseName, month: month) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートで支出を検索しますか？")
        }
        return .result(value: result.report, dialog: IntentDialog("\(result.report)"))
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriFindExpenseCardsIntent: AppIntent {
    static let title: LocalizedStringResource = "支出明細を検索してカードで表示"
    static let description = IntentDescription("支出の名前や月でシートを検索します。最近の支出や特定の支出について、日付・支出名・金額・カテゴリが並ぶカードと、一致した件数・通貨別合計を返します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "指定されたシート。省略時は最後に開いたシートを使います。")
    var sheet: ExpenseSheetEntity?
    @Parameter(title: "支出名", description: "「ランチ」や店名など、支出名に含まれる言葉。最近の支出を一覧にするときは省略します。")
    var expenseName: String?
    @Parameter(title: "対象月", description: "指定された月に含まれる日付。省略時は全期間を検索します。")
    var month: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriExpenseCardResult> & ProvidesDialog & ShowsSnippetView {
        let result = try await SiriExpenseLookup.run(sheet: sheet, expenseName: expenseName, month: month) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートで支出を検索しますか？")
        }
        return .result(value: result.card, dialog: IntentDialog("\(result.summary)"),
                       view: SiriExpenseCardView(result: result.card))
    }
}

@available(iOS 27.3, *)
private enum SiriExpenseLookup {
    @MainActor
    static func run(sheet: ExpenseSheetEntity?, expenseName: String?, month: Date?,
                    choosing: ([ExpenseSheetEntity]) async throws -> ExpenseSheetEntity) async throws
        -> (report: String, summary: String, card: SiriExpenseCardResult) {
        let viewContext = PersistenceController.shared.container.viewContext
        let sheetID: String
        if let sheet {
            sheetID = sheet.id
        } else if let lastID = UserDefaults.standard.string(forKey: "lastOpenedSheetURI"), !lastID.isEmpty {
            sheetID = lastID
        } else {
            let candidates = try IntentSheetAccess(checking: viewContext).sheets().map(ExpenseSheetEntity.from)
            guard let first = candidates.first else { throw AppIntentError.sheetNotFound }
            if candidates.count == 1 {
                sheetID = first.id
            } else {
                let choice = try await choosing(candidates)
                sheetID = choice.id
            }
        }
        // Validate even a remembered or just-confirmed sheet in case its lock changed.
        let access = try IntentSheetAccess(checking: viewContext)
        let record = try access.resolve(sheetID)
        let request = NSFetchRequest<Expense>(entityName: "Expense")
        var filters = [NSPredicate(format: "sheet == %@", record)]
        if let month, let interval = Calendar.current.dateInterval(of: .month, for: month) {
            filters.append(NSPredicate(format: "date >= %@ AND date < %@", interval.start as NSDate, interval.end as NSDate))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: filters)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Expense.date, ascending: false),
                                   NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)]
        request.fetchBatchSize = 64

        let name = (expenseName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query = Self.searchKey(name)
        var count = 0
        var totals: [String: Decimal] = [:]
        var rows: [SiriExpenseCardRow] = []
        lazy var isSoloSheet = !record.hasAcceptedOtherMembers()
        for expense in try access.context.fetch(request) where expense.kind == .expense && !expense.isSkipped {
            let title = expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle
            guard query.isEmpty || Self.searchKey(title).contains(query) else { continue }
            count += 1
            let currency = expense.resolvedCurrencyCode.uppercased()
            totals[currency, default: 0] += expense.amountDecimal
            if rows.count < 5 {
                let day = expense.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "日付不明")
                let amount = expense.amountDecimal.formatted(.currency(code: currency).presentation(.isoCode))
                let category = expense.categoryDisplayName
                let payer = SiriExpensePayer.snapshot(for: expense, isSoloSheet: isSoloSheet)
                rows.append(SiriExpenseCardRow(title: title, date: day, category: category, amount: amount,
                                               categoryColorHex: expense.resolvedCategory?.displayColorHex ?? "",
                                               categorySymbol: expense.categorySymbol,
                                               signedAmount: expense.formattedSignedAmount,
                                               payerName: payer?.name, payerColorHex: payer?.colorHex ?? "",
                                               payerPhoto: payer?.photo,
                                               foreignCurrencyCode: currency == record.resolvedDefaultCurrencyCode ? nil : currency))
            }
        }

        let period = month?.formatted(.dateTime.year().month(.wide)) ?? String(localized: "全期間")
        let scope = name.isEmpty ? String(localized: "「\(record.displayName)」の\(period)の支出")
            : String(localized: "「\(record.displayName)」の\(period)で支出名に「\(name)」を含む明細")
        let summary: String
        let amounts = totals.sorted { $0.key < $1.key }.map { currency, total in
            total.formatted(.currency(code: currency).presentation(.isoCode))
        }.formatted(.list(type: .and))
        if count == 0 {
            summary = String(localized: "\(scope)は見つかりませんでした。")
        } else {
            summary = String(localized: "\(scope)は\(count)件、合計は\(amounts)です。")
        }
        var report = summary
        if count > rows.count {
            report += "\n" + String(localized: "新しい順に\(rows.count)件を表示します。")
        }
        for row in rows {
            let label = row.title == row.category ? row.title : String(localized: "\(row.title)（\(row.category)）")
            report += "\n" + String(localized: "\(row.date)　\(label)　\(row.amount)")
        }
        return (report, summary, SiriExpenseCardResult(sheetName: record.displayName, period: period,
                                                      expenseName: name, count: count, total: amounts, rows: rows))
    }

    private static func searchKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}
#endif

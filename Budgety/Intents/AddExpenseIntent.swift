//
//  AddExpenseIntent.swift
//  Expenso
//
//  AppIntents で支出を背景から追加するインテント。
//  Shortcuts / Siri / Spotlight / Action Button から呼ばれ、UI を開かずに
//  Core Data に Expense を作成し CloudKit に同期させる。
//

import AppIntents
import CoreData
import Foundation

struct AddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "支出を追加"
    static var description = IntentDescription(
        "Budgety のシートに支出を 1 件記録します。今日の日付・支払者は自分が使われます。"
    )
    /// Shortcuts 経由で実行された時の振る舞い:
    /// - openAppWhenRun = false → アプリは前面に出ない (= 完全バックグラウンド実行)
    static var openAppWhenRun: Bool = false

    @Parameter(title: "シート", description: "支出を記録するシート")
    var sheet: ExpenseSheetEntity

    @Parameter(
        title: "金額",
        description: "支払った金額。シートの既定通貨で記録されます。",
        controlStyle: .field
    )
    var amount: Double

    @Parameter(
        title: "カテゴリ",
        description: "支出のカテゴリ。「AI 提案」を選ぶとタイトルから自動推測、「未分類」を選ぶとカテゴリなしで保存します。"
    )
    var category: ExpenseCategoryEntity

    @Parameter(
        title: "タイトル (任意)",
        description: "支出の内容 (例: ランチ)。未入力ならカテゴリ名が表示名になります。"
    )
    var title: String?

    @Parameter(title: "メモ (任意)", default: "")
    var note: String

    @Parameter(
        title: "日付 (任意)",
        description: "未指定の場合は現在時刻で記録します。"
    )
    var date: Date?

    @Parameter(
        title: "日付テキスト (任意)",
        description: "ISO8601 文字列 (例: 2026-05-03T19:30:00Z) が指定されたら、こちらが「日付」より優先されます。"
    )
    var dateText: String?

    @Parameter(
        title: "シート名 (任意)",
        description: "シート名 (例: 家計簿、仕事) を文字列で指定。設定すると「シート」パラメータより優先されます。MCP / 自動化向け。"
    )
    var sheetName: String?

    // タイトルは入力させない (= 任意・詳細配下)。必須は シート → 金額 → カテゴリ の
    // 順に尋ね、カテゴリを最後に選ばせる。
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) に \(\.$amount) を \(\.$category) で追加") {
            \.$title
            \.$note
            \.$date
            \.$dateText
            \.$sheetName
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext

        // シート解決順位:
        //   1) sheetName (文字列) で名前一致 → 見つかればそれ
        //   2) sheet entity が指定されていればそれ
        //   3) 一番古いシートをフォールバック (= MCP / Shortcuts の素朴呼び出し向け)
        let coreSheet: ExpenseSheet
        if let name = sheetName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            // 全シートを取得して name で比較 (predicate より柔軟。
            // CloudKit / 共有ストア越境や正規化差異にも強い)。
            let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
            req.returnsObjectsAsFaults = false
            let all = (try? ctx.fetch(req)) ?? []
            if let found = all.first(where: { ($0.name ?? "") == name }) {
                coreSheet = found
            } else if let found = all.first(where: {
                ($0.name ?? "").compare(name, options: .caseInsensitive) == .orderedSame
            }) {
                coreSheet = found
            } else {
                let availableNames = all.compactMap { $0.name }.joined(separator: ", ")
                throw AppIntentError.sheetNotFoundWithList(
                    requested: name,
                    available: availableNames.isEmpty ? "(empty)" : availableNames
                )
            }
        } else if let url = URL(string: sheet.id),
                  let oid = pc.container.persistentStoreCoordinator
                    .managedObjectID(forURIRepresentation: url),
                  let resolved = try? ctx.existingObject(with: oid) as? ExpenseSheet {
            coreSheet = resolved
        } else {
            let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
            req.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)]
            req.fetchLimit = 1
            guard let fallback = (try? ctx.fetch(req))?.first else {
                throw AppIntentError.sheetNotFound
            }
            coreSheet = fallback
        }

        // タイトルは任意。未入力なら表示名はカテゴリ名にフォールバックする (nil で保存)。
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard amount > 0 else {
            throw AppIntentError.invalidAmount
        }

        let expense = Expense(context: ctx)
        let sheetStore = coreSheet.objectID.persistentStore
        if let store = sheetStore {
            ctx.assign(expense, to: store)
        }

        expense.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        expense.amount = NSDecimalNumber(decimal: Decimal(amount))
        expense.kindRaw = TransactionKind.expense.rawValue
        expense.currencyCode = coreSheet.resolvedDefaultCurrencyCode
        expense.date = Self.resolveDate(date: date, dateText: dateText)
        expense.note = note
        expense.createdAt = .now

        // カテゴリ解決: 選択値 (AI 提案 / 未分類 / 実カテゴリ) をシート内へマップ
        let resolvedCategory = await resolveCategory(
            chosen: category,
            sheet: coreSheet,
            title: trimmedTitle,
            ctx: ctx
        )
        if let cat = resolvedCategory {
            expense.categoryRaw = cat.name
            if cat.objectID.persistentStore == sheetStore {
                expense.category = cat
            }
        }

        // 支払者: 自分。共有シートの場合は canonical (= owner/userRecordName または email)
        // を、非共有シートは userRecordName を payerProfileID として保存。paidBy は廃止。
        let profile = UserProfileStore.shared
        let share = ShareCoordinator.shared.existingShare(for: coreSheet)
        if let pid = profile.canonicalSelfID(forShare: share), !pid.isEmpty {
            expense.payerProfileID = pid
        }
        // ショートカット / MCP からの追加は割り勘にしない (受益者未設定 = 支払者単独負担)。
        // beneficiaryProfileIDs は明示的にセットしない (resolvedBeneficiaryIDs() で
        // 空のままになり、SettlementCalculator では残高変動なしの扱い)。
        if let memberID = profile.selfMemberID {
            expense.payerMemberID = memberID
        }

        expense.sheet = coreSheet

        // 自分の ParticipantProfile をシートに ensure (まだ無ければ作成)
        if BuildInfo.profileFeatureEnabled { profile.ensureProfile(in: coreSheet, ctx: ctx) }

        pc.save()

        let amountDisplay = CurrencyCatalog.format(
            Decimal(amount),
            code: coreSheet.resolvedDefaultCurrencyCode
        )
        let categoryNote = resolvedCategory.map { " / \($0.displayName)" } ?? ""
        // タイトル未入力時はタイトルの引用を出さない。
        let body = trimmedTitle.isEmpty
            ? "\(amountDisplay)\(categoryNote)"
            : "「\(trimmedTitle)」(\(amountDisplay)\(categoryNote))"
        return .result(
            dialog: IntentDialog(
                full: "「\(coreSheet.displayName)」に \(body) を追加しました",
                supporting: "支出を追加しました"
            )
        )
    }

    /// 選択されたカテゴリ entity → シート内の `ExpenseCategory` を返す。
    /// - 「未分類」sentinel → nil (カテゴリなしで保存)
    /// - 「AI 提案」sentinel → FoundationModels でタイトルから推測
    /// - 実カテゴリ → objectID 一致 (同シート) / 名前一致でマップ
    @MainActor
    private func resolveCategory(
        chosen: ExpenseCategoryEntity,
        sheet: ExpenseSheet,
        title: String,
        ctx: NSManagedObjectContext
    ) async -> ExpenseCategory? {
        let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let kindCats = cats.filter { c in
            let raw = c.kindRaw ?? ""
            return raw == TransactionKind.expense.rawValue || raw.isEmpty
        }

        // 「未分類」→ カテゴリなし
        if chosen.id == Self.skipCategoryID { return nil }

        // 「AI 提案」→ FoundationModels で推測
        if chosen.id == ExpenseCategoryEntity.aiSuggestionSentinelID {
            let names = kindCats.map { $0.displayName }
            guard !names.isEmpty,
                  CategoryAISuggestor.isAvailable,
                  let suggestedName = await CategoryAISuggestor.suggest(
                    title: title, kind: .expense, categories: names
                  )
            else { return nil }
            return kindCats.first(where: { $0.displayName == suggestedName })
        }

        // 実カテゴリ: objectID 一致 (同シート) → 名前一致
        if let url = URL(string: chosen.id),
           let oid = ctx.persistentStoreCoordinator?
            .managedObjectID(forURIRepresentation: url),
           let exact = try? ctx.existingObject(with: oid) as? ExpenseCategory,
           exact.sheet?.objectID == sheet.objectID {
            return exact
        }
        return kindCats.first(where: { $0.displayName == chosen.name })
    }

    /// 「未分類」を表す sentinel id
    static let skipCategoryID = "__expenso_skip_category__"

    /// `dateText` が ISO8601 で解釈できればそれを優先、なければ `date`、それも未指定なら `.now`。
    static func resolveDate(date: Date?, dateText: String?) -> Date {
        if let text = dateText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: text) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: text) { return d }
        }
        return date ?? .now
    }
}

enum AppIntentError: Error, CustomLocalizedStringResourceConvertible {
    case sheetNotFound
    case sheetNotFoundWithList(requested: String, available: String)
    case debugDump(message: String)
    case emptyTitle
    case invalidAmount

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sheetNotFound: "シートが見つかりませんでした。"
        case .sheetNotFoundWithList(let req, let avail):
            "シート \"\(req)\" が見つかりません。利用可能: \(avail)"
        case .debugDump(let msg):
            "DEBUG: \(msg)"
        case .emptyTitle:    "タイトルが空です。"
        case .invalidAmount: "金額は 0 より大きい値を指定してください。"
        }
    }
}

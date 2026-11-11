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
        let selected: ExpenseSheetEntity
        if let name = sheetName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
            let sheets = try access.sheets()
            guard let named = sheets.first(where: { $0.name == name }) ??
                sheets.first(where: { $0.name?.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw AppIntentError.sheetNotFound
            }
            selected = ExpenseSheetEntity.from(named)
        } else {
            selected = sheet
        }
        let dialog = try await Self.record(sheet: selected, amount: amount, title: title,
                                           date: Self.resolveDate(date: date, dateText: dateText),
                                           category: category, note: note)
        return .result(dialog: dialog)
    }

    @MainActor
    static func record(sheet selected: ExpenseSheetEntity, amount: Double, title: String? = nil,
                       date: Date = .now, category: ExpenseCategoryEntity? = nil,
                       note: String = "", currencyCode: String? = nil) async throws -> IntentDialog {
        guard amount.isFinite, amount > 0 else { throw AppIntentError.invalidAmount }
        let currency = currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let currency, !CurrencyCatalog.all.contains(where: { $0.code == currency }) {
            throw AppIntentError.unsupportedCurrency
        }
        let value = Decimal(amount)
        guard !value.isNaN, value > 0 else { throw AppIntentError.invalidAmount }
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let viewContext = PersistenceController.shared.container.viewContext
        let lookup = try IntentSheetAccess(checking: viewContext)
        let selectedSheet = try lookup.resolve(selected.id)
        let categoryID = await resolveCategory(chosen: category, sheet: selectedSheet,
                                               title: trimmedTitle, ctx: lookup.context)?.objectID

        // AI classification can suspend. Resolve the same ID again before making any changes.
        try Task.checkCancellation()
        let transaction = try IntentSheetAccess(checking: viewContext)
        let ctx = transaction.context
        let coreSheet = try transaction.resolve(selected.id)
        let resolvedCategory = categoryID.flatMap { try? ctx.existingObject(with: $0) as? ExpenseCategory }
            .flatMap { $0.sheet?.objectID == coreSheet.objectID ? $0 : nil }
        let expense = Expense(context: ctx)
        let sheetStore = coreSheet.objectID.persistentStore
        if let store = sheetStore {
            ctx.assign(expense, to: store)
        }

        expense.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        expense.amount = NSDecimalNumber(decimal: value)
        expense.kindRaw = TransactionKind.expense.rawValue
        let recordedCurrency = currency ?? coreSheet.resolvedDefaultCurrencyCode
        expense.currencyCode = recordedCurrency
        expense.date = date
        expense.note = note
        expense.createdAt = .now

        // カテゴリ解決: 選択値 (AI 提案 / 未分類 / 実カテゴリ) をシート内へマップ
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
        // FX スナップショット (Shortcut 経由でも current FX で凍結)
        expense.captureFXSnapshot()

        // 自分の ParticipantProfile をシートに ensure (まだ無ければ作成)
        if BuildInfo.profileFeatureEnabled { profile.ensureProfile(in: coreSheet, ctx: ctx, saveChanges: false) }

        try ctx.save()

        let amountDisplay = CurrencyCatalog.format(
            value,
            code: recordedCurrency
        )
        let categoryNote = resolvedCategory.map { " / \($0.displayName)" } ?? ""
        // タイトル未入力時はタイトルの引用を出さない。
        let body = trimmedTitle.isEmpty
            ? "\(amountDisplay)\(categoryNote)"
            : "「\(trimmedTitle)」(\(amountDisplay)\(categoryNote))"
        return IntentDialog(full: "「\(coreSheet.displayName)」に \(body) を追加しました",
                            supporting: "支出を追加しました")
    }

    /// 選択されたカテゴリ entity → シート内の `ExpenseCategory` を返す。
    /// - 「未分類」sentinel → nil (カテゴリなしで保存)
    /// - 「AI 提案」sentinel → FoundationModels でタイトルから推測
    /// - 実カテゴリ → objectID 一致 (同シート) / 名前一致でマップ
    @MainActor
    private static func resolveCategory(
        chosen: ExpenseCategoryEntity?,
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
        if chosen?.id == Self.skipCategoryID { return nil }

        // 「AI 提案」→ ①過去の自分の分類履歴 → ②FoundationModels で推測
        if chosen == nil || chosen?.id == ExpenseCategoryEntity.aiSuggestionSentinelID {
            if let hist = CategoryHistorySuggestor.suggest(title: title, kind: .expense, in: sheet) {
                return hist
            }
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
        guard let chosen else { return nil }
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
    case expenseUnavailable
    case debugDump(message: String)
    case emptyTitle
    case invalidAmount
    case unsupportedCurrency

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sheetNotFound: "シートが見つかりませんでした。"
        case .expenseUnavailable: "この支出明細は現在表示できません。"
        case .debugDump(let msg):
            "DEBUG: \(msg)"
        case .emptyTitle:    "タイトルが空です。"
        case .unsupportedCurrency: "この通貨はBudgetyで記録できません。"
        case .invalidAmount: "金額は 0 より大きい値を指定してください。"
        }
    }
}

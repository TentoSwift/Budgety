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
    #if os(watchOS)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    #endif

    @Parameter(title: "シート", description: "支出を記録するシート")
    var sheet: ExpenseSheetEntity

    @Parameter(
        title: "金額",
        description: "実際に支払った金額。通貨を指定しなければシートの既定通貨で記録します。",
        controlStyle: .field
    )
    var amount: Double

    @Parameter(title: "支払通貨", description: "支払額の通貨。「1,200円」なら、シートが米ドルでも日本円を選びます。",
               optionsProvider: SiriCurrencyOptions())
    var currencyCode: String?

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

    @Parameter(title: "支払者", description: "このシートのメンバー。省略すると自分が支払者になります。")
    var payer: SiriSheetMemberEntity?

    @Parameter(title: "全員で割り勘", description: "このシートの現在のメンバー全員で均等に分けます。")
    var splitAll: Bool?

    @Parameter(title: "割り勘するメンバー", description: "金額を負担する人を選びます。選択したメンバーだけで均等に分けます。")
    var beneficiaries: [SiriSheetMemberEntity]?

    // タイトルは入力させない (= 任意・詳細配下)。必須は シート → 金額 → カテゴリ の
    // 順に尋ね、カテゴリを最後に選ばせる。
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) に \(\.$amount) を \(\.$category) で追加") {
            \.$title
            \.$currencyCode
            \.$note
            \.$date
            \.$dateText
            \.$sheetName
            \.$payer
            \.$splitAll
            \.$beneficiaries
        }
    }

    #if os(watchOS) || (os(iOS) && canImport(AppIntents, _version: 301.2.7.2))
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let saved = try await recordSelectedExpense()
        if #available(iOS 27.3, watchOS 26.0, *) {
            let snippet = SiriRecordedTransactionSnippetIntent(identifier: saved.transaction.objectID.uriRepresentation().absoluteString)
            return .result(dialog: saved.dialog, snippetIntent: snippet)
        }
        return .result(dialog: saved.dialog, snippetIntent: EmptySnippetIntent())
    }
    #else
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let saved = try await recordSelectedExpense()
        return .result(dialog: saved.dialog)
    }
    #endif

    @MainActor
    private func recordSelectedExpense() async throws -> RecordedTransaction {
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
        return try await Self.recordTransaction(sheet: selected, kind: .expense, amount: amount, title: title,
                                                date: Self.resolveDate(date: date, dateText: dateText),
                                                category: category, note: note, currencyCode: currencyCode, payer: payer,
                                                splitAll: splitAll ?? false, beneficiaries: beneficiaries ?? [])
    }

    @MainActor
    static func record(sheet selected: ExpenseSheetEntity, amount: Double, title: String? = nil,
                       date: Date = .now, category: ExpenseCategoryEntity? = nil,
                       note: String = "", currencyCode: String? = nil) async throws -> IntentDialog {
        try await recordTransaction(sheet: selected, kind: .expense, amount: amount, title: title,
                                    date: date, category: category, note: note, currencyCode: currencyCode).dialog
    }

    struct RecordedTransaction {
        let transaction: Expense
        let sheet: ExpenseSheet
        let dialog: IntentDialog
        // NSManagedObject does not retain its context; keep the saved row and its relationships usable.
        let context: NSManagedObjectContext
    }

    @MainActor
    static func recordTransaction(sheet selected: ExpenseSheetEntity, kind: TransactionKind, amount: Double,
                                  title: String? = nil, date: Date = .now, category: ExpenseCategoryEntity? = nil,
                                  note: String = "", currencyCode: String? = nil, payer: SiriSheetMemberEntity? = nil,
                                  splitAll: Bool = false, beneficiaries: [SiriSheetMemberEntity] = []) async throws -> RecordedTransaction {
        guard let value = CurrencyCatalog.transactionAmount(amount) else { throw AppIntentError.invalidAmount }
        let currency = try currencyCode.map { input in
            guard let code = CurrencyCatalog.transactionCurrencyCode(for: input) else { throw AppIntentError.unsupportedCurrency }
            return code
        }
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let viewContext = PersistenceController.shared.container.viewContext
        let lookup = try IntentSheetAccess(checking: viewContext)
        let selectedSheet = try lookup.resolve(selected.id)
        let categoryID = await resolveCategory(chosen: category, kind: kind, sheet: selectedSheet,
                                               title: trimmedTitle, ctx: lookup.context)?.objectID

        // AI classification can suspend. Resolve the same ID again before making any changes.
        try Task.checkCancellation()
        let transaction = try IntentSheetAccess(checking: viewContext)
        let ctx = transaction.context
        let coreSheet = try transaction.resolve(selected.id)
        let resolvedCategory = categoryID.flatMap { try? ctx.existingObject(with: $0) as? ExpenseCategory }
            .flatMap { $0.sheet?.objectID == coreSheet.objectID && matchesKind($0, kind) ? $0 : nil }
        guard PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: coreSheet.objectID) else {
            throw AppIntentError.sheetNotFound
        }
        let expense = Expense(context: ctx)
        let sheetStore = coreSheet.objectID.persistentStore
        if let store = sheetStore {
            ctx.assign(expense, to: store)
        }

        expense.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        expense.amount = NSDecimalNumber(decimal: value)
        expense.kindRaw = kind.rawValue
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

        let profile = UserProfileStore.shared
        try assignParticipants(to: expense, sheet: coreSheet, access: transaction, payer: payer,
                               splitAll: splitAll, beneficiaries: beneficiaries)
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
        let dialog: IntentDialog
        switch kind {
        case .expense:
            dialog = IntentDialog(full: "「\(coreSheet.displayName)」に \(body) を追加しました", supporting: "支出を追加しました")
        case .income:
            dialog = IntentDialog(full: "「\(coreSheet.displayName)」に \(body) を収入として追加しました", supporting: "収入を追加しました")
        }
        return RecordedTransaction(transaction: expense, sheet: coreSheet, dialog: dialog, context: ctx)
    }

    @MainActor
    private static func assignParticipants(to transaction: Expense, sheet: ExpenseSheet, access: IntentSheetAccess,
                                           payer: SiriSheetMemberEntity?, splitAll: Bool,
                                           beneficiaries: [SiriSheetMemberEntity]) throws {
        let profile = UserProfileStore.shared
        let splitting = splitAll || !beneficiaries.isEmpty
        guard payer != nil || splitting else {
            // Preserve the original shortcuts' default, including sheets without an iCloud identity.
            let share = ShareCoordinator.shared.existingShare(for: sheet)
            if let id = profile.canonicalSelfID(forShare: share), !id.isEmpty { transaction.payerProfileID = id }
            transaction.payerMemberID = profile.selfMemberID
            return
        }
        if splitting, transaction.kind != .expense { throw AppIntentError.incomeCannotSplit }
        let roster = try SiriSheetMemberRoster(sheet: sheet, access: access, preparingToSave: true)
        guard let party = try payer.map(roster.resolve) ?? roster.members.first(where: \.isSelf) else {
            throw AppIntentError.missingPayer
        }
        transaction.payerProfileID = party.profileID
        transaction.payerMemberID = party.memberID
        guard splitting else { return }
        let members = try splitMembers(in: roster, splitAll: splitAll, beneficiaries: beneficiaries)
        transaction.beneficiaryProfileIDs = members.map(\.profileID).sorted().joined(separator: ",")
    }

    @MainActor
    static func splitMembers(in roster: SiriSheetMemberRoster, splitAll: Bool,
                             beneficiaries: [SiriSheetMemberEntity]) throws -> [SiriSheetMemberEntity] {
        let all = Set(roster.members.map(\.id))
        guard all.count > 1 else { throw AppIntentError.noSplitMembers }
        let selected = Set(try beneficiaries.map { try roster.resolve($0).id })
        if splitAll, !selected.isEmpty, selected != all { throw AppIntentError.conflictingSplitMembers }
        let ids = splitAll ? all : selected
        let members = roster.members.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
        // An uninitialized self profile can occur in a read-only edit preview. The write-time
        // roster assigns its stable local UUID before any beneficiary IDs are stored.
        guard !members.isEmpty, members.allSatisfy({ ($0.isSelf || !$0.profileID.isEmpty) && !$0.profileID.contains(",") })
        else { throw AppIntentError.invalidSplitMembers }
        return members
    }

    private static func matchesKind(_ category: ExpenseCategory, _ kind: TransactionKind) -> Bool {
        let raw = category.kindRaw ?? ""
        return raw == kind.rawValue || (kind == .expense && raw.isEmpty)
    }

    /// 選択されたカテゴリ entity → シート内の `ExpenseCategory` を返す。
    /// - 「未分類」sentinel → nil (カテゴリなしで保存)
    /// - 「AI 提案」sentinel → FoundationModels でタイトルから推測
    /// - 実カテゴリ → objectID 一致 (同シート) / 名前一致でマップ
    @MainActor
    private static func resolveCategory(
        chosen: ExpenseCategoryEntity?,
        kind: TransactionKind,
        sheet: ExpenseSheet,
        title: String,
        ctx: NSManagedObjectContext
    ) async -> ExpenseCategory? {
        let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let kindCats = cats.filter { matchesKind($0, kind) }

        // 「未分類」→ カテゴリなし
        if chosen?.id == Self.skipCategoryID { return nil }

        // 「AI 提案」→ ①過去の自分の分類履歴 → ②FoundationModels で推測
        if chosen == nil || chosen?.id == ExpenseCategoryEntity.aiSuggestionSentinelID {
            if let hist = CategoryHistorySuggestor.suggest(title: title, kind: kind, in: sheet), kindCats.contains(hist) {
                return hist
            }
            #if !os(watchOS)
            let names = kindCats.map { $0.displayName }
            guard !names.isEmpty,
                  CategoryAISuggestor.isAvailable,
                  let suggestedName = await CategoryAISuggestor.suggest(
                    title: title, kind: kind, categories: names
                  )
            else { return nil }
            return kindCats.first(where: { $0.displayName == suggestedName })
            #else
            return nil
            #endif
        }

        // 実カテゴリ: objectID 一致 (同シート) → 名前一致
        guard let chosen else { return nil }
        if let url = URL(string: chosen.id),
           let oid = ctx.persistentStoreCoordinator?
            .managedObjectID(forURIRepresentation: url),
           let exact = try? ctx.existingObject(with: oid) as? ExpenseCategory,
           kindCats.contains(exact) {
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

struct SiriCurrencyOptions: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        let currencies = CurrencyCatalog.allOrderedByLocale.map { option in
            IntentItem(option.code, title: "\(option.displayName)", subtitle: "\(option.code)")
        }
        return IntentItemCollection(sections: [IntentItemSection(items: currencies)])
    }
}

enum AppIntentError: Error, CustomLocalizedStringResourceConvertible {
    case sheetNotFound
    case expenseUnavailable
    case debugDump(message: String)
    case emptyTitle
    case invalidAmount
    case unsupportedCurrency
    case missingPayer, incomeCannotSplit, noSplitMembers, conflictingSplitMembers, invalidSplitMembers

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sheetNotFound: "シートが見つかりませんでした。"
        case .expenseUnavailable: "この明細は現在表示できません。"
        case .debugDump(let msg):
            "DEBUG: \(msg)"
        case .emptyTitle:    "タイトルが空です。"
        case .unsupportedCurrency: "この通貨はBudgetyで記録できません。"
        case .invalidAmount: "金額は 0 より大きい値を指定してください。"
        case .missingPayer: "このシートの支払者を選んでください。"
        case .incomeCannotSplit: "割り勘は支出に設定できます。"
        case .noSplitMembers: "割り勘にはシートに2人以上のメンバーが必要です。"
        case .conflictingSplitMembers: "全員で割り勘するか、割り勘するメンバーを指定してください。"
        case .invalidSplitMembers: "選択したメンバーで割り勘を保存できません。"
        }
    }
}

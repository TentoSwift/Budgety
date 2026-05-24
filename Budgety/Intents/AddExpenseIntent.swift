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

    @Parameter(title: "シート", description: "支出を記録するシート (未指定の場合は一番古いシートに記録)")
    var sheet: ExpenseSheetEntity?

    @Parameter(title: "タイトル", description: "支出の内容 (例: ランチ)")
    var title: String

    @Parameter(
        title: "金額",
        description: "支払った金額。シートの既定通貨で記録されます。",
        controlStyle: .field
    )
    var amount: Double

    @Parameter(
        title: "カテゴリ (任意)",
        description: "未指定の場合、FoundationModels がタイトルから推測します。"
    )
    var category: ExpenseCategoryEntity?

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

    // シートとカテゴリはメイン行に出して、その場で選べるようにする。
    // 日時/メモ/MCP 用の文字列指定は「詳細を表示」配下に隠す。
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) の \(\.$category) に \(\.$title) (\(\.$amount)) を追加") {
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
        } else if let entity = sheet,
                  let url = URL(string: entity.id),
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

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw AppIntentError.emptyTitle
        }
        guard amount > 0 else {
            throw AppIntentError.invalidAmount
        }

        let expense = Expense(context: ctx)
        let sheetStore = coreSheet.objectID.persistentStore
        if let store = sheetStore {
            ctx.assign(expense, to: store)
        }

        expense.title = trimmedTitle
        expense.amount = NSDecimalNumber(decimal: Decimal(amount))
        expense.kindRaw = TransactionKind.expense.rawValue
        expense.currencyCode = coreSheet.resolvedDefaultCurrencyCode
        expense.date = Self.resolveDate(date: date, dateText: dateText)
        expense.note = note
        expense.createdAt = .now

        // カテゴリ解決: ユーザー指定 → シート内のカテゴリへマップ → AI 推測 → 確認ダイアログ
        let resolvedCategory = try await resolveCategory(
            chosen: category,
            sheet: coreSheet,
            title: trimmedTitle,
            ctx: ctx,
            sheetStore: sheetStore
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
        let categoryNote = resolvedCategory.map { " /  \($0.displayName)" } ?? ""
        return .result(
            dialog: IntentDialog(
                full: "「\(coreSheet.displayName)」に「\(trimmedTitle)」(\(amountDisplay)\(categoryNote)) を追加しました",
                supporting: "支出を追加しました"
            )
        )
    }

    /// 入力カテゴリ → シート内の `ExpenseCategory` を返す。
    /// 1. ユーザーが指定 → そのシート内で同名 (+ 支出 kind) を探してマッチ
    /// 2. 未指定 → FoundationModels で推測 → ユーザーに確認ダイアログを出す
    /// 3. 拒否・利用不可 → nil (= 未分類で保存)
    @MainActor
    private func resolveCategory(
        chosen: ExpenseCategoryEntity?,
        sheet: ExpenseSheet,
        title: String,
        ctx: NSManagedObjectContext,
        sheetStore: NSPersistentStore?
    ) async throws -> ExpenseCategory? {
        let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let kindCats = cats.filter { c in
            let raw = c.kindRaw ?? ""
            return raw == TransactionKind.expense.rawValue ||
                   raw.isEmpty
        }
        let names = kindCats.map { $0.displayName }

        // AI 提案を求める helper
        @MainActor
        func runAISuggestion() async -> ExpenseCategory? {
            guard !names.isEmpty,
                  CategoryAISuggestor.isAvailable,
                  let suggestedName = await CategoryAISuggestor.suggest(
                    title: title,
                    kind: .expense,
                    categories: names
                  )
            else { return nil }
            return kindCats.first(where: { $0.displayName == suggestedName })
        }

        // 1a) ユーザーが「AI 提案」sentinel を選択 → 即 AI 自動採用
        if let chosen, chosen.id == ExpenseCategoryEntity.aiSuggestionSentinelID {
            return await runAISuggestion()
        }
        // 1b) 通常のカテゴリ指定 → そのシート内で同名のカテゴリを探す
        if let chosen {
            if let url = URL(string: chosen.id),
               let oid = ctx.persistentStoreCoordinator?
                .managedObjectID(forURIRepresentation: url),
               let exact = try? ctx.existingObject(with: oid) as? ExpenseCategory,
               exact.sheet?.objectID == sheet.objectID {
                return exact
            }
            if let match = kindCats.first(where: { $0.displayName == chosen.name }) {
                return match
            }
        }

        // 2) カテゴリ未指定 → AI 推測 + 3 択 (AI 提案 / 自分で選ぶ / 未分類のまま) ダイアログ
        guard !names.isEmpty else { return nil }
        let suggestedCat = await runAISuggestion()

        // 選択肢を組み立て:
        //   - AI 提案 (subtitle "AI 提案") ※あれば先頭
        //   - シート内のその他カテゴリ (sortOrder 順)
        //   - "未分類のまま" sentinel (id = skipCategoryID)
        var options: [ExpenseCategoryEntity] = []
        if let suggestedCat {
            // 推奨はカテゴリ symbol (色付き) + apple.intelligence を横並びにした composite アイコン。
            // subtitle は "提案" のみ (シート名は出さない)。
            options.append(ExpenseCategoryEntity(
                id: suggestedCat.objectID.uriRepresentation().absoluteString,
                name: suggestedCat.displayName,
                sheetName: "提案",
                kindRaw: suggestedCat.kindRaw ?? TransactionKind.expense.rawValue,
                symbol: suggestedCat.displaySymbol,
                colorHex: suggestedCat.displayColorHex,
                iconData: ExpenseCategoryEntity.renderAISuggestionSymbol(
                    suggestedCat.displaySymbol,
                    colorHex: suggestedCat.displayColorHex
                )
            ))
        }
        let sortedOthers = kindCats
            .filter { $0.objectID != suggestedCat?.objectID }
            .sorted { $0.sortOrder < $1.sortOrder }
        for cat in sortedOthers {
            options.append(ExpenseCategoryEntity.from(cat))
        }
        let unfiledColor = "#8E8E93"
        options.append(ExpenseCategoryEntity(
            id: Self.skipCategoryID,
            name: "未分類のまま",
            sheetName: "(カテゴリなしで保存)",
            kindRaw: "",
            symbol: "list.bullet",
            colorHex: unfiledColor,
            iconData: ExpenseCategoryEntity.renderColoredSymbol(
                "list.bullet",
                colorHex: unfiledColor
            )
        ))

        let dialog: IntentDialog = {
            if let suggestedCat {
                return IntentDialog(
                    "「\(title)」のカテゴリを選んでください。提案: 「\(suggestedCat.displayName)」"
                )
            }
            return IntentDialog("「\(title)」のカテゴリを選んでください。")
        }()

        do {
            let chosen = try await $category.requestDisambiguation(
                among: options,
                dialog: dialog
            )
            // Skip sentinel → 未分類
            if chosen.id == Self.skipCategoryID { return nil }
            // 選ばれた entity の objectID から ExpenseCategory を解決
            if let url = URL(string: chosen.id),
               let oid = ctx.persistentStoreCoordinator?
                .managedObjectID(forURIRepresentation: url),
               let cat = try? ctx.existingObject(with: oid) as? ExpenseCategory {
                return cat
            }
            // フォールバック: 名前一致でシート内検索
            return kindCats.first(where: { $0.displayName == chosen.name })
        } catch {
            // ユーザーがキャンセル / エラー → 未分類で保存
            return nil
        }
    }

    /// 「未分類のまま」を表す sentinel id
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

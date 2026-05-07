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
        "Expenso のシートに支出を 1 件記録します。今日の日付・支払者は自分が使われます。"
    )
    /// Shortcuts 経由で実行された時の振る舞い:
    /// - openAppWhenRun = false → アプリは前面に出ない (= 完全バックグラウンド実行)
    static var openAppWhenRun: Bool = false

    @Parameter(title: "シート", description: "支出を記録するシート")
    var sheet: ExpenseSheetEntity

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

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) に \(\.$title) (\(\.$amount)) を追加") {
            \.$category
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext

        // Entity の id (= objectID URI) から実体を引く
        guard let url = URL(string: sheet.id),
              let oid = pc.container.persistentStoreCoordinator
                .managedObjectID(forURIRepresentation: url),
              let coreSheet = try? ctx.existingObject(with: oid) as? ExpenseSheet
        else {
            throw AppIntentError.sheetNotFound
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
        expense.date = .now
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

        // 支払者: 自分 (UserProfileStore のキャッシュから埋める)
        let profile = UserProfileStore.shared
        if let rn = profile.userRecordName, !rn.isEmpty {
            expense.payerProfileID = rn
            expense.paidBy = profile.resolvedDisplayName
        }
        if let memberID = profile.selfMemberID {
            expense.payerMemberID = memberID
        }

        expense.sheet = coreSheet

        // 自分の ParticipantProfile をシートに ensure (まだ無ければ作成)
        profile.ensureProfile(in: coreSheet, ctx: ctx)

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
        // 1) ユーザー指定があれば、そのシート内で同名のカテゴリを探す
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

        // 2) AI 推測 + 3 択 (AI 提案 / 自分で選ぶ / 未分類のまま) ダイアログ
        let names = kindCats.map { $0.displayName }
        guard !names.isEmpty else { return nil }

        // AI 提案 (利用可能な時のみ)
        var suggestedCat: ExpenseCategory? = nil
        if CategoryAISuggestor.isAvailable,
           let suggestedName = await CategoryAISuggestor.suggest(
            title: title,
            kind: .expense,
            categories: names
           ) {
            suggestedCat = kindCats.first(where: { $0.displayName == suggestedName })
        }

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
        options.append(ExpenseCategoryEntity(
            id: Self.skipCategoryID,
            name: "未分類のまま",
            sheetName: "(カテゴリなしで保存)",
            kindRaw: "",
            symbol: "questionmark.circle",
            colorHex: "#8E8E93",
            iconData: nil
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
}

enum AppIntentError: Error, CustomLocalizedStringResourceConvertible {
    case sheetNotFound
    case emptyTitle
    case invalidAmount

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sheetNotFound: "シートが見つかりませんでした。"
        case .emptyTitle:    "タイトルが空です。"
        case .invalidAmount: "金額は 0 より大きい値を指定してください。"
        }
    }
}

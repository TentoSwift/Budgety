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

        // 2) AI 推測 + 確認ダイアログ
        guard CategoryAISuggestor.isAvailable else { return nil }
        let names = kindCats.map { $0.displayName }
        guard !names.isEmpty else { return nil }
        let suggestedName = await CategoryAISuggestor.suggest(
            title: title,
            kind: .expense,
            categories: names
        )
        guard let suggestedName,
              let suggestedCat = kindCats.first(where: { $0.displayName == suggestedName })
        else { return nil }

        // ユーザーに「この提案を使うか?」を確認 (Yes/No ダイアログ)
        let suggestedEntity = ExpenseCategoryEntity.from(suggestedCat)
        do {
            let accepted = try await $category.requestConfirmation(
                for: suggestedEntity,
                dialog: IntentDialog(
                    "「\(title)」のカテゴリは「\(suggestedCat.displayName)」で良いですか? (AI が推測しました)"
                )
            )
            return accepted ? suggestedCat : nil
        } catch {
            // ユーザーがキャンセル → 未分類で保存
            return nil
        }
    }
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

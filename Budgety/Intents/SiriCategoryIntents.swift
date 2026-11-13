#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriListCategoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "シートのカテゴリを表示"
    static let description = IntentDescription("「家計のカテゴリ一覧」「どんな収入カテゴリがある？」など、利用できるカテゴリの一覧を明示的に求めたときに、シートのカテゴリ名とアイコンを一覧カードで返します。", searchKeywords: ["カテゴリ一覧", "カテゴリー一覧", "利用できるカテゴリ"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート", description: "カテゴリの一覧を表示するシート。変更する明細の指定ではありません。") var sheet: ExpenseSheetEntity?
    @Parameter(title: "種別", description: "支出か収入が指定された場合だけ設定します。") var kind: TransactionKind?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSheetDirectoryResult> & ProvidesDialog & ShowsSnippetIntent {
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートのカテゴリを表示しますか？")
        }
        let contents: SiriDirectoryContents = switch kind {
        case .expense: .expenseCategories
        case .income: .incomeCategories
        case nil: .categories
        }
        let result = try SiriSheetDirectoryResult.load(sheetID: sheetID, contents: contents)
        return .result(value: result, dialog: IntentDialog("\(result.summary)"),
                       snippetIntent: SiriSheetDirectorySnippetIntent(sheetID: sheetID, contents: contents))
    }
}

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriAddCategoryIntent: AppIntent {
    static let title: LocalizedStringResource = "シートにカテゴリを追加"
    static let description = IntentDescription("「家計に習い事という支出カテゴリを追加」「副業という収入カテゴリを新しく作成」など、新しいカテゴリ自体の作成を明示的に求めたときに、指定したシートにカテゴリを追加します。", searchKeywords: ["カテゴリを作成", "カテゴリを登録", "カテゴリー追加"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "カテゴリ名", description: "新しく作成するカテゴリの名前。明細に割り当てる既存のカテゴリ名ではありません。") var name: String
    @Parameter(title: "種別", description: "種別が省略された場合は支出です。") var kind: TransactionKind?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ExpenseCategoryEntity> & ProvidesDialog {
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートにカテゴリを追加しますか？")
        }
        let kind = kind ?? .expense
        let result = try SiriCategoryStore.add(name: name, kind: kind, sheetID: sheetID)
        return .result(value: result, dialog: "\(kind.label)カテゴリ「\(result.name)」を追加しました。")
    }
}

@available(iOS 27.3, macOS 27.3, *)
@MainActor
enum SiriCategoryStore {
    private enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case emptyName, duplicate, readOnly, editing
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .emptyName: "追加するカテゴリ名を教えてください。"
            case .duplicate: "このシートには同じ種別・名前のカテゴリがあります。"
            case .readOnly: "このシートにはカテゴリを追加できません。"
            case .editing: "このシートのカテゴリを編集中です。保存してからもう一度お試しください。"
            }
        }
    }

    static func sortedCategories(in sheet: ExpenseSheet) -> [ExpenseCategory] {
        let categories = sheet.categories as? Set<ExpenseCategory> ?? []
        return categories.filter { !$0.isDeleted }.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .expense }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
        }
    }

    static func add(name: String, kind: TransactionKind, sheetID: String) throws -> ExpenseCategoryEntity {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        let container = PersistenceController.shared.container
        let access = try IntentSheetAccess(checking: container.viewContext)
        let sheet = try access.resolve(sheetID)
        guard container.canUpdateRecord(forManagedObjectWith: sheet.objectID) else { throw Failure.readOnly }
        let viewContext = access.viewContext
        if viewContext.hasChanges {
            let changed = viewContext.insertedObjects.union(viewContext.updatedObjects).union(viewContext.deletedObjects)
            for case let category as ExpenseCategory in changed {
                let previous = category.isInserted ? nil : category.committedValues(forKeys: ["sheet"])["sheet"] as? ExpenseSheet
                if category.sheet?.objectID == sheet.objectID || previous?.objectID == sheet.objectID { throw Failure.editing }
            }
        }

        let categories = sortedCategories(in: sheet)
        guard !categories.contains(where: {
            $0.kind == kind && $0.displayName.compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }) else { throw Failure.duplicate }

        try Task.checkCancellation()
        let category = ExpenseCategory(context: access.context)
        if let store = sheet.objectID.persistentStore { access.context.assign(category, to: store) }
        category.id = UUID()
        category.name = name
        category.kind = kind
        category.sheet = sheet
        category.symbol = kind == .income ? "briefcase.fill" : "tag.fill"
        category.colorHex = kind == .income ? "#34C759" : "#FF9500"
        category.isBuiltIn = false
        category.createdAt = .now
        category.sortOrder = Int32(clamping: Int64(categories.map(\.sortOrder).max() ?? -1) + 1)
        try access.context.save()
        return ExpenseCategoryEntity.from(category)
    }
}
#endif

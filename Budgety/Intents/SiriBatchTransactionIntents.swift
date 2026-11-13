#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, macOS 27.3, *)
#if !os(watchOS)
@AppIntent(.tool)
#endif
struct SiriBatchAddTransactionsIntent: AppIntent {
    static let title: LocalizedStringResource = "複数の明細を追加"
    static let description = IntentDescription("複数の支出や収入を1度に追加します。各明細を「支出 ランチ 1,200円」「収入 給与 100 USD」のように別々の行で指定してください。全件を確認してから保存します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート") var sheet: ExpenseSheetEntity
    @Parameter(title: "明細", description: "名前と金額を1件ずつ指定します。例：ランチ 850円、電車 300円。各行の冒頭に「収入」を付けると収入になります。")
    var lines: [String]
    @Parameter(title: "種別", description: "行ごとの種別を指定しないときに使用します。省略すると支出です。")
    var kind: TransactionKind?
    @Parameter(title: "日付") var date: Date?
    @Parameter(title: "通貨", description: "行に通貨がない場合に使用します。省略するとシートの既定通貨です。", optionsProvider: SiriCurrencyOptions())
    var currencyCode: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let entries = try Self.parse(lines: lines, defaultKind: kind ?? .expense, currency: currencyCode, date: date ?? .now)
        let prepared = try SiriBatchTransactionStore.prepareAdd(sheetID: sheet.id, entries: entries)
        try await requestConfirmation(actionName: .add, dialog: IntentDialog("次の\(prepared.count)件を追加しますか？\n\(prepared.summary)"))
        let count = try SiriBatchTransactionStore.commit(prepared).count
        return .result(dialog: "\(count)件の明細を追加しました。")
    }

    static func parse(lines: [String], defaultKind: TransactionKind, currency: String?, date: Date) throws -> [SiriBatchTransactionStore.Entry] {
        // Anchor the full line. Decimal(string:) alone also accepts partial numbers.
        let pattern = #"^(?:(支出|収入|expense|income)\s+)?(.+?)\s+((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)\s*([^0-9０-９,.\s].*?)?$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let rows = lines.flatMap { $0.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "、;；"))) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return try rows.map { line in
            var value = line
            // Normalize the numeric suffix for full-width dictation without rewriting the name.
            if let boundary = line.range(of: #"\s+[０-９0-9]"#, options: .regularExpression, range: nil, locale: nil) {
                value = String(line[..<boundary.lowerBound]) + line[boundary.lowerBound...].precomposedStringWithCompatibilityMapping
            }
            guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
                throw SiriBatchTransactionStore.BatchError.invalidRow
            }
            func capture(_ index: Int) -> String? {
                Range(match.range(at: index), in: value).map { String(value[$0]) }
            }
            guard let name = capture(2), let numeric = capture(3),
                  let amount = Decimal(string: numeric.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
            else { throw SiriBatchTransactionStore.BatchError.invalidRow }
            let rowKind: TransactionKind
            switch capture(1)?.lowercased() {
            case "収入", "income": rowKind = .income
            case "支出", "expense": rowKind = .expense
            default: rowKind = defaultKind
            }
            return SiriBatchTransactionStore.Entry(title: name, amount: amount, kind: rowKind,
                                                   currencyCode: capture(4) ?? currency, date: date)
        }
    }
}

@available(iOS 27.3, macOS 27.3, *)
#if !os(watchOS)
@AppIntent(.tool)
#endif
struct SiriBatchEditTransactionsIntent: AppIntent {
    static let title: LocalizedStringResource = "複数の明細を編集"
    static let description = IntentDescription("選んだ支出・収入の名前、金額、通貨、日付またはカテゴリをまとめて変更します。選んだ各明細に同じ変更を適用し、保存前にすべての差分を確認します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート") var sheet: ExpenseSheetEntity
    @Parameter(title: "変更する明細", optionsProvider: SiriBatchEditableQuery())
    var transactions: [SiriEditableTransactionEntity]
    @Parameter(title: "変更する項目") var editField: SiriBatchEditField?
    @Parameter(title: "新しい名前") var newTitle: String?
    @Parameter(title: "新しい金額") var newAmount: Double?
    @Parameter(title: "変更後の通貨", optionsProvider: SiriCurrencyOptions()) var currencyCode: String?
    @Parameter(title: "新しい日付") var newDate: Date?
    @Parameter(title: "変更後のカテゴリ", optionsProvider: SiriBatchCategoryQuery()) var category: ExpenseCategoryEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) の \(\.$transactions) をまとめて編集") {
            \.$editField
            \.$newTitle
            \.$newAmount
            \.$currencyCode
            \.$newDate
            \.$category
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if newTitle == nil, newAmount == nil, currencyCode == nil, newDate == nil, category == nil {
            guard let editField else { throw $editField.needsValueError("どの項目を変更しますか？") }
            switch editField {
            case .name: throw $newTitle.needsValueError("新しい名前は何ですか？")
            case .amount: throw $newAmount.needsValueError("金額をいくらにしますか？")
            case .currency: throw $currencyCode.needsValueError("どの通貨にしますか？")
            case .date: throw $newDate.needsValueError("日付をいつにしますか？")
            case .category: throw $category.needsValueError("どのカテゴリにしますか？")
            }
        }
        let prepared = try Self.prepare(sheetID: sheet.id, transactions: transactions, title: newTitle, amount: newAmount,
                                        currencyCode: currencyCode, date: newDate, category: category)
        try await requestConfirmation(actionName: Self.confirmationAction,
                                      dialog: IntentDialog("次の\(prepared.count)件を変更しますか？\n\(prepared.summary)"))
        let count = try SiriBatchTransactionStore.commit(prepared).count
        return .result(dialog: "\(count)件の明細を変更しました。")
    }

    static var confirmationAction: ConfirmationActionName {
        .custom(acceptLabel: "アップデート", acceptAlternatives: ["変更を保存"], denyLabel: "キャンセル", denyAlternatives: [], destructive: true)
    }

    @MainActor
    static func prepare(sheetID: String, transactions: [SiriEditableTransactionEntity], title: String?, amount inputAmount: Double?,
                        currencyCode: String?, date: Date?, category: ExpenseCategoryEntity?) throws -> SiriBatchTransactionStore.Prepared {
        let amount = try inputAmount.map { value in
            guard let amount = CurrencyCatalog.transactionAmount(value) else { throw AppIntentError.invalidAmount }
            return amount
        }
        let edits = transactions.map { SiriBatchTransactionStore.Edit(identifier: $0.id, title: title, amount: amount,
                                                                        currencyCode: currencyCode, date: date, categoryID: category?.id) }
        return try SiriBatchTransactionStore.prepareEdit(sheetID: sheetID, edits: edits)
    }

}

enum SiriBatchEditField: String, AppEnum {
    case name, amount, currency, date, category

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "変更する項目"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .name: "名前", .amount: "金額", .currency: "通貨", .date: "日付", .category: "カテゴリ"
    ]
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriBatchEditableQuery: EntityStringQuery {
    @IntentParameterDependency<SiriBatchEditTransactionsIntent>(\.$sheet) var edit

    @MainActor func suggestedEntities() async throws -> [SiriEditableTransactionEntity] { try candidates("") }
    @MainActor func entities(matching string: String) async throws -> [SiriEditableTransactionEntity] { try candidates(string) }
    @MainActor func entities(for identifiers: [String]) async throws -> [SiriEditableTransactionEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriEditableTransactionQuery.resolve(identifiers, in: edit?.sheet.id, access: access)
    }
    @MainActor private func candidates(_ term: String) throws -> [SiriEditableTransactionEntity] {
        guard let selected = edit?.sheet else { return [] }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        return try SiriEditableTransactionQuery.candidates(in: access.resolve(selected.id), matching: term, access: access)
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriBatchCategoryQuery: EntityStringQuery {
    @IntentParameterDependency<SiriBatchEditTransactionsIntent>(\.$sheet) var editSheet
    @IntentParameterDependency<SiriBatchEditTransactionsIntent>(\.$transactions) var editRows

    @MainActor func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        try Self.options(sheet: editSheet?.sheet, transactions: editRows?.transactions ?? [])
    }
    @MainActor static func options(sheet selected: ExpenseSheetEntity?, transactions targets: [SiriEditableTransactionEntity]) throws -> [ExpenseCategoryEntity] {
        guard let selected, !targets.isEmpty else { return [] }
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try access.resolve(selected.id)
        let transactions = try targets.map { try access.transactionForDisplay(identifier: $0.id) }
        guard transactions.allSatisfy({ $0.sheet?.objectID == sheet.objectID }) else { return [] }
        let kinds = Set(transactions.map(\.kind))
        let clear = ExpenseCategoryEntity.skipEntity()
        guard kinds.count == 1, let kind = kinds.first else { return [clear] }
        let categories = ((sheet.categories as? Set<ExpenseCategory>) ?? []).filter { $0.kind == kind }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
        return [clear] + categories.map(ExpenseCategoryEntity.from)
    }
    @MainActor func entities(for identifiers: [String]) async throws -> [ExpenseCategoryEntity] {
        let options = try await suggestedEntities()
        return identifiers.compactMap { id in options.first { $0.id == id } }
    }
    @MainActor func entities(matching string: String) async throws -> [ExpenseCategoryEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}
#endif

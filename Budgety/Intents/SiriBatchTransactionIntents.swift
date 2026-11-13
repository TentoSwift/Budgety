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
    static let description = IntentDescription("複数の支出や収入を1度に追加します。1件だけなら「シートに支出を記録」または「収入を追加」を使います。名前は省略できます。各明細を「支出 ランチ 1,200円」「収入 給与 100 USD」のように別々の行で指定してください。全件に共通の支払者・受取者を選べます。支出だけを追加するときは割り勘も指定できます。保存前に全件を確認します。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート") var sheet: ExpenseSheetEntity
    @Parameter(title: "明細", description: "金額を1件ずつ指定します。名前は任意です。「10ドルの出費を追加して」や「10 USD」も指定できます。例：ランチ 850円、電車 300円。各行の冒頭に「収入」を付けると収入になります。")
    var lines: [String]
    @Parameter(title: "種別", description: "行ごとの種別を指定しないときに使用します。省略すると支出です。")
    var kind: TransactionKind?
    @Parameter(title: "日付") var date: Date?
    @Parameter(title: "通貨", description: "行に通貨がない場合に使用します。省略するとシートの既定通貨です。", optionsProvider: SiriCurrencyOptions())
    var currencyCode: String?
    @Parameter(title: "支払者・受取者", description: "すべての明細で支払った人、または収入を受け取った人。", optionsProvider: SiriBatchMemberQuery())
    var payer: SiriSheetMemberEntity?
    @Parameter(title: "全員で割り勘", description: "すべての支出をシートの全メンバーで均等に負担します。")
    var splitAll: Bool?
    @Parameter(title: "割り勘の対象", description: "すべての支出を均等に負担するメンバー。支払者も負担するときは含めてください。", optionsProvider: SiriBatchMemberQuery())
    var beneficiaries: [SiriSheetMemberEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) に \(\.$lines) をまとめて追加") {
            \.$kind
            \.$date
            \.$currencyCode
            \.$payer
            \.$splitAll
            \.$beneficiaries
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let prepared = try Self.prepare(sheetID: sheet.id, lines: lines, defaultKind: kind ?? .expense,
                                        currency: currencyCode, date: date ?? .now, payer: payer,
                                        splitAll: splitAll ?? false, beneficiaries: beneficiaries ?? [])
        try await requestConfirmation(actionName: .add, dialog: IntentDialog("次の\(prepared.count)件を追加しますか？\n\(prepared.summary)"))
        let count = try SiriBatchTransactionStore.commit(prepared).count
        return .result(dialog: "\(count)件の明細を追加しました。")
    }

    @MainActor
    static func prepare(sheetID: String, lines: [String], defaultKind: TransactionKind, currency: String?, date: Date,
                        payer: SiriSheetMemberEntity? = nil, splitAll: Bool = false,
                        beneficiaries: [SiriSheetMemberEntity] = []) throws -> SiriBatchTransactionStore.Prepared {
        let entries = try parse(lines: lines, defaultKind: defaultKind, currency: currency, date: date)
        return try SiriBatchTransactionStore.prepareAdd(sheetID: sheetID, entries: entries, payer: payer,
                                                       splitAll: splitAll, beneficiaries: beneficiaries)
    }

    static func parse(lines: [String], defaultKind: TransactionKind, currency: String?, date: Date) throws -> [SiriBatchTransactionStore.Entry] {
        // Anchor the full line. Decimal(string:) alone also accepts partial numbers.
        let pattern = #"^(?:(支出|収入|expense|income)\s+)?(.+?)\s+((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)\s*([^0-9０-９,.\s].*?)?$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let rows = lines.flatMap { $0.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "、;；"))) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return try rows.map { line in
            if let entry = try unnamedEntry(line, defaultKind: defaultKind, currency: currency, date: date) { return entry }
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

    // Siri can route a single amount-only request to the batch tool. Accept only a
    // complete amount expression here; malformed named rows must still fail above.
    private static func unnamedEntry(_ line: String, defaultKind: TransactionKind, currency: String?, date: Date) throws -> SiriBatchTransactionStore.Entry? {
        var text = line.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"(?:を?(?:追加して|記録して|追加|記録)(?:ください)?)$"#, with: "", options: .regularExpression)
        var rowKind = defaultKind
        if let suffix = text.range(of: #"の(出費|支出|収入)$"#, options: .regularExpression) {
            rowKind = text[suffix].contains("収入") ? .income : .expense
            text.removeSubrange(suffix)
        }
        if let prefix = text.range(of: #"^(支出|出費|収入|expense|income)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let kind = text[prefix].trimmingCharacters(in: .whitespaces).lowercased()
            rowKind = ["収入", "income"].contains(kind) ? .income : .expense
            text.removeSubrange(prefix)
        }
        var prefixCurrency: String?
        if let prefix = text.range(of: #"^(?:[A-Za-z]{3}|[$€¥])\s*(?=[0-9])"#, options: .regularExpression) {
            let token = text[prefix].trimmingCharacters(in: .whitespaces)
            if token == "$" || token == "¥" {
                // A symbol alone can represent more than one currency. Honor Siri's explicit currency.
                if let code = currency.flatMap(CurrencyCatalog.transactionCurrencyCode(for:)),
                   CurrencyCatalog.option(for: code).symbol.hasSuffix(token) {
                    prefixCurrency = code
                } else {
                    prefixCurrency = token == "$" ? "USD" : "JPY"
                }
            } else {
                prefixCurrency = CurrencyCatalog.transactionCurrencyCode(for: token)
            }
            guard prefixCurrency != nil else { return nil }
            text.removeSubrange(prefix)
        }
        let pattern = #"^((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)\s*([^0-9,.\s].*?)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let amount = Decimal(string: String(text[numberRange]).replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let code: String?
        if let currencyRange = Range(match.range(at: 2), in: text) {
            let token = String(text[currencyRange])
            let explicit = ["dollar", "dollars"].contains(token.lowercased()) ? "USD" : CurrencyCatalog.transactionCurrencyCode(for: token)
            guard let explicit else { return nil }
            guard prefixCurrency == nil || prefixCurrency == explicit else { throw AppIntentError.unsupportedCurrency }
            code = explicit
        } else { code = prefixCurrency ?? currency }
        return SiriBatchTransactionStore.Entry(title: "", amount: amount, kind: rowKind, currencyCode: code, date: date)
    }
}

@available(iOS 27.3, macOS 27.3, *)
#if !os(watchOS)
@AppIntent(.tool)
#endif
struct SiriBatchEditTransactionsIntent: AppIntent {
    static let title: LocalizedStringResource = "複数の明細を編集"
    static let description = IntentDescription("選んだ支出・収入の名前、金額、通貨、日付、カテゴリ、支払者・受取者をまとめて変更します。支出の割り勘の設定・解除もできます。選んだ各明細に同じ変更を適用し、保存前にすべての差分を確認します。")
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
    @Parameter(title: "支払者・受取者", description: "選んだ全明細の新しい支払者または受取者。省略すると元の人を維持します。", optionsProvider: SiriBatchMemberQuery())
    var payer: SiriSheetMemberEntity?
    @Parameter(title: "割り勘", description: "選んだ支出の割り勘を解除するか、全員または指定のメンバーで均等に負担します。")
    var split: SiriTransactionSplitChange?
    @Parameter(title: "割り勘の対象", description: "選んだ支出を均等に負担するメンバー。支払者も負担するときは含めてください。", optionsProvider: SiriBatchMemberQuery())
    var beneficiaries: [SiriSheetMemberEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$sheet) の \(\.$transactions) をまとめて編集") {
            \.$editField
            \.$newTitle
            \.$newAmount
            \.$currencyCode
            \.$newDate
            \.$category
            \.$payer
            \.$split
            \.$beneficiaries
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let members = beneficiaries ?? []
        if newTitle == nil, newAmount == nil, currencyCode == nil, newDate == nil, category == nil,
           payer == nil, split == nil, members.isEmpty {
            guard let editField else { throw $editField.needsValueError("どの項目を変更しますか？") }
            switch editField {
            case .name: throw $newTitle.needsValueError("新しい名前は何ですか？")
            case .amount: throw $newAmount.needsValueError("金額をいくらにしますか？")
            case .currency: throw $currencyCode.needsValueError("どの通貨にしますか？")
            case .date: throw $newDate.needsValueError("日付をいつにしますか？")
            case .category: throw $category.needsValueError("どのカテゴリにしますか？")
            case .payer: throw $payer.needsValueError("どのメンバーに変更しますか？")
            case .split: throw $split.needsDisambiguationError(among: [.off, .all, .selected], dialog: "割り勘をどう変更しますか？")
            }
        }
        if split == .selected, members.isEmpty {
            throw $beneficiaries.needsValueError("割り勘の対象にするメンバーを選んでください。")
        }
        let prepared = try Self.prepare(sheetID: sheet.id, transactions: transactions, title: newTitle, amount: newAmount,
                                        currencyCode: currencyCode, date: newDate, category: category,
                                        payer: payer, split: split, beneficiaries: members)
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
                        currencyCode: String?, date: Date?, category: ExpenseCategoryEntity?, payer: SiriSheetMemberEntity? = nil,
                        split: SiriTransactionSplitChange? = nil, beneficiaries: [SiriSheetMemberEntity] = []) throws -> SiriBatchTransactionStore.Prepared {
        let amount = try inputAmount.map { value in
            guard let amount = CurrencyCatalog.transactionAmount(value) else { throw AppIntentError.invalidAmount }
            return amount
        }
        let splitChange = split ?? (beneficiaries.isEmpty ? .unchanged : .selected)
        let edits = transactions.map {
            SiriBatchTransactionStore.Edit(identifier: $0.id, title: title, amount: amount,
                                          currencyCode: currencyCode, date: date, categoryID: category?.id,
                                          payer: payer, split: splitChange, beneficiaries: beneficiaries)
        }
        return try SiriBatchTransactionStore.prepareEdit(sheetID: sheetID, edits: edits)
    }

}

enum SiriBatchEditField: String, AppEnum {
    case name, amount, currency, date, category, payer, split

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "変更する項目"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .name: "名前", .amount: "金額", .currency: "通貨", .date: "日付", .category: "カテゴリ",
        .payer: "支払者・受取者", .split: "割り勘"
    ]
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriBatchMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity

    @IntentParameterDependency<SiriBatchAddTransactionsIntent>(\.$sheet) var add
    @IntentParameterDependency<SiriBatchEditTransactionsIntent>(\.$sheet) var edit

    func selectedSheetID(access: IntentSheetAccess) throws -> String? { add?.sheet.id ?? edit?.sheet.id }
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

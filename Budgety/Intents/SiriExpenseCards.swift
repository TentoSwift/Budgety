#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS) || os(macOS)
@available(iOS 27.3, macOS 27.3, *)
@MainActor
enum SiriTransactionCategoryIcon {
    private static let images: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 96
        return cache
    }()

    static func file(symbol: String, colorHex: String) -> IntentFile? {
        let glyph = symbol.isEmpty ? "tag.slash" : symbol
        let color = colorHex.isEmpty ? "#8E8E93" : colorHex
        let key = (glyph + "|" + color) as NSString
        let data: Data
        if let cached = images.object(forKey: key) { data = cached as Data }
        else {
            guard let rendered = ExpenseCategoryEntity.renderColoredSymbol(glyph, colorHex: color)
                    ?? ExpenseCategoryEntity.renderColoredSymbol("tag.slash", colorHex: color) else { return nil }
            images.setObject(rendered as NSData, forKey: key)
            data = rendered
        }
        return IntentFile(data: data, filename: "category.png", type: .png)
    }

    nonisolated static func image(_ file: IntentFile?, symbol: String) -> DisplayRepresentation.Image {
        if let data = file?.data { return .init(data: data, isTemplate: false, displayStyle: .circular) }
        return .init(systemName: symbol.isEmpty ? "tag.slash" : symbol)
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriListedTransactionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "明細"
    static let defaultQuery = SiriListedTransactionQuery()
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    let id: String
    @Property(title: "名前") var title: String
    @Property(title: "日付") var date: String
    @Property(title: "金額") var amount: String
    @Property(title: "カテゴリ") var category: String
    @Property(title: "支払者・受取者") var payerName: String?
    @Property(title: "取引の種類") var kind: TransactionKind
    @Property(title: "編集対象") var editableTransaction: SiriEditableTransactionEntity?
    @Property(title: "カテゴリのシンボル", visibility: .internal) var categorySymbol: String
    @Property(title: "カテゴリの色", visibility: .internal) var categoryColorHex: String
    @Property(title: "カテゴリの画像", visibility: .internal) var categoryIcon: IntentFile?

    @MainActor
    init(row: SiriExpenseCardRow) throws {
        try self.init(row: row, originalID: nil)
    }

    @MainActor
    fileprivate init(row: SiriExpenseCardRow, originalID: String?) throws {
        guard let identifier = originalID ?? row.expenseIdentifier else { throw AppIntentError.expenseUnavailable }
        id = identifier
        title = row.title
        date = row.date
        amount = row.signedAmount ?? row.amount
        if let currency = row.foreignCurrencyCode { amount += " " + currency }
        category = row.category
        payerName = row.payerName
        kind = row.transactionKind
        editableTransaction = row.editableTransaction
        categorySymbol = row.categorySymbol
        categoryColorHex = row.categoryColorHex
        categoryIcon = SiriTransactionCategoryIcon.file(symbol: row.categorySymbol, colorHex: row.categoryColorHex)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(date) · \(amount)",
                              image: SiriTransactionCategoryIcon.image(categoryIcon, symbol: categorySymbol))
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriListedTransactionQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriListedTransactionEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let backing = VirtualRowBacking()
        return try identifiers.compactMap { id in
            guard let target = try? SiriVirtualExpenseLink.resolve(id, access: access) else { return nil }
            let expense: Expense
            let sheet: ExpenseSheet
            switch target {
            case .stored(let stored):
                guard let owner = stored.sheet else { return nil }
                sheet = owner
                expense = stored
            case .virtual(let occurrence, let owner, _):
                sheet = owner
                expense = backing.displayExpense(for: occurrence, sheet: owner)
            }
            let row = SiriExpenseCardRow.from(expense, in: sheet, isSoloSheet: !sheet.hasAcceptedOtherMembers(),
                                              virtualIdentifier: expense.objectID.isTemporaryID ? id : nil, includePayerPhoto: false)
            return try SiriListedTransactionEntity(row: row, originalID: id)
        }
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriOpenListedTransactionIntent: OpenIntent {
    static let title: LocalizedStringResource = "指定した明細を開く"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "明細") var target: SiriListedTransactionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await SiriOpenExpenseIntent(expenseIdentifier: target.id).perform()
        return .result()
    }
}
#endif

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseCardRow: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "明細"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    var transactionKind: TransactionKind = .expense
    @Property(title: "編集対象") var editableTransaction: SiriEditableTransactionEntity?
    @Property(title: "名前") var title: String
    @Property(title: "日付") var date: String
    @Property(title: "カテゴリ") var category: String
    @Property(title: "金額") var amount: String
    @Property(title: "支払者・受取者") var payerName: String?
    @Property(title: "外貨の通貨コード") var foreignCurrencyCode: String?

    // Watch snippets reload these presentation fields from the store when invoked.
    #if os(watchOS)
    var expenseIdentifier: String?
    var categoryColorHex = ""
    var categorySymbol = ""
    var signedAmount: String?
    var payerIsVirtual: Bool?
    var payerColorHex: String?
    var payerPhoto: IntentFile?
    #else
    @Property(title: "明細の識別子", visibility: .internal) var expenseIdentifier: String?
    @Property(title: "カテゴリの色", visibility: .internal) var categoryColorHex: String
    @Property(title: "カテゴリのアイコン", visibility: .internal) var categorySymbol: String
    @Property(title: "表示用金額", visibility: .internal) var signedAmount: String?
    @Property(title: "バーチャルメンバー", visibility: .internal) var payerIsVirtual: Bool?
    @Property(title: "支払者の色", visibility: .internal) var payerColorHex: String?
    @Property(title: "支払者のアイコン", visibility: .internal) var payerPhoto: IntentFile?
    #endif

    init() {}

    init(title: String, date: String, category: String, amount: String, kind: TransactionKind = .expense,
         categoryColorHex: String = "", categorySymbol: String = "tag",
         signedAmount: String? = nil, payerName: String? = nil,
         payerColorHex: String = "", payerPhoto: IntentFile? = nil,
         payerIsVirtual: Bool? = nil, foreignCurrencyCode: String? = nil, expenseIdentifier: String? = nil,
         editableTransaction: SiriEditableTransactionEntity? = nil) {
        self.transactionKind = kind
        self.expenseIdentifier = expenseIdentifier
        self.editableTransaction = editableTransaction
        self.title = title
        self.date = date
        self.category = category
        self.amount = amount
        self.categoryColorHex = categoryColorHex
        self.categorySymbol = categorySymbol
        self.signedAmount = signedAmount
        self.payerName = payerName
        self.payerIsVirtual = payerIsVirtual
        self.payerColorHex = payerColorHex
        self.payerPhoto = payerPhoto
        self.foreignCurrencyCode = foreignCurrencyCode
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(date) · \(amount)")
    }

    @MainActor
    static func from(_ transaction: Expense, in sheet: ExpenseSheet, isSoloSheet: Bool,
                     virtualIdentifier: String? = nil, includePayerPhoto: Bool = true) -> Self {
        let currency = transaction.resolvedCurrencyCode.uppercased()
        let category = transaction.categoryDisplayName
        let payer = SiriExpensePayer.snapshot(for: transaction, isSoloSheet: isSoloSheet, includePhoto: includePayerPhoto)
        return Self(
            title: transaction.displayTitle.isEmpty ? category : transaction.displayTitle,
            date: transaction.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "日付不明"),
            category: category,
            amount: transaction.amountDecimal.formatted(.currency(code: currency).presentation(.isoCode)), kind: transaction.kind,
            categoryColorHex: transaction.resolvedCategory?.displayColorHex ?? "",
            categorySymbol: transaction.categorySymbol,
            signedAmount: transaction.formattedSignedAmount,
            payerName: payer?.name, payerColorHex: payer?.colorHex ?? "", payerPhoto: payer?.photo,
            payerIsVirtual: UserProfileStore.isVirtualRecordName(transaction.payerProfileID ?? ""),
            foreignCurrencyCode: currency == sheet.resolvedDefaultCurrencyCode ? nil : currency,
            expenseIdentifier: virtualIdentifier ?? transaction.objectID.uriRepresentation().absoluteString,
            editableTransaction: virtualIdentifier == nil ? SiriEditableTransactionEntity.from(transaction) : nil
        )
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseCardResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "明細の検索結果"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "シート名") var sheetName: String
    @Property(title: "対象期間") var period: String
    @Property(title: "検索した明細名") var expenseName: String
    @Property(title: "該当件数") var count: Int
    @Property(title: "通貨別の合計") var total: String
    @Property(title: "収入") var incomeTotal: String?
    @Property(title: "支出") var expenseTotal: String?
    @Property(title: "新しい順の明細") var rows: [SiriExpenseCardRow]

    #if os(watchOS)
    var sheetSymbol: String?
    var sheetColorHex: String?
    #else
    @Property(title: "シートのアイコン", visibility: .internal) var sheetSymbol: String?
    @Property(title: "シートの色", visibility: .internal) var sheetColorHex: String?
    #endif

    init() {}

    init(sheetName: String, period: String, expenseName: String, count: Int, total: String,
         rows: [SiriExpenseCardRow], sheetSymbol: String? = nil, sheetColorHex: String? = nil) {
        self.sheetName = sheetName
        self.sheetSymbol = sheetSymbol
        self.sheetColorHex = sheetColorHex
        self.period = period
        self.expenseName = expenseName
        self.count = count
        self.total = total
        self.rows = Array(rows.prefix(5))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sheetName)", subtitle: "\(period)")
    }

}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriMemberCardResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "メンバーの収支"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "メンバー") var memberName: String
    @Property(title: "シート名") var sheetName: String
    @Property(title: "対象期間") var period: String
    @Property(title: "支出") var expenseTotal: String?
    @Property(title: "収入") var incomeTotal: String?
    @Property(title: "収支") var netTotal: String?
    @Property(title: "該当件数") var count: Int
    @Property(title: "新しい順の明細") var rows: [SiriExpenseCardRow]

    #if os(watchOS)
    var memberColorHex = ""
    var memberPhoto: IntentFile?
    var memberIsVirtual = false
    var sheetSymbol: String?
    var sheetColorHex: String?
    #else
    @Property(title: "メンバーの色", visibility: .internal) var memberColorHex: String
    @Property(title: "メンバーの写真", visibility: .internal) var memberPhoto: IntentFile?
    @Property(title: "バーチャルメンバー", visibility: .internal) var memberIsVirtual: Bool
    @Property(title: "シートのアイコン", visibility: .internal) var sheetSymbol: String?
    @Property(title: "シートの色", visibility: .internal) var sheetColorHex: String?
    #endif

    init() {}

    init(memberName: String, memberColorHex: String, memberPhoto: IntentFile?, memberIsVirtual: Bool,
         sheetName: String, sheetSymbol: String?, sheetColorHex: String?, period: String,
         expenseTotal: String?, incomeTotal: String?, count: Int, rows: [SiriExpenseCardRow]) {
        self.memberName = memberName
        self.memberColorHex = memberColorHex
        self.memberPhoto = memberPhoto
        self.memberIsVirtual = memberIsVirtual
        self.sheetName = sheetName
        self.sheetSymbol = sheetSymbol
        self.sheetColorHex = sheetColorHex
        self.period = period
        self.expenseTotal = expenseTotal
        self.incomeTotal = incomeTotal
        self.count = count
        self.rows = Array(rows.prefix(5))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(memberName)", subtitle: "\(sheetName) · \(period)")
    }

}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriRecordedTransaction: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "登録した明細"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "シート名") var sheetName: String
    @Property(title: "明細") var row: SiriExpenseCardRow
    @Property(title: "取引の種類") var kindName: String
    @Property(title: "割り勘の対象") var splitMemberNames: [String]?
    @ComputedProperty(title: "編集対象") var editableTransaction: SiriEditableTransactionEntity? { row.editableTransaction }

    #if os(watchOS)
    var sheetSymbol: String?
    var sheetColorHex: String?
    #else
    @Property(title: "シートのアイコン", visibility: .internal) var sheetSymbol: String?
    @Property(title: "シートの色", visibility: .internal) var sheetColorHex: String?
    #endif

    init() {}

    init(sheetName: String, row: SiriExpenseCardRow, kindName: String,
         sheetSymbol: String? = nil, sheetColorHex: String? = nil, splitMemberNames: [String]? = nil) {
        self.sheetName = sheetName
        self.sheetSymbol = sheetSymbol
        self.sheetColorHex = sheetColorHex
        self.row = row
        self.kindName = kindName
        self.splitMemberNames = splitMemberNames
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(row.title)", subtitle: "\(sheetName) · \(row.signedAmount ?? row.amount)")
    }

}

#if os(iOS) || os(macOS)
@available(iOS 27.3, macOS 27.3, *)
extension SiriExpenseCardResult: SnippetRepresentableEntity {
    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { result, _ in
            SiriExpenseCardView(result: result)
        }
    }
}

@available(iOS 27.3, macOS 27.3, *)
extension SiriMemberCardResult: SnippetRepresentableEntity {
    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { result, _ in
            SiriExpenseCardView(member: result)
        }
    }
}

@available(iOS 27.3, macOS 27.3, *)
extension SiriRecordedTransaction: SnippetRepresentableEntity {
    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { recorded, _ in
            SiriExpenseCardView(recorded: recorded)
        }
    }
}
#endif

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpenseCardView: View {
    private enum Content {
        case search(SiriExpenseCardResult)
        case recorded(SiriRecordedTransaction)
        case member(SiriMemberCardResult)
    }
    private let content: Content
    private var allowsOpening = true

    init(result: SiriExpenseCardResult) { content = .search(result) }
    init(member: SiriMemberCardResult) { content = .member(member) }
    init(recorded: SiriRecordedTransaction, allowsOpening: Bool = true) {
        content = .recorded(recorded)
        self.allowsOpening = allowsOpening
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(\.colorScheme) private var colorScheme

    // Siri can composite the snippet over any app. Resolve the text and its opaque
    // surface together so their contrast survives a different host appearance.
    private var surface: Color { Color(white: colorScheme == .dark ? 0.10 : 0.98) }
    private var primaryInk: Color { Color(white: colorScheme == .dark ? 1 : 0.08) }
    private var secondaryInk: Color { Color(white: colorScheme == .dark ? 0.82 : 0.30) }

    var body: some View {
        if allowsOpening, let onlyExpenseIdentifier {
            openButton(identifier: onlyExpenseIdentifier) { card }
                .accessibilityIdentifier("siriExpenseRow_0")
        } else {
            card
        }
    }

    private var onlyExpenseIdentifier: String? {
        switch content {
        case .recorded(let recorded):
            recorded.row.expenseIdentifier
        case .search(let result):
            result.count == 1 && result.rows.count == 1 ? result.rows.first?.expenseIdentifier : nil
        case .member:
            nil
        }
    }

    private var card: some View {
        #if os(watchOS)
        let spacing: CGFloat = 4
        let padding: CGFloat = 8
        #else
        let spacing: CGFloat = 8
        let padding: CGFloat = 12
        #endif
        return VStack(alignment: .leading, spacing: spacing) {
            switch content {
            case .recorded(let recorded):
                sheetHeader(name: recorded.sheetName, detail: recorded.row.date,
                           symbol: recorded.sheetSymbol, colorHex: recorded.sheetColorHex)
                row(recorded.row)
                if let names = recorded.splitMemberNames, !names.isEmpty {
                    Text("割り勘　\(names.formatted(.list(type: .and)))")
                        .font(.caption)
                        .foregroundStyle(secondaryInk)
                }
            case .search(let result):
                searchContent(result)
            case .member(let member):
                memberContent(member)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .foregroundStyle(primaryInk)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .privacySensitive()
    }

    @ViewBuilder
    private func searchContent(_ result: SiriExpenseCardResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            #if !os(watchOS)
            if !result.expenseName.isEmpty {
                Text(verbatim: result.expenseName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            #endif
            sheetHeader(name: result.sheetName, detail: result.period,
                       symbol: result.sheetSymbol, colorHex: result.sheetColorHex)
        }

        if result.rows.isEmpty {
            Text("該当する明細はありません")
                .font(.body)
        } else {
            Text(verbatim: result.total)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let income = result.incomeTotal, let expense = result.expenseTotal {
                Text("収入 \(income) ／ 支出 \(expense)").font(.caption).foregroundStyle(secondaryInk)
            }
            fittingRows(result.rows, count: result.count, period: result.period)
        }
    }

    @ViewBuilder
    private func memberContent(_ result: SiriMemberCardResult) -> some View {
        #if os(watchOS)
        HStack(spacing: 6) {
            AvatarView(photoData: result.memberPhoto?.data, displayName: result.memberName,
                       colorHex: result.memberColorHex, size: 26, isVirtual: result.memberIsVirtual)
                .accessibilityHidden(true)
            Text(verbatim: result.memberName)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        sheetHeader(name: result.sheetName, detail: result.period,
                    symbol: result.sheetSymbol, colorHex: result.sheetColorHex)
        if result.count == 0 {
            Text("該当する明細はありません").font(.caption)
        } else {
            if let net = result.netTotal { Text("収支 \(net)").font(.caption.bold()) }
            if let expense = result.expenseTotal { Text("支出 \(expense)").font(.caption.bold()) }
            if let income = result.incomeTotal { Text("収入 \(income)").font(.caption.bold()) }
            fittingRows(result.rows, count: result.count, period: result.period)
        }
        #else
        ViewThatFits(in: .vertical) {
            ForEach((0...result.rows.count).reversed(), id: \.self) { visibleCount in
                VStack(alignment: .leading, spacing: 8) {
                    memberHeader(result)
                    Divider()
                    if result.count == 0 {
                        Text("該当する明細はありません")
                            .font(.subheadline)
                            .foregroundStyle(secondaryInk)
                    } else {
                        list(result.rows, count: result.count, limit: visibleCount)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif
    }

    @ViewBuilder
    private func memberHeader(_ result: SiriMemberCardResult) -> some View {
        VStack(spacing: 10) {
            AvatarView(photoData: result.memberPhoto?.data, displayName: result.memberName,
                       colorHex: result.memberColorHex, size: 72, isVirtual: result.memberIsVirtual)
                .accessibilityHidden(true)
            Text(verbatim: result.memberName)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            sheetHeader(name: result.sheetName, detail: result.period,
                        symbol: result.sheetSymbol, colorHex: result.sheetColorHex)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { memberTotals(result) }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { memberTotals(result) }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func memberTotals(_ result: SiriMemberCardResult) -> some View {
        if let value = result.netTotal { memberAmount("収支", value: value) }
        if let value = result.expenseTotal { memberAmount("支出", value: value) }
        if let value = result.incomeTotal { memberAmount("収入", value: value) }
    }

    private func memberAmount(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryInk)
            Text(verbatim: value)
                .font(.headline.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func fittingRows(_ rows: [SiriExpenseCardRow], count: Int, period: String) -> some View {
        ViewThatFits(in: .vertical) {
            #if os(watchOS)
            list(rows, count: count, limit: min(2, rows.count), omittingDate: period)
            list(rows, count: count, limit: min(1, rows.count), omittingDate: period)
            #else
            ForEach((0...rows.count).reversed(), id: \.self) { visibleCount in
                list(rows, count: count, limit: visibleCount)
            }
            #endif
        }
    }

    private func sheetHeader(name: String, detail: String, symbol: String?, colorHex: String?) -> some View {
        #if os(watchOS)
        HStack(spacing: 4) {
            SheetSymbolIcon(symbol: symbol ?? "person.2.fill", tint: Color(hex: colorHex ?? "#5B8DEF") ?? .indigo,
                            size: 16)
                .accessibilityHidden(true)
            Text("\(name) · \(detail)").font(.caption2).foregroundStyle(secondaryInk)
        }
        .fixedSize(horizontal: false, vertical: true)
        #else
        HStack(spacing: 8) {
            SheetSymbolIcon(symbol: symbol ?? "person.2.fill",
                            tint: Color(hex: colorHex ?? "#5B8DEF") ?? .indigo, size: 24)
                .accessibilityHidden(true)
            Text("\(name) · \(detail)")
                .font(.subheadline)
                .foregroundStyle(secondaryInk)
        }
        #endif
    }

    private func list(_ rows: [SiriExpenseCardRow], count: Int, limit: Int, omittingDate: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<limit, id: \.self) { index in
                let item = rows[index]
                if item.date != omittingDate, index == 0 || rows[index - 1].date != item.date {
                    Text(verbatim: item.date)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryInk)
                        .accessibilityAddTraits(.isHeader)
                }
                if onlyExpenseIdentifier == nil, let identifier = item.expenseIdentifier {
                    openButton(identifier: identifier) { row(item) }
                        .accessibilityIdentifier("siriExpenseRow_\(index)")
                } else {
                    row(item)
                }
            }
            let hiddenCount = count - limit
            if hiddenCount > 0 {
                Text("+\(hiddenCount)件")
                    .font(.caption)
                    .foregroundStyle(secondaryInk)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openButton<Label: View>(identifier: String, @ViewBuilder label: () -> Label) -> some View {
        Button(intent: SiriOpenExpenseIntent(expenseIdentifier: identifier)) {
            label()
                .foregroundStyle(primaryInk)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Budgetyでこの明細の詳細を開きます")
    }

    private func row(_ item: SiriExpenseCardRow) -> some View {
        #if os(watchOS)
        return HStack(spacing: 6) {
            categoryIcon(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.category).font(.caption.weight(.semibold))
                if !item.title.isEmpty, item.title != item.category {
                    Text(verbatim: item.title).font(.caption2).foregroundStyle(secondaryInk)
                }
                if let payer = item.payerName, !payer.isEmpty {
                    Text(verbatim: payer).font(.caption2).foregroundStyle(secondaryInk)
                }
                let amount = item.signedAmount ?? item.amount
                Text(verbatim: item.foreignCurrencyCode.map { "\(amount) \($0)" } ?? amount)
                    .font(.caption.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .combine)
        #else
        let amount = VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: item.signedAmount ?? item.amount)
                .font(.subheadline.monospacedDigit())
            if let code = item.foreignCurrencyCode {
                Text(verbatim: code)
                    .font(.caption2)
                    .foregroundStyle(secondaryInk)
            }
        }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        categoryIcon(item)
                        Spacer(minLength: 12)
                        amount
                    }
                    labels(item)
                }
            } else {
                HStack(spacing: 12) {
                    categoryIcon(item)
                    labels(item)
                    Spacer(minLength: 0)
                    amount.fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        #endif
    }

    private func categoryIcon(_ item: SiriExpenseCardRow) -> some View {
        #if os(watchOS)
        let size: CGFloat = 26
        #else
        let size: CGFloat = 38
        #endif
        return ZStack(alignment: .bottomTrailing) {
            CategoryIconView(symbol: item.categorySymbol.isEmpty ? "tag.slash" : item.categorySymbol,
                             tint: Color(hex: item.categoryColorHex) ?? .gray, size: size)
            if let payerName = item.payerName {
                AvatarView(photoData: item.payerPhoto?.data, displayName: payerName,
                           colorHex: item.payerColorHex ?? "", size: size * 0.47, isVirtual: item.payerIsVirtual == true)
                    .background(Circle().fill(surface).padding(-2))
                    .offset(x: 5, y: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func labels(_ item: SiriExpenseCardRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.category)
                .font(.body)
            if !item.title.isEmpty, item.title != item.category {
                Text(verbatim: item.title)
                    .font(.caption)
                    .foregroundStyle(secondaryInk)
            }
            if let payerName = item.payerName, !payerName.isEmpty {
                Text(verbatim: payerName)
                    .font(.caption)
                    .foregroundStyle(secondaryInk)
            }
        }
    }
}
#endif

#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import SwiftUI

@available(iOS 27.3, *)
struct SiriExpenseCardRow: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "明細"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "明細の識別子", visibility: .internal) var expenseIdentifier: String?
    @Property(title: "編集対象") var editableTransaction: SiriEditableTransactionEntity?
    @Property(title: "名前") var title: String
    @Property(title: "日付") var date: String
    @Property(title: "カテゴリ") var category: String
    @Property(title: "金額") var amount: String
    @Property(title: "カテゴリの色", visibility: .internal) var categoryColorHex: String
    @Property(title: "カテゴリのアイコン", visibility: .internal) var categorySymbol: String
    @Property(title: "表示用金額", visibility: .internal) var signedAmount: String?
    @Property(title: "支払者・受取者") var payerName: String?
    @Property(title: "支払者の色", visibility: .internal) var payerColorHex: String?
    @Property(title: "支払者のアイコン", visibility: .internal) var payerPhoto: IntentFile?
    @Property(title: "外貨の通貨コード") var foreignCurrencyCode: String?

    init() {}

    init(title: String, date: String, category: String, amount: String,
         categoryColorHex: String = "", categorySymbol: String = "tag",
         signedAmount: String? = nil, payerName: String? = nil,
         payerColorHex: String = "", payerPhoto: IntentFile? = nil,
         foreignCurrencyCode: String? = nil, expenseIdentifier: String? = nil,
         editableTransaction: SiriEditableTransactionEntity? = nil) {
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
        self.payerColorHex = payerColorHex
        self.payerPhoto = payerPhoto
        self.foreignCurrencyCode = foreignCurrencyCode
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(date) · \(amount)")
    }

    @MainActor
    static func from(_ transaction: Expense, in sheet: ExpenseSheet, isSoloSheet: Bool,
                     virtualIdentifier: String? = nil) -> Self {
        let currency = transaction.resolvedCurrencyCode.uppercased()
        let category = transaction.categoryDisplayName
        let payer = SiriExpensePayer.snapshot(for: transaction, isSoloSheet: isSoloSheet)
        return Self(
            title: transaction.displayTitle.isEmpty ? category : transaction.displayTitle,
            date: transaction.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "日付不明"),
            category: category,
            amount: transaction.amountDecimal.formatted(.currency(code: currency).presentation(.isoCode)),
            categoryColorHex: transaction.resolvedCategory?.displayColorHex ?? "",
            categorySymbol: transaction.categorySymbol,
            signedAmount: transaction.formattedSignedAmount,
            payerName: payer?.name, payerColorHex: payer?.colorHex ?? "", payerPhoto: payer?.photo,
            foreignCurrencyCode: currency == sheet.resolvedDefaultCurrencyCode ? nil : currency,
            expenseIdentifier: virtualIdentifier ?? transaction.objectID.uriRepresentation().absoluteString,
            editableTransaction: virtualIdentifier == nil ? SiriEditableTransactionEntity.from(transaction) : nil
        )
    }
}

@available(iOS 27.3, *)
struct SiriExpenseCardResult: TransientAppEntity, SnippetRepresentableEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "支出の検索結果"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "シート名") var sheetName: String
    @Property(title: "シートのアイコン", visibility: .internal) var sheetSymbol: String?
    @Property(title: "シートの色", visibility: .internal) var sheetColorHex: String?
    @Property(title: "対象期間") var period: String
    @Property(title: "検索した支出名") var expenseName: String
    @Property(title: "該当件数") var count: Int
    @Property(title: "通貨別の合計") var total: String
    @Property(title: "新しい順の明細") var rows: [SiriExpenseCardRow]

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

    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { result, _ in
            SiriExpenseCardView(result: result)
        }
    }
}

@available(iOS 27.3, *)
struct SiriRecordedTransaction: TransientAppEntity, SnippetRepresentableEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "登録した明細"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "シート名") var sheetName: String
    @Property(title: "シートのアイコン", visibility: .internal) var sheetSymbol: String?
    @Property(title: "シートの色", visibility: .internal) var sheetColorHex: String?
    @Property(title: "明細") var row: SiriExpenseCardRow
    @Property(title: "取引の種類") var kindName: String
    @Property(title: "割り勘の対象") var splitMemberNames: [String]?
    @ComputedProperty(title: "編集対象") var editableTransaction: SiriEditableTransactionEntity? { row.editableTransaction }

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

    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { recorded, _ in
            SiriExpenseCardView(recorded: recorded)
        }
    }
}

@available(iOS 27.3, *)
struct SiriExpenseCardView: View {
    private enum Content {
        case search(SiriExpenseCardResult)
        case recorded(SiriRecordedTransaction)
    }
    private let content: Content
    private var allowsOpening = true

    init(result: SiriExpenseCardResult) { content = .search(result) }
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
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .foregroundStyle(primaryInk)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .privacySensitive()
    }

    @ViewBuilder
    private func searchContent(_ result: SiriExpenseCardResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !result.expenseName.isEmpty {
                Text(verbatim: result.expenseName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            sheetHeader(name: result.sheetName, detail: result.period,
                       symbol: result.sheetSymbol, colorHex: result.sheetColorHex)
        }

        if result.rows.isEmpty {
            Text("該当する支出はありません")
                .font(.body)
        } else {
            Text(verbatim: result.total)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            ViewThatFits(in: .vertical) {
                ForEach((0...result.rows.count).reversed(), id: \.self) { visibleCount in
                    list(result, limit: visibleCount)
                }
            }
        }
    }

    private func sheetHeader(name: String, detail: String, symbol: String?, colorHex: String?) -> some View {
        HStack(spacing: 8) {
            SheetIconView.baseIcon(symbol: symbol ?? "person.2.fill",
                                  tint: Color(hex: colorHex ?? "#5B8DEF") ?? .indigo, size: 24)
                .accessibilityHidden(true)
            Text("\(name) · \(detail)")
                .font(.subheadline)
                .foregroundStyle(secondaryInk)
        }
    }

    private func list(_ result: SiriExpenseCardResult, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<limit, id: \.self) { index in
                let item = result.rows[index]
                if index == 0 || result.rows[index - 1].date != item.date {
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
            let hiddenCount = result.count - limit
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
    }

    private func categoryIcon(_ item: SiriExpenseCardRow) -> some View {
        ZStack(alignment: .bottomTrailing) {
            CategoryIconView(symbol: item.categorySymbol.isEmpty ? "tag.slash" : item.categorySymbol,
                             tint: Color(hex: item.categoryColorHex) ?? .gray, size: 38)
            if let payerName = item.payerName {
                AvatarView(photoData: item.payerPhoto?.data, displayName: payerName,
                           colorHex: item.payerColorHex ?? "", size: 18)
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

#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import SwiftUI

@available(iOS 27.3, *)
struct SiriExpenseCardRow: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "支出明細"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "支出名") var title: String
    @Property(title: "支払日") var date: String
    @Property(title: "カテゴリ") var category: String
    @Property(title: "金額") var amount: String
    @Property(title: "カテゴリの色", visibility: .internal) var categoryColorHex: String
    @Property(title: "カテゴリのアイコン", visibility: .internal) var categorySymbol: String
    @Property(title: "表示用金額", visibility: .internal) var signedAmount: String?
    @Property(title: "支払者") var payerName: String?
    @Property(title: "支払者の色", visibility: .internal) var payerColorHex: String?
    @Property(title: "支払者のアイコン", visibility: .internal) var payerPhoto: IntentFile?
    @Property(title: "外貨の通貨コード") var foreignCurrencyCode: String?

    init() {}

    init(title: String, date: String, category: String, amount: String,
         categoryColorHex: String = "", categorySymbol: String = "tag",
         signedAmount: String? = nil, payerName: String? = nil,
         payerColorHex: String = "", payerPhoto: IntentFile? = nil,
         foreignCurrencyCode: String? = nil) {
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
}

@available(iOS 27.3, *)
struct SiriExpenseCardResult: TransientAppEntity, SnippetRepresentableEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "支出の検索結果"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "シート名") var sheetName: String
    @Property(title: "対象期間") var period: String
    @Property(title: "検索した支出名") var expenseName: String
    @Property(title: "該当件数") var count: Int
    @Property(title: "通貨別の合計") var total: String
    @Property(title: "新しい順の明細") var rows: [SiriExpenseCardRow]

    init() {}

    init(sheetName: String, period: String, expenseName: String, count: Int, total: String,
         rows: [SiriExpenseCardRow]) {
        self.sheetName = sheetName
        self.period = period
        self.expenseName = expenseName
        self.count = count
        self.total = total
        self.rows = Array(rows.prefix(5))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sheetName)の支出明細", subtitle: "\(period) · \(count)件")
    }

    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { result, _ in
            SiriExpenseCardView(result: result)
        }
    }
}

@available(iOS 27.3, *)
struct SiriExpenseCardView: View {
    let result: SiriExpenseCardResult
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.expenseName.isEmpty ? String(localized: "支出明細") : result.expenseName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("\(result.sheetName) · \(result.period)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if result.rows.isEmpty {
                Text("該当する支出はありません")
                    .font(.body)
            } else {
                Text("合計 \(result.total)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                ViewThatFits(in: .vertical) {
                    list(limit: result.rows.count)
                    if result.rows.count > 2 { list(limit: 2) }
                    if result.rows.count > 1 { list(limit: 1) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .privacySensitive()
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<limit, id: \.self) { index in
                let item = result.rows[index]
                if index == 0 || result.rows[index - 1].date != item.date {
                    Text(verbatim: item.date)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
                row(item)
            }
            if result.count > limit {
                Text("全\(result.count)件のうち最新\(limit)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(result.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: SiriExpenseCardRow) -> some View {
        let amount = VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: item.signedAmount ?? item.amount)
                .font(.subheadline.monospacedDigit())
            if let code = item.foreignCurrencyCode {
                Text(verbatim: code)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        .accessibilityElement(children: .combine)
    }

    private func categoryIcon(_ item: SiriExpenseCardRow) -> some View {
        ZStack(alignment: .bottomTrailing) {
            CategoryIconView(symbol: item.categorySymbol.isEmpty ? "tag.slash" : item.categorySymbol,
                             tint: Color(hex: item.categoryColorHex) ?? .gray, size: 38)
            if let payerName = item.payerName {
                AvatarView(photoData: item.payerPhoto?.data, displayName: payerName,
                           colorHex: item.payerColorHex ?? "", size: 18)
                    .background(Circle().fill(Color.platformSystemBackground).padding(-2))
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
                    .foregroundStyle(.secondary)
            }
            if let payerName = item.payerName, !payerName.isEmpty {
                Text(verbatim: payerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif

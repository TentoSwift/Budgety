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

    init() {}

    init(title: String, date: String, category: String, amount: String,
         categoryColorHex: String = "", categorySymbol: String = "tag") {
        self.title = title
        self.date = date
        self.category = category
        self.amount = amount
        self.categoryColorHex = categoryColorHex
        self.categorySymbol = categorySymbol
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
                row(result.rows[index])
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
        let tint = Color(hex: item.categoryColorHex) ?? .secondary
        let tile = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.categorySymbol.isEmpty ? "tag" : item.categorySymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(5)
                .background(tint.opacity(0.22), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: item.title).fixedSize()
                        Spacer(minLength: 0)
                        Text(verbatim: item.amount).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.title)
                        Text(verbatim: item.amount)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                Text(item.title == item.category ? item.date : "\(item.date) · \(item.category)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.13), in: tile)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
        }
        .clipShape(tile)
        .accessibilityElement(children: .combine)
    }
}
#endif

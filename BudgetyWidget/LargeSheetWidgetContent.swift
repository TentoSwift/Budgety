import SwiftUI
import WidgetKit

struct LargeSheetWidgetContent: View {
    let sheet: WidgetSheetSnapshot
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("今月の収支").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(sheet.income - sheet.expense, format: .currency(code: sheet.currency))
                .font(.title2.bold().monospacedDigit()).minimumScaleFactor(0.65)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { income; spending }
            VStack(alignment: .leading) { income; spending }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        Divider()
        Text("直近30日の支出").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if let rows = sheet.recentExpenses {
            if rows.isEmpty {
                Text("支出はありません").font(.subheadline)
            } else {
                ViewThatFits(in: .vertical) {
                    ForEach((0...rows.count).reversed(), id: \.self) { limit in
                        list(rows, limit: limit)
                    }
                }
            }
        } else {
            Text("Budgetyを開いて更新してください。").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
    }

    private var income: some View {
        HStack(spacing: 4) {
            Text("収入")
            Text(sheet.income, format: .currency(code: sheet.currency)).lineLimit(1)
        }
    }

    private var spending: some View {
        HStack(spacing: 4) {
            Text("支出")
            Text(sheet.expense, format: .currency(code: sheet.currency)).lineLimit(1)
        }
    }

    private func list(_ rows: [WidgetExpenseRow], limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<limit, id: \.self) { index in
                let row = rows[index]
                if index == 0 || !Calendar.current.isDate(rows[index - 1].date, inSameDayAs: row.date) {
                    Text(row.date, format: .dateTime.month().day())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
                expenseRow(row)
            }
            if let count = sheet.recentExpenseCount, count > limit {
                Text("+\(count - limit)件")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func expenseRow(_ item: WidgetExpenseRow) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill((Color(hex: item.colorHex) ?? .gray).gradient)
                    Image(systemName: item.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .blendMode(renderingMode == .fullColor ? .normal : .destinationOut)
                }
                .compositingGroup()
                .frame(width: 31, height: 31)
                if let name = item.payerName {
                    avatar(for: item, name: name).offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.category).font(.subheadline.weight(.medium))
                if !item.title.isEmpty && item.title != item.category {
                    Text(verbatim: item.title).font(.caption).foregroundStyle(.secondary)
                }
                if let name = item.payerName {
                    Text(verbatim: name).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 3)
            VStack(alignment: .trailing, spacing: 0) {
                Text(-item.amount, format: .currency(code: item.currency))
                    .font(.subheadline.monospacedDigit()).minimumScaleFactor(0.65)
                if item.currency != sheet.currency {
                    Text(verbatim: item.currency).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .layoutPriority(1)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    private func avatar(for item: WidgetExpenseRow, name: String) -> some View {
        ZStack {
            Circle().fill(Color(hex: item.payerColorHex ?? "") ?? .secondary)
            if let bytes = item.payerThumbnail, let photo = UIImage(data: bytes) {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                Text(verbatim: String(name.prefix(1))).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 15, height: 15)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.background, lineWidth: 1))
    }
}

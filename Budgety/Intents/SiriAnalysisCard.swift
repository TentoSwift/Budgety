#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import SwiftUI

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriAnalysisCard: View {
    let report: SiriAnalysisReport
    @Environment(\.colorScheme) private var colorScheme

    private var surface: Color { Color(white: colorScheme == .dark ? 0.10 : 0.98) }
    private var primaryInk: Color { Color(white: colorScheme == .dark ? 1 : 0.08) }
    private var secondaryInk: Color { Color(white: colorScheme == .dark ? 0.82 : 0.30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: report.title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(verbatim: report.scope).font(.caption).foregroundStyle(secondaryInk)
            Text(verbatim: report.summary).font(.subheadline.bold()).monospacedDigit()
            if let note = report.note {
                Text(verbatim: note).font(.caption).foregroundStyle(secondaryInk)
            }
            if !report.rows.isEmpty {
                Divider()
                ViewThatFits(in: .vertical) {
                    #if os(watchOS)
                    list(limit: 2)
                    #else
                    list(limit: 5)
                    list(limit: 3)
                    #endif
                    list(limit: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .foregroundStyle(primaryInk)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<min(limit, report.rows.count), id: \.self) { index in
                let row = report.rows[index]
                if let id = row.transactionID {
                    Button(intent: SiriOpenExpenseIntent(expenseIdentifier: id)) { content(row) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Budgetyで明細を開きます")
                } else { content(row) }
            }
            let remaining = report.matchingRowCount - min(limit, report.rows.count)
            if remaining > 0 {
                Text("ほか\(remaining)件").font(.caption).foregroundStyle(secondaryInk)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func content(_ row: SiriAnalysisReport.Row) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let artwork = row.artwork {
                switch artwork {
                case let .category(symbol, colorHex):
                    CategoryIconView(symbol: symbol, tint: Color(hex: colorHex) ?? .gray, size: 32)
                        .accessibilityHidden(true)
                case let .member(name, colorHex, photo, isVirtual):
                    AvatarView(photoData: photo, displayName: name, colorHex: colorHex, size: 32, isVirtual: isVirtual)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title).font(.subheadline.weight(.semibold))
                Text(verbatim: row.value).font(.subheadline.monospacedDigit())
                if let detail = row.detail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(secondaryInk)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif

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
            if report.rows.first?.comparison != nil {
                periodComparisons
            } else if report.sections.isEmpty {
                standardContent
            } else {
                monthlyRankings
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .foregroundStyle(primaryInk)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var periodComparisons: some View {
        Text(verbatim: report.scope).font(.caption).foregroundStyle(secondaryInk)
        ForEach(0..<report.rows.count, id: \.self) { index in
            if let comparison = report.rows[index].comparison {
                if index > 0 { Divider() }
                if report.matchingRowCount > 1 { Text(verbatim: comparison.currency).font(.caption.bold()) }
                Text(verbatim: comparison.headline).font(.headline).accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]).accessibilityHidden(true)
                            Text(verbatim: comparison.priorLabel)
                            Text(verbatim: comparison.currentLabel)
                        }
                        .font(.caption).foregroundStyle(secondaryInk)
                        ForEach(0..<comparison.metrics.count, id: \.self) { i in
                            let metric = comparison.metrics[i]
                            GridRow {
                                Text(verbatim: metric.title).gridColumnAlignment(.leading)
                                Text(verbatim: metric.prior)
                                Text(verbatim: metric.current)
                            }
                            .font(.subheadline.weight(i == 0 ? .semibold : .regular))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach([false, true], id: \.self) { isCurrent in
                            Text(verbatim: isCurrent ? comparison.currentLabel : comparison.priorLabel).font(.caption).foregroundStyle(secondaryInk)
                            ForEach(0..<comparison.metrics.count, id: \.self) { i in
                                let metric = comparison.metrics[i]
                                HStack(alignment: .firstTextBaseline) {
                                    Text(verbatim: metric.title)
                                    Spacer(minLength: 3)
                                    Text(verbatim: isCurrent ? metric.current : metric.prior)
                                }
                                .font(.subheadline.weight(i == 0 ? .semibold : .regular))
                            }
                        }
                    }
                }
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: comparison.metrics.map {
                    "\($0.title)、\(comparison.priorLabel) \($0.prior)、\(comparison.currentLabel) \($0.current)"
                }.joined(separator: "。")))
            }
        }
        let remaining = report.omittedRowCount(displayedCount: report.rows.count)
        if remaining > 0 { Text("ほか\(remaining)通貨").font(.caption).foregroundStyle(secondaryInk) }
        if let note = report.note { Text(verbatim: note).font(.caption).foregroundStyle(secondaryInk) }
    }

    @ViewBuilder private var standardContent: some View {
        Text(verbatim: report.title).font(.headline).accessibilityAddTraits(.isHeader)
        Text(verbatim: report.scope).font(.caption).foregroundStyle(secondaryInk)
        Text(verbatim: report.summary)
            .font(report.filteredTotalDialog == nil ? .subheadline.bold() : .title3.bold())
            .monospacedDigit()
        if !report.matchedMerchantNames.isEmpty {
            // Newest rows can all be from one shop. Include older matching names alongside the total.
            let names = report.matchedMerchantNames
            let preview = names.prefix(8).joined(separator: "、")
            let rest = names.count - min(names.count, 8)
            Group {
                if rest > 0 { Text("対象：\(preview) ほか\(rest)件") }
                else { Text("対象：\(preview)") }
            }
            .font(.caption).foregroundStyle(secondaryInk)
        }
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
                list(limit: 2)
                #endif
                list(limit: 1)
            }
        }
    }

    @ViewBuilder private var monthlyRankings: some View {
        Text(verbatim: report.scope).font(.caption).foregroundStyle(secondaryInk)
        ForEach(0..<report.sections.count, id: \.self) { index in
            let section = report.sections[index]
            if index > 0 { Divider() }
            HStack(alignment: .center, spacing: 8) {
                if case let .category(symbol, colorHex)? = section.artwork {
                    CategoryIconView(symbol: symbol, tint: Color(hex: colorHex) ?? .gray, size: 28)
                        .accessibilityHidden(true)
                }
                Text(verbatim: section.title).font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if section.rows.isEmpty {
                Text(verbatim: section.summary).font(.subheadline)
            } else {
                let visibleCount = min(5, section.rows.count)
                ForEach(0..<visibleCount, id: \.self) { rowIndex in
                    let row = section.rows[rowIndex]
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: row.title).fixedSize()
                            Spacer(minLength: 2)
                            Text(verbatim: row.value).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: row.title)
                            Text(verbatim: row.value)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
                if section.rows.count > visibleCount {
                    Text("ほか\(section.rows.count - visibleCount)か月")
                        .font(.caption).foregroundStyle(secondaryInk)
                }
            }
            if let note = section.note {
                Text(verbatim: note).font(.caption).foregroundStyle(secondaryInk)
            }
        }
        if let note = report.note {
            Text(verbatim: note).font(.caption).foregroundStyle(secondaryInk)
        }
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
            let remaining = report.omittedRowCount(displayedCount: min(limit, report.rows.count))
            if remaining > 0 {
                Group {
                    if report.filteredTotalDialog != nil { Text("+\(remaining)件") }
                    else { Text("ほか\(remaining)件") }
                }
                .font(.caption).foregroundStyle(secondaryInk)
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
            if report.filteredTotalDialog != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        transactionLabel(row).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        Text(verbatim: row.value).font(.subheadline.monospacedDigit()).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        transactionLabel(row)
                        Text(verbatim: row.value).font(.subheadline.monospacedDigit())
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title).font(.subheadline.weight(.semibold))
                    Text(verbatim: row.value).font(.subheadline.monospacedDigit())
                    if let detail = row.detail {
                        Text(verbatim: detail).font(.caption).foregroundStyle(secondaryInk)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func transactionLabel(_ row: SiriAnalysisReport.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.title).font(.subheadline.weight(.semibold))
            if let detail = row.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(secondaryInk)
            }
        }
    }
}
#endif

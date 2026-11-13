#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import SwiftUI

@available(iOS 27.3, macOS 27.3, *)
struct SiriSettlementCardView: View {
    let sheetID: String?
    let sheetName: String
    let sheetSymbol: String?
    let sheetColorHex: String?
    let period: String
    let title: LocalizedStringKey
    let rows: [SiriSettlementCardRow]
    let missingRates: [String]

    init(result: SiriSettlementCardResult) {
        self.init(sheetID: result.sheetID, sheetName: result.sheetName, sheetSymbol: result.sheetSymbol, sheetColorHex: result.sheetColorHex,
                  period: result.period, title: "精算状況", rows: result.rows, missingRates: result.missingRates)
    }

    init(sheetID: String? = nil, sheetName: String, sheetSymbol: String?, sheetColorHex: String?, period: String,
         title: LocalizedStringKey, rows: [SiriSettlementCardRow], missingRates: [String] = []) {
        self.sheetID = sheetID
        self.sheetName = sheetName
        self.sheetSymbol = sheetSymbol
        self.sheetColorHex = sheetColorHex
        self.period = period
        self.title = title
        self.rows = rows
        self.missingRates = missingRates
    }

    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { Color(white: colorScheme == .dark ? 1.0 : 0.08) }
    private var secondaryInk: Color { Color(white: colorScheme == .dark ? 0.82 : 0.30) }
    private var surface: Color { Color(white: colorScheme == .dark ? 0.10 : 0.98) }

    var body: some View {
        if let sheetID {
            Button(intent: SiriOpenSettlementIntent(sheetID: sheetID)) {
                card.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Budgetyでこのシートの精算詳細を開きます")
        } else {
            card
        }
    }

    private var card: some View {
        ViewThatFits(in: .vertical) {
            ForEach((0...min(5, rows.count)).reversed(), id: \.self) { limit in
                VStack(alignment: .leading, spacing: 8) {
                    header
                    Divider()
                    if rows.isEmpty {
                        Label {
                            Text(missingRates.isEmpty ? "精算は不要です" : "換算できた範囲では精算は不要です")
                        } icon: {
                            Image(systemName: missingRates.isEmpty ? "checkmark.circle" : "info.circle").accessibilityHidden(true)
                        }
                        .font(.subheadline)
                    }
                    ForEach(0..<limit, id: \.self) { index in
                        transfer(rows[index])
                        if index + 1 < limit { Divider() }
                    }
                    if rows.count > limit {
                        Text("+\(rows.count - limit)件").font(.caption).foregroundStyle(secondaryInk)
                    }
                    if !missingRates.isEmpty {
                        Text("未換算の通貨：\(missingRates.formatted(.list(type: .and)))")
                            .font(.footnote).foregroundStyle(secondaryInk)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(watchOS)
        .padding(6)
        #else
        .padding(12)
        #endif
        .foregroundStyle(ink)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .privacySensitive()
    }

    private var header: some View {
        HStack(spacing: 10) {
            SheetSymbolIcon(symbol: sheetSymbol ?? "person.2.fill",
                            tint: Color(hex: sheetColorHex ?? "#5B8DEF") ?? .indigo, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text("\(sheetName) · \(period)").font(.subheadline).foregroundStyle(secondaryInk)
            }
        }
    }

    private func transfer(_ row: SiriSettlementCardRow) -> some View {
        let direction = Image(systemName: "arrow.forward")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(secondaryInk)
        let amount = Text(verbatim: row.amount).font(.headline.monospacedDigit())
        #if os(watchOS)
        let content = VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                profile(row.sender).frame(maxWidth: .infinity)
                direction.padding(.top, 5)
                profile(row.recipient).frame(maxWidth: .infinity)
            }
            amount
        }
        #else
        let content = ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                profile(row.sender)
                    .frame(minWidth: 54, maxWidth: .infinity)
                VStack(spacing: 4) { amount.fixedSize(); direction }
                profile(row.recipient)
                    .frame(minWidth: 54, maxWidth: .infinity)
            }
            // Keep large amounts and long names legible even in a narrow Siri overlay.
            VStack(alignment: .leading, spacing: 6) {
                inlineProfile(row.sender)
                HStack(spacing: 8) { Image(systemName: "arrow.down"); amount }
                    .padding(.leading, 10)
                inlineProfile(row.recipient)
            }
        }
        #endif
        return content
            .padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: row.spokenDetail))
    }

    private func avatar(_ profile: SiriSettlementProfile) -> some View {
        #if os(watchOS)
        let size: CGFloat = 26
        #else
        let size: CGFloat = 40
        #endif
        return AvatarView(photoData: profile.photo?.data, displayName: profile.name, colorHex: profile.colorHex,
                          size: size, isVirtual: profile.isVirtual)
            .accessibilityHidden(true)
    }

    private func profile(_ profile: SiriSettlementProfile) -> some View {
        VStack(spacing: 4) {
            avatar(profile)
            Text(verbatim: profile.name)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineProfile(_ profile: SiriSettlementProfile) -> some View {
        HStack(spacing: 8) {
            avatar(profile)
            Text(verbatim: profile.name).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif

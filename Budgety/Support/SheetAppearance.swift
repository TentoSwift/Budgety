import SwiftUI

enum SheetAppearance {
    static let summaryCornerRadius: CGFloat = 28
}

extension Font {
    static func sheetNumber(_ style: TextStyle, weight: Weight? = nil) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }
}

struct SheetSettlementButton: View {
    @ObservedObject var sheet: ExpenseSheet
    let action: () -> Void
    @ObservedObject private var profiles = PublicProfileSync.shared
    @ObservedObject private var userProfile = UserProfileStore.shared
    @ScaledMetric(relativeTo: .body) private var overlap: CGFloat = 6

    var body: some View {
        let members = sheet.acceptedMemberProfileIDs()
        if members.count > 1 || members.contains(where: UserProfileStore.isVirtualRecordName) {
            let visible = members.prefix(4).map { (id: $0, info: sheet.memberDisplayInfo(for: $0)) }
            Button(action: action) {
                HStack(spacing: -overlap) {
                    ForEach(visible, id: \.id) { member in
                        AvatarView(photoData: member.info.photoData, displayName: member.info.name,
                                   colorHex: member.info.colorHex, size: 28,
                                   isVirtual: UserProfileStore.isVirtualRecordName(member.id))
                            .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                    }
                    if members.count > visible.count {
                        Text("+\(members.count - visible.count)")
                            .font(.sheetNumber(.caption, weight: .semibold))
                            .padding(5)
                            .background(.background, in: Capsule())
                    }
                }
                .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("精算")
            .accessibilityValue(Text(verbatim: visible.map { $0.info.name }.formatted(.list(type: .and))))
            .accessibilityIdentifier("sheetSettlementButton")
        }
    }
}

#if canImport(UIKit)
import UIKit

extension UIFont {
    static func sheetNumber(ofSize size: CGFloat, weight: Weight) -> UIFont {
        let base = monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }
}
#endif

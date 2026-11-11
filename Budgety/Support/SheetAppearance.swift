import SwiftUI

enum SheetAppearance {
    static let summaryCornerRadius: CGFloat = 28
}

extension Font {
    static func sheetNumber(_ style: TextStyle, weight: Weight? = nil) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }
}

struct SheetMemberAvatars: View {
    @ObservedObject var sheet: ExpenseSheet
    @ObservedObject private var profiles = PublicProfileSync.shared
    @ObservedObject private var userProfile = UserProfileStore.shared
    @ScaledMetric(relativeTo: .body) private var overlap: CGFloat = 6

    var body: some View {
        let members = sheet.acceptedMemberProfileIDs()
        if members.count > 1 || members.contains(where: UserProfileStore.isVirtualRecordName) {
            HStack(spacing: -overlap) {
                ForEach(members.prefix(4), id: \.self) { id in
                    let info = sheet.memberDisplayInfo(for: id)
                    AvatarView(photoData: info.photoData, displayName: info.name, colorHex: info.colorHex, size: 28,
                               isVirtual: UserProfileStore.isVirtualRecordName(id))
                        .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: info.name))
                }
                if members.count > 4 {
                    Text("+\(members.count - 4)")
                        .font(.sheetNumber(.caption, weight: .semibold))
                        .padding(5)
                        .background(.background, in: Capsule())
                }
            }
            .accessibilityElement(children: .combine)
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

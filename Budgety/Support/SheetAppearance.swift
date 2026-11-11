import SwiftUI

enum SheetAppearance {
    static let summaryCornerRadius: CGFloat = 28
}

extension Font {
    static func sheetNumber(_ style: TextStyle, weight: Weight? = nil) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
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

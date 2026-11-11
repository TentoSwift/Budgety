import SwiftUI

struct SheetSymbolIcon: View {
    let symbol: String
    let tint: Color
    let size: CGFloat
    var cutsOutSymbol = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(tint.gradient)
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .font(.system(size: size * 0.46, weight: .semibold))
                .blendMode(cutsOutSymbol ? .destinationOut : .normal)
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }
}

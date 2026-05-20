//
//  SheetIconPickerView.swift
//  Budgety
//
//  iOS の AddSheet / EditSheet からプッシュ遷移して使うアイコンピッカー。
//  基本 (Free) 以外のセクション (家・暮らし / 仕事・勉強 / 旅行・移動 / etc.) を
//  すべて閲覧 / 選択できる。Premium 限定シンボルはロック表示。
//

import SwiftUI

struct SheetIconPickerView: View {
    @Binding var selectedSymbol: String
    let tint: Color

    @Environment(\.dismiss) private var dismiss
    @State private var showingPaywall: Bool = false

    /// 基本セクションは元の画面に出ているので、ピッカー側では除外する。
    private var sections: [SheetSymbols.Section] {
        SheetSymbols.sections.filter { $0.id != "free" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        // AX サイズでも列が詰まらないよう adaptive grid
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 50), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(section.symbols, id: \.self) { sym in
                                iconButton(sym)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.platformSecondarySystemBackground)
                    )
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(Color.platformSystemBackground.ignoresSafeArea())
        .navigationTitle("アイコンを選ぶ")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }

    @ViewBuilder
    private func iconButton(_ sym: String) -> some View {
        let isSelected = selectedSymbol == sym
        let isLocked = SheetSymbols.isPremiumSymbol(sym) && !PurchaseManager.shared.isPremium
        Button {
            if isLocked {
                showingPaywall = true
                Haptics.warning()
            } else {
                selectedSymbol = sym
                Haptics.selection()
                dismiss()
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 3)
                        .frame(width: 46, height: 46)
                }
                Circle()
                    .fill(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 38, height: 38)
                // 固定サイズで Dynamic Type に追従させない
                Image(systemName: sym)
                    .foregroundStyle(isSelected ? .white : Color.primary)
                    .font(.system(size: 17, weight: .medium))
                    .opacity(isLocked ? 0.45 : 1)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 13, y: 13)
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
    }
}

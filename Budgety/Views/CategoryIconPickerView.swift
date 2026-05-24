//
//  CategoryIconPickerView.swift
//  Budgety
//
//  iOS の EditCategoryView からプッシュ遷移して使うカテゴリアイコンピッカー。
//  基本 (Free) 以外のセクション (食べ物・交通・趣味 etc.) を全て閲覧 / 選択できる。
//  Premium 限定シンボルはロック表示。
//

import SwiftUI

struct CategoryIconPickerView: View {
    @Binding var selectedSymbol: String
    let tint: Color
    /// 編集中の既存シンボル (= 後で Premium が切れても再選択できるよう救済)
    var origSymbol: String = ""
    /// このシートで課金機能が使えるか (自分が Premium / 共有シート)。
    /// true ならプレミアムアイコンもロックせず選択できる。
    var premiumUnlocked: Bool = PurchaseManager.isCurrentUserPremium

    @Environment(\.dismiss) private var dismiss
    @State private var showingPaywall: Bool = false

    /// 基本セクションは元の画面に出ているので、ピッカー側では除外する。
    private var sections: [CategoryDefaults.SymbolSection] {
        CategoryDefaults.symbolSections.filter { $0.id != "free" }
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
                            columns: [GridItem(.adaptive(minimum: 54), spacing: 12)],
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
        // 保存済みの symbol は救済 (後で Premium が切れても再選択できるように)
        let isLocked = CategoryDefaults.isPremiumSymbol(sym)
            && !premiumUnlocked
            && sym != origSymbol
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
                        .frame(width: 50, height: 50)
                }
                Circle()
                    .fill(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 40, height: 40)
                // 固定サイズで Dynamic Type に追従させない
                Image(systemName: sym)
                    .foregroundStyle(isSelected ? .white : Color.primary)
                    .font(.system(size: 18, weight: .medium))
                    .opacity(isLocked ? 0.45 : 1)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 14, y: 14)
                }
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
    }
}

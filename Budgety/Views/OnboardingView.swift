//
//  OnboardingView.swift
//  Budgety
//
//  初回起動時のオンボーディング。
//  - ヘッダー (アクセント色のシンボル + 「ようこそ / Budgety へ」)
//  - 機能ハイライト 4 件 (シート / 共有 / 多通貨 / AI・Siri)
//  - 下部「はじめる」ボタン (Liquid Glass 効果)
//

import SwiftUI

struct OnboardingView: View {
    /// 完了時に呼ばれる。呼び出し側は `@AppStorage("hasShownOnboarding")` 等を true にする。
    var onContinue: () -> Void

    // Dynamic Type で拡大されるヘッダーアイコン
    @ScaledMetric(relativeTo: .largeTitle) private var headerIconSize: CGFloat = 60
    // FeatureRow のアイコン枠サイズ
    @ScaledMetric(relativeTo: .title2) private var featureIconWidth: CGFloat = 38

    @State private var appearOpacity: Double = 0

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    // ヘッダー
                    VStack(spacing: 12) {
                        VStack(spacing: 4) {
                            Text("ようこそ")
                                .font(.largeTitle.weight(.bold))
                            Text("Budgety へ")
                                .font(.largeTitle.weight(.bold))
                                .foregroundStyle(.tint)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 24)

                    // 機能ハイライト
                    VStack(alignment: .leading, spacing: 22) {
                        FeatureRow(
                            icon: "rectangle.stack.fill",
                            title: "シートで分けて管理",
                            description: "家計・旅行・サークルなど、用途ごとにシートを作って独立した家計簿として使えます。",
                            iconWidth: featureIconWidth
                        )
                        FeatureRow(
                            icon: "person.2.fill",
                            title: "家族や友人と共有",
                            description: "iCloud を通じてシートを共有。立て替えと精算プランも自動で計算します。",
                            iconWidth: featureIconWidth
                        )
                        FeatureRow(
                            icon: "globe",
                            title: "多通貨対応",
                            description: "海外旅行や外貨支出も同じシートで管理。為替レートで自動換算します。",
                            iconWidth: featureIconWidth
                        )
                        FeatureRow(
                            icon: "sparkles",
                            title: "AI と Siri で簡単入力",
                            description: "Apple Intelligence によるカテゴリ自動推測と、Siri ショートカットで素早く記録できます。",
                            iconWidth: featureIconWidth
                        )
                    }
                    .padding(.horizontal, 32)
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            // 上下端を gradient mask でフェードアウト
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .opacity(appearOpacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.5)) { appearOpacity = 1 }
            }
        }
        // フッター: はじめるボタン (Liquid Glass) + プライバシーポリシー同意の表記
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                // 「はじめる」を押すと同意したものとみなす旨と、ポリシーへのリンク。
                Text(.init("「はじめる」を押すと [プライバシーポリシー](https://tentoswift.github.io/budgety-privacy/) に同意したものとみなされます。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .tint(Color.accentColor)
                    .padding(.horizontal, 24)

                Button {
                    onContinue()
                } label: {
                    Text("はじめる")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Rectangle())
                }
                .glassEffect()
                .tint(Color.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    let iconWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onContinue: {})
}

#Preview("Accessibility XXXL") {
    OnboardingView(onContinue: {})
        .environment(\.dynamicTypeSize, .accessibility3)
}

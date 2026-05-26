//
//  OnboardingView.swift
//  Budgety
//
//  Apple の「新機能 (What's New)」画面風の初回オンボーディング。
//  - 中央にアプリアイコン
//  - 左寄せの小見出し (アクセント色) + 大きいタイトル
//  - 機能ハイライト 4 つ (アクセント色の SF Symbol + 見出し + 説明、左寄せ)
//  - 下部に「続ける」ボタン (アクセント色の capsule)
//

import SwiftUI

struct OnboardingView: View {
    /// 完了時に呼ばれる。呼び出し側は `@AppStorage("hasShownOnboarding")` 等を true にする。
    var onContinue: () -> Void

    /// 表示時に内容をフェード＋わずかにスライドインさせる (Apple 標準の登場演出)。
    @State private var appeared = false

    var body: some View {

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    
                    // 小見出し + タイトル (左寄せ)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ようこそ")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Budgetyへ")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 28)
                    
                    // 機能ハイライト (左寄せ)
                    featuresList
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { appeared = true }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    footer
                }
            }
        }
    }


    // MARK: - Features

    private struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let body: String
    }

    private let features: [Feature] = [
        .init(
            symbol: "rectangle.stack.fill",
            title: "シートで分けて管理",
            body: "家計・旅行・サークルなど、用途ごとにシートを作って独立した家計簿として使えます。"
        ),
        .init(
            symbol: "person.2.fill",
            title: "家族や友人と共有",
            body: "iCloud を通じてシートを共有。立て替えと精算プランも自動で計算します。"
        ),
        .init(
            symbol: "globe",
            title: "多通貨対応",
            body: "海外旅行や外貨支出も同じシートで管理。為替レートで自動換算します。"
        ),
        .init(
            symbol: "sparkles",
            title: "AI と Siri で簡単入力",
            body: "Apple Intelligence によるカテゴリ自動推測と、Siri ショートカットで素早く記録できます。"
        )
    ]

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(features) { f in
                featureRow(f)
            }
        }
    }

    private func featureRow(_ f: Feature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // アイコンはすべてアクセント色のシンボル単体 (What's New 風)
            Image(systemName: f.symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(f.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Button {
            onContinue()
        } label: {
            Text("続ける")
        }
        .frame(maxWidth: .infinity)
        .tint(Color.accentColor)
    }
}

#Preview {
    OnboardingView(onContinue: {})
}

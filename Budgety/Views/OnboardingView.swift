//
//  OnboardingView.swift
//  Budgety
//
//  Apple 標準アプリ (Mail / Notes / Health) 風の初回オンボーディング。
//  - ヒーロー (アプリアイコン + "Welcome to ...")
//  - 機能ハイライト 4 つ (SF Symbol + title + body)
//  - 続けるボタン (capsule / accent)
//

import SwiftUI

struct OnboardingView: View {
    /// 完了時に呼ばれる。呼び出し側は `@AppStorage("hasShownOnboarding")` 等を true にする。
    var onContinue: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 表示時に内容をフェード＋わずかにスライドインさせる (Apple 標準の登場演出)。
    @State private var appeared = false

    var body: some View {
        ZStack {
            // 背景は system background + 上端からのわずかなグラデーション
            backgroundLayer
            ScrollView {
                VStack(spacing: 0) {
                    hero
                        .padding(.top, 48)
                        .padding(.bottom, 36)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(.smooth(duration: 0.5), value: appeared)
                    featuresList
                        .padding(.horizontal, 28)
                        .padding(.bottom, 36)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .onAppear { appeared = true }
            // フッター (続ける + プライバシー)
            VStack {
                Spacer()
                footer
            }
            .ignoresSafeArea(.keyboard)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 16) {
            // ヒーローアイコン: 紙幣・コイン系の SF Symbol を accent gradient の角丸 squircle で囲む。
            // (実機ではここを AppIcon の image にしてもよい)
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 116, height: 116)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 18, y: 8)
                Image(systemName: "yensign.bank.building")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("ようこそ")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Budgety へ")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("家計・旅行・共同プロジェクトの支出を、シンプルに記録・精算するアプリです。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Features

    private struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let tint: Color
        let title: String
        let body: String
    }

    private let features: [Feature] = [
        .init(
            symbol: "rectangle.stack.fill",
            tint: .blue,
            title: "シートで分けて管理",
            body: "家計・旅行・サークルなど、用途ごとにシートを作って独立した家計簿として使えます。"
        ),
        .init(
            symbol: "person.2.fill",
            tint: .green,
            title: "家族や友人と共有",
            body: "iCloud を通じてシートを共有。立て替えと精算プランも自動で計算します。"
        ),
        .init(
            symbol: "globe",
            tint: .orange,
            title: "多通貨対応",
            body: "海外旅行や外貨支出も同じシートで管理。為替レートで自動換算します。"
        ),
        .init(
            symbol: "sparkles",
            tint: .purple,
            title: "AI と Siri で簡単入力",
            body: "Apple Intelligence によるカテゴリ自動推測と、Siri ショートカットで素早く記録できます。"
        )
    ]

    private var featuresList: some View {
        VStack(spacing: 22) {
            ForEach(Array(features.enumerated()), id: \.element.id) { idx, f in
                featureRow(f)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(.smooth(duration: 0.5).delay(0.15 + Double(idx) * 0.08), value: appeared)
            }
        }
    }

    private func featureRow(_ f: Feature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: f.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(f.tint)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(f.title)
                    .font(.headline)
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
        VStack(spacing: 12) {
            Button {
                onContinue()
            } label: {
                Text("続ける")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)

            Text("シートやデータは iCloud にのみ保存されます。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [Color.platformSystemBackground.opacity(0), Color.platformSystemBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 140)
            .allowsHitTesting(false),
            alignment: .bottom
        )
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        Color.platformSystemBackground
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 260)
                .ignoresSafeArea()
            }
            .ignoresSafeArea()
    }
}

#Preview {
    OnboardingView(onContinue: {})
}

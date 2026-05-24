//
//  OnboardingView.swift
//  Budgety
//
//  初回起動時のアニメーション付きウォークスルー。
//  4 ステップ構成:
//    0. ようこそ (アニメーションするヒーロー)
//    1. できること (機能ハイライトをスタッガード表示)
//    2. お名前の設定 (プロフィール表示名)
//    3. 最初のシートを作成 (名前・カラー・アイコン)
//  各ステップは下部の「次へ / はじめる」で進み、進捗ドットで現在地を示す。
//

import SwiftUI
import CoreData

struct OnboardingView: View {
    /// 完了時に呼ばれる。呼び出し側は `@AppStorage("hasShownOnboarding")` 等を true にする。
    var onContinue: () -> Void

    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @State private var step: Int = 0
    private let lastStep = 3

    // Step 0/1 のエントランス用
    @State private var heroIn = false
    @State private var featuresIn = false

    // Step 2: 名前
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    // Step 3: 最初のシート
    @State private var sheetName: String = "家計"
    @State private var sheetColor: String = "#5B8DEF"
    @State private var sheetSymbol: String = SheetSymbols.freeOptions.first ?? "house.fill"
    @FocusState private var sheetNameFocused: Bool
    @State private var didFinish = false

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]
    private var symbolChoices: [String] { Array(SheetSymbols.freeOptions.prefix(10)) }

    var body: some View {
        ZStack {
            backgroundLayer
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    AnimatedStep {
                        stepContent
                    }
                    .id(step)
                    .padding(.top, 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                footer
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: featuresStep
        case 2: nameStep
        default: sheetStep
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            heroIcon
            VStack(spacing: 8) {
                Text("ようこそ")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Budgety へ")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("家計・旅行・共同プロジェクトの支出を、シンプルに記録・精算。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .opacity(heroIn ? 1 : 0)
            .offset(y: heroIn ? 0 : 14)
        }
        .padding(.top, 24)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { heroIn = true }
        }
        .onDisappear { heroIn = false }
    }

    private var heroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 120, height: 120)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)
            Image(systemName: "yensign.circle.fill")
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: heroIn)
        }
        .scaleEffect(heroIn ? 1 : 0.5)
        .rotationEffect(.degrees(heroIn ? 0 : -10))
        .opacity(heroIn ? 1 : 0)
    }

    // MARK: - Step 1: Features

    private struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let tint: Color
        let title: String
        let body: String
    }

    private let features: [Feature] = [
        .init(symbol: "rectangle.stack.fill", tint: .blue,
              title: "シートで分けて管理",
              body: "家計・旅行・サークルなど、用途ごとに独立した家計簿として使えます。"),
        .init(symbol: "person.2.fill", tint: .green,
              title: "家族や友人と共有",
              body: "iCloud でシートを共有。立て替えと精算プランも自動で計算。"),
        .init(symbol: "globe", tint: .orange,
              title: "多通貨に対応",
              body: "海外旅行や外貨支出も同じシートで。為替レートで自動換算します。"),
        .init(symbol: "sparkles", tint: .purple,
              title: "AI と Siri で簡単入力",
              body: "カテゴリの自動推測や、Siri ショートカットで素早く記録。")
    ]

    private var featuresStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("できること")
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 20) {
                ForEach(Array(features.enumerated()), id: \.element.id) { idx, f in
                    featureRow(f)
                        .opacity(featuresIn ? 1 : 0)
                        .offset(x: featuresIn ? 0 : 28)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85)
                            .delay(Double(idx) * 0.09), value: featuresIn)
                }
            }
        }
        .padding(.horizontal, 16)
        .onAppear { featuresIn = true }
        .onDisappear { featuresIn = false }
    }

    private func featureRow(_ f: Feature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: f.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(f.tint.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title)
                    .font(.headline)
                Text(f.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 2: Name

    private var nameStep: some View {
        VStack(spacing: 22) {
            AvatarView(
                photoData: profile.photoData,
                displayName: name.trimmingCharacters(in: .whitespaces).isEmpty ? "?" : name,
                colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                size: 96
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: name)

            VStack(spacing: 6) {
                Text("お名前を教えてください")
                    .font(.title2.bold())
                Text("共有シートで表示される名前です。あとからいつでも変更できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            TextField("名前", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .focused($nameFocused)
                .submitLabel(.next)
                .onSubmit { advance() }
        }
        .padding(.top, 12)
        .onAppear {
            // 既存の名前があれば初期表示。
            if name.isEmpty { name = profile.displayName }
        }
    }

    // MARK: - Step 3: First sheet

    private var sheetStep: some View {
        VStack(spacing: 18) {
            SheetIconView.baseIcon(
                symbol: sheetSymbol,
                tint: Color(hex: sheetColor) ?? .blue,
                size: 84
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: sheetSymbol)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: sheetColor)

            VStack(spacing: 6) {
                Text("最初のシートを作成")
                    .font(.title2.bold())
                Text("用途ごとに支出をまとめる単位です。例: 家計、旅行、サークル。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            TextField("シート名", text: $sheetName)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .focused($sheetNameFocused)

            colorRow
            symbolRow
        }
        .padding(.top, 8)
    }

    private var colorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(palette, id: \.self) { hex in
                    let selected = hex == sheetColor
                    Circle()
                        .fill(Color(hex: hex) ?? .blue)
                        .frame(width: 30, height: 30)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            if selected {
                                Circle().stroke(Color.primary.opacity(0.35), lineWidth: 3)
                                    .frame(width: 38, height: 38)
                            }
                        }
                        .onTapGesture {
                            withAnimation(.spring) { sheetColor = hex }
                            Haptics.light()
                        }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
        }
    }

    private var symbolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(symbolChoices, id: \.self) { sym in
                    let selected = sym == sheetSymbol
                    let tint = Color(hex: sheetColor) ?? .blue
                    Button {
                        withAnimation(.spring) { sheetSymbol = sym }
                        Haptics.light()
                    } label: {
                        Image(systemName: sym)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(selected ? .white : .primary)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle().fill(
                                    selected ? AnyShapeStyle(tint.gradient)
                                             : AnyShapeStyle(.quaternary)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Top bar (back / skip)

    private var topBar: some View {
        HStack {
            if step > 0 {
                Button {
                    withAnimation(.smooth) { step -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if step <= 1 {
                Button("スキップ") { finish(createSheet: false) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .padding(.top, 8)
    }

    // MARK: - Footer (dots + primary)

    private var footer: some View {
        VStack(spacing: 16) {
            progressDots
            Button { advance() } label: {
                Text(step == lastStep ? "はじめる" : "次へ")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(primaryEnabled ? Color.accentColor : Color.gray))
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .padding(.horizontal, 28)
            .animation(.smooth, value: primaryEnabled)

            if step == lastStep {
                Button("あとで作成") { finish(createSheet: false) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [Color.platformSystemBackground.opacity(0), Color.platformSystemBackground],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 130)
            .allowsHitTesting(false),
            alignment: .bottom
        )
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0...lastStep, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == step ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
    }

    private var primaryEnabled: Bool {
        if step == lastStep {
            return !sheetName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    // MARK: - Actions

    private func advance() {
        if step < lastStep {
            if step == 2 { applyName() }   // 名前ステップを離れる時に保存
            nameFocused = false
            sheetNameFocused = false
            withAnimation(.smooth) { step += 1 }
        } else {
            finish(createSheet: true)
        }
    }

    private func applyName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != profile.displayName else { return }
        profile.updateProfile(
            displayName: trimmed,
            photoData: profile.photoData,
            avatarBgColorHex: profile.avatarBgColorHex
        )
    }

    private func finish(createSheet: Bool) {
        guard !didFinish else { return }
        didFinish = true
        applyName()
        if createSheet { createFirstSheet() }
        onContinue()
    }

    private func createFirstSheet() {
        let trimmed = sheetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let sheet = ExpenseSheet(context: viewContext)
        sheet.name = trimmed
        sheet.colorHex = sheetColor
        sheet.symbol = sheetSymbol
        sheet.defaultCurrencyCode = CurrencyCatalog.defaultCode
        sheet.createdAt = .now
        PersistenceController.seedDefaultCategories(for: sheet, in: viewContext)
        PersistenceController.shared.save()
        // シート作成後に自分の ParticipantProfile を生成 (同期キー)。
        Task { @MainActor in
            await profile.ensureUserRecordNameLoaded()
            profile.ensureSelfMemberExists(in: viewContext)
            profile.ensureProfile(in: sheet, ctx: viewContext)
        }
        Haptics.success()
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        Color.platformSystemBackground
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 260)
                .ignoresSafeArea()
            }
            .ignoresSafeArea()
    }
}

/// 各ステップの共通エントランス (フェード + わずかに下からスライドイン)。
/// `.id(step)` で再生成されるたびにアニメーションが再生される。
private struct AnimatedStep<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                withAnimation(.smooth(duration: 0.45)) { shown = true }
            }
    }
}

#Preview {
    OnboardingView(onContinue: {})
}

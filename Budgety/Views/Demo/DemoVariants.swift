//
//  DemoVariants.swift
//  Expenso
//
//  各デモバリアント (時刻 → SwiftUI View の純関数) を定義する。
//  追加する時は `DemoVariant.allVariants` にエントリを足す。
//

import SwiftUI

extension DemoVariant {
    /// 一覧表示と書き出しに使うバリアント全体。
    static let allVariants: [DemoVariant] = [
        intro,
        quickInput,
        categoryStats
    ]

    static let intro = DemoVariant(
        id: "intro",
        title: "イントロ",
        subtitle: "Budgety の紹介 (タイトル + 機能 + クロージング)",
        symbol: "sparkles",
        totalDuration: 12.0,
        exportSize: CGSize(width: 1080, height: 1920),
        defaultTint: Color(red: 0.30, green: 0.55, blue: 0.95),
        render: { t, tint in AnyView(IntroDemoView(t: t, tint: tint)) }
    )

    static let quickInput = DemoVariant(
        id: "quick-input",
        title: "クイック記録",
        subtitle: "AI が自動でカテゴリも提案",
        symbol: "pencil.tip.crop.circle.badge.plus",
        totalDuration: 12.0,
        exportSize: CGSize(width: 1080, height: 1920),
        defaultTint: Color(red: 0.20, green: 0.40, blue: 0.95),
        render: { t, tint in AnyView(QuickInputDemoView(t: t, tint: tint)) }
    )

    static let categoryStats = DemoVariant(
        id: "category-stats",
        title: "カテゴリ別集計",
        subtitle: "支出をカテゴリでまとめて可視化",
        symbol: "chart.pie.fill",
        totalDuration: 10.0,
        exportSize: CGSize(width: 1080, height: 1920),
        defaultTint: Color(red: 0.36, green: 0.55, blue: 0.94),
        render: { t, tint in AnyView(CategoryStatsDemoView(t: t, tint: tint)) }
    )
}

// MARK: - 1) Intro

struct IntroDemoView: View {
    let t: Double
    let tint: Color

    private struct Feature {
        let symbol: String
        let title: String
    }
    private let features: [Feature] = [
        .init(symbol: "yensign.circle.fill", title: "家計を 1 タップで記録"),
        .init(symbol: "person.2.fill",       title: "家族とシートを共有"),
        .init(symbol: "chart.pie.fill",      title: "カテゴリ別に自動集計"),
        .init(symbol: "arrow.left.arrow.right.circle", title: "メンバー間の精算プラン")
    ]

    var body: some View {
        ZStack {
            background
            content
        }
    }

    private var background: some View {
        let phase = (t / 12.0).truncatingRemainder(dividingBy: 1.0)
        // tint を中心に上端は 1.15 倍明るく、下端は 0.65 倍暗くしたグラデ
        return LinearGradient(
            colors: [
                tint.adjust(by: 0.15 + 0.04 * sin(phase * 2 * .pi)),
                tint.adjust(by: -0.30 + 0.04 * cos(phase * 2 * .pi))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        if t < 4.0 {
            titleScene
        } else if t < 9.0 {
            featureScene(localT: (t - 4.0) / 5.0)
        } else {
            closingScene(localT: (t - 9.0) / 3.0)
        }
    }

    private var titleScene: some View {
        let titleAppear = DemoEasing.easeOut(min(1, t / 0.8))
        let tagAppear = DemoEasing.easeOut(max(0, min(1, (t - 0.8) / 0.6)))
        return VStack(spacing: 18) {
            Image(systemName: "yensign.circle.fill")
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(0.7 + 0.3 * titleAppear)
                .opacity(titleAppear)
            Text("Budgety")
                .font(.system(size: 72, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .scaleEffect(0.7 + 0.3 * titleAppear)
                .opacity(titleAppear)
            Text("家族で家計を、スマートに")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .opacity(tagAppear)
                .offset(y: 12 * (1 - tagAppear))
        }
    }

    private func featureScene(localT: Double) -> some View {
        let progress = DemoEasing.easeOut(localT)
        return VStack(spacing: 20) {
            ForEach(features.indices, id: \.self) { idx in
                let feat = features[idx]
                let stagger = Double(idx) * 0.18
                let p = max(0, min(1, (progress - stagger) * 2.5))
                HStack(spacing: 18) {
                    Image(systemName: feat.symbol)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.white.opacity(0.18)))
                    Text(feat.title)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .opacity(p)
                .offset(x: 60 * (1 - p))
            }
        }
        .padding(.vertical, 60)
    }

    private func closingScene(localT: Double) -> some View {
        let appear = DemoEasing.easeOut(min(1, localT / 0.4))
        // overshoot: 0.6 → 1.12 → 1.0 でバウンド感
        let scale: Double = {
            let p = min(1, localT / 0.6)
            if p < 0.7 {
                return 0.6 + (1.12 - 0.6) * DemoEasing.easeOut(p / 0.7)
            } else {
                return 1.12 - (1.12 - 1.0) * DemoEasing.easeOut((p - 0.7) / 0.3)
            }
        }()
        // 静止後のゆるい breath
        let breath = 1.0 + 0.015 * sin(localT * .pi * 2.0)
        return VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(.white)
            Text("Budgety")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("App Store で公開予定")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .scaleEffect(scale * breath)
        .opacity(appear)
    }
}

// MARK: - 2) Quick Input

struct QuickInputDemoView: View {
    let t: Double
    let tint: Color

    var body: some View {
        ZStack {
            // ベース背景 (時間で僅かに動くグラデ)
            LinearGradient(
                colors: [
                    tint.adjust(by: 0.05),
                    tint.adjust(by: -0.40)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // ふわっとドリフトする光のオーブ (Apple 系の brand 動画によく出る)
            ambientGlow

            VStack {
                topCaption
                    .padding(.top, 40)
                    .opacity(captionOpacity)
                Spacer()
                phoneFrame
                    // 大きいソフトシャドウで奥行き感
                    .shadow(color: .black.opacity(0.30), radius: 60, x: 0, y: 30)
                    .shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 10)
                    .offset(y: -camera.dy)
                    .scaleEffect(camera.scale, anchor: .center)
                    .rotationEffect(.degrees(0.4 * sin(t / 10.0 * .pi * 2)))
                Spacer()
            }

            // 微弱なビネット
            RadialGradient(
                colors: [.clear, .black.opacity(0.18)],
                center: .center,
                startRadius: 600,
                endRadius: 1300
            )
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// 背景のドリフトする光のオーブ 2 つ。位相をずらして互いに追いかけるように。
    private var ambientGlow: some View {
        let phase = t / 10.0
        let dx1 = 200 * sin(phase * .pi * 2)
        let dy1 = 150 * cos(phase * .pi * 2)
        let dx2 = -160 * cos(phase * .pi * 2 + 1.0)
        let dy2 = -200 * sin(phase * .pi * 2 + 0.5)
        return ZStack {
            Circle()
                .fill(tint.adjust(by: 0.30).opacity(0.45))
                .frame(width: 800, height: 800)
                .blur(radius: 180)
                .offset(x: dx1, y: dy1 - 400)
            Circle()
                .fill(tint.adjust(by: -0.10).opacity(0.50))
                .frame(width: 700, height: 700)
                .blur(radius: 160)
                .offset(x: dx2, y: dy2 + 400)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// ズームインしたら caption は引っ込める (邪魔しないため)。
    private var captionOpacity: Double {
        if t < 1.0 {
            return DemoEasing.easeOut(t / 1.0)
        } else if t < 2.4 {
            // 最初のズーム中にゆっくりフェードアウト
            return 1.0 - DemoEasing.easeOut((t - 1.0) / 1.4)
        } else if t < 9.7 {
            return 0.0
        } else {
            // 引きに合わせて再表示
            return DemoEasing.easeOut(min(1, (t - 9.7) / 0.8))
        }
    }

    /// 時刻 t におけるカメラ姿勢 (= フォーカス Y オフセット + ズーム)。
    /// 各キーフレーム間を easeOut で補間。
    /// dy は phone (高さ 1100) の上下中心からのフォーカス位置 (px)。
    private var camera: (dy: Double, scale: Double) {
        // dy は phone (高さ 860, 中心 430) の中心からのフォーカス位置 (px)。
        // 最初のズームをゆっくり (0.5s → 2.5s, 2 秒かけて) 入れて余韻を作る。
        let keys: [(t: Double, dy: Double, scale: Double)] = [
            (0.0,  0,    0.92),
            (0.5,  0,    0.95),  // 全体 + ホールド
            (2.5,  -250, 1.70),  // タイトルへゆっくり入る (2 秒)
            (4.0,  -250, 1.70),  // タイトル維持
            (4.6,  -130, 1.70),  // 金額にパン
            (6.0,  -130, 1.70),  // 金額維持
            (6.6,  +30,  1.55),  // カテゴリ + 提案
            (9.1,  +30,  1.55),  // 維持 (確定アニメ含めゆっくり見せる)
            (9.7,  0,    1.00),  // 全体に戻る
            (10.5, 0,    1.18),  // 保存パンチ
            (11.2, 0,    1.00),  // 落ち着き
            (12.0, 0,    0.94)   // 引き
        ]
        for i in 0..<(keys.count - 1) {
            let a = keys[i]
            let b = keys[i + 1]
            if t >= a.t && t <= b.t {
                let p = (t - a.t) / max(0.001, b.t - a.t)
                // Apple 風: 動き出しと止まり際の両方を滑らかに (easeInOut)。
                let e = DemoEasing.smoothEase(p)
                return (
                    dy: a.dy + (b.dy - a.dy) * e,
                    scale: a.scale + (b.scale - a.scale) * e
                )
            }
        }
        let last = keys.last!
        return (last.dy, last.scale)
    }

    private var topCaption: some View {
        let appear = DemoEasing.easeOut(min(1, t / 0.6))
        return VStack(spacing: 6) {
            Text("クイック記録")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("タイトル → 金額 → 保存")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
        .opacity(appear)
        .offset(y: -8 * (1 - appear))
    }

    private var phoneFrame: some View {
        let titleProgress = DemoEasing.progress(t, from: 2.5, duration: 1.4)
        let amountProgress = DemoEasing.progress(t, from: 4.7, duration: 1.4)
        let suggestAppear = DemoEasing.easeOut(DemoEasing.progress(t, from: 6.6, duration: 0.6))
        let suggestPulse = pulseScale(start: 7.4, peak: 7.8, end: 8.2)
        // 確定瞬間を 0.1s 遅らせて chip exit のフェードを完了させる
        let categoryFilled = t >= 8.3
        let savedAppear = DemoEasing.easeOut(DemoEasing.progress(t, from: 9.6, duration: 0.8))
        // 保存中は フォーム要素をフェードアウトして大きいチェックマークを前面に出す
        let formOpacity = 1.0 - savedAppear
        return RoundedRectangle(cornerRadius: 48)
            .fill(Color.white)
            .frame(width: 620, height: 860)
            .overlay {
                ZStack {
                    formContent(
                        titleProgress: titleProgress,
                        amountProgress: amountProgress,
                        suggestAppear: suggestAppear,
                        suggestPulse: suggestPulse,
                        categoryFilled: categoryFilled
                    )
                    .opacity(formOpacity)

                    // 保存完了の大きいチェックマーク (中央)
                    centerSavedCheck
                        .opacity(savedAppear)
                }
            }
    }

    /// 中央に出る大型のチェックマーク。
    /// 円のガラスが overshoot で出現 → 一拍遅れてチェックマークが stroke 描画。
    private var centerSavedCheck: some View {
        let p = DemoEasing.progress(t, from: 9.6, duration: 0.7)
        let scale: Double = {
            if p < 0.65 {
                return 0.3 + (1.20 - 0.3) * DemoEasing.easeOut(p / 0.65)
            } else {
                return 1.20 - (1.20 - 1.0) * DemoEasing.easeOut((p - 0.65) / 0.35)
            }
        }()
        // 円が出てから少し遅れてチェックを 0.55s で描く
        let drawProgress = DemoEasing.easeOut(
            DemoEasing.progress(t, from: 9.8, duration: 0.55)
        )
        return ZStack {
            // glassEffect は ImageRenderer (書き出し) で再現できないので、
            // ガラス風の見た目 (グラデ + ハイライト + シャドウ) を Circle で代替
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.adjust(by: 0.10), tint.adjust(by: -0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 5
                        )
                )
                .frame(width: 360, height: 360)
                .shadow(color: tint.opacity(0.55), radius: 40, x: 0, y: 8)

            CheckmarkShape()
                .trim(from: 0, to: drawProgress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 38, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 220, height: 220)
        }
        .scaleEffect(scale)
    }

    @ViewBuilder
    private func formContent(
        titleProgress: Double,
        amountProgress: Double,
        suggestAppear: Double,
        suggestPulse: Double,
        categoryFilled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack {
                Text("支出を追加")
                    .font(.system(size: 44, weight: .bold))
                Spacer()
            }
            fieldRow(
                label: "タイトル",
                text: typedText("スーパー", progress: titleProgress),
                showCaret: titleProgress > 0 && titleProgress < 1
            )
            fieldRow(
                label: "金額",
                text: typedText("¥3,420", progress: amountProgress),
                showCaret: amountProgress > 0 && amountProgress < 1
            )
            categoryRow(filled: categoryFilled)
            // 確定直前 (7.9–8.3s) に chip がカテゴリ行に「吸い込まれる」ように縮小 + フェード
            let chipExit = DemoEasing.easeOut(
                DemoEasing.progress(t, from: 7.9, duration: 0.4)
            )
            if suggestAppear > 0 && !categoryFilled {
                suggestionChip
                    .opacity(suggestAppear * (1 - chipExit))
                    .scaleEffect(suggestPulse * (1 - 0.45 * chipExit))
                    .offset(
                        x: 0,
                        y: 18 * (1 - suggestAppear) - 30 * chipExit
                    )
            }
            Spacer()
        }
        .padding(56)
    }

    /// 提案チップ → 選択 → カテゴリ行に流れ込むアニメ用のバウンドスケール。
    private func pulseScale(start: Double, peak: Double, end: Double) -> Double {
        guard t >= start, t <= end else { return 1.0 }
        let mid = peak
        if t <= mid {
            let p = (t - start) / max(0.001, mid - start)
            return 1.0 + 0.10 * p
        } else {
            let p = (t - mid) / max(0.001, end - mid)
            return 1.10 - 0.10 * p
        }
    }

    private var suggestionChip: some View {
        // AI 提案出現中はグローが鼓動
        let glowPhase = max(0, sin((t - 5.0) * .pi * 1.6))
        return HStack(spacing: 14) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .pink, .orange],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: .pink.opacity(0.6 * glowPhase), radius: 14)
                .shadow(color: .purple.opacity(0.4 * glowPhase), radius: 24)
            Text("AI 提案: ")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.orange))
                Text("食費")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.orange.opacity(0.10)))
            .overlay(Capsule().stroke(Color.orange, lineWidth: 2))
            .shadow(color: .orange.opacity(0.35 * glowPhase), radius: 22)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func categoryRow(filled: Bool) -> some View {
        // 確定 (filled=true) になった瞬間からの経過 0...1。ゆっくり 1.2s。
        let confirmP = filled
            ? DemoEasing.progress(t, from: 8.3, duration: 1.2)
            : 0
        // overshoot: 0.4 → 1.15 → 1.0 (smoothEase でゆったり)
        let scale: Double = {
            if confirmP < 0.65 {
                return 0.4 + (1.15 - 0.4) * DemoEasing.smoothEase(confirmP / 0.65)
            } else {
                return 1.15 - (1.15 - 1.0) * DemoEasing.smoothEase((confirmP - 0.65) / 0.35)
            }
        }()
        let opacity = DemoEasing.smoothEase(min(1, confirmP * 1.4))
        // アイコンを軽く回転して着地 (-30° → 0°)
        let iconRotation = -30.0 * (1 - DemoEasing.smoothEase(min(1, confirmP * 1.2)))
        // 確定パルスのリングが外側にゆっくり広がる
        let ringP = filled
            ? DemoEasing.smoothEase(DemoEasing.progress(t, from: 8.3, duration: 1.5))
            : 0

        return VStack(alignment: .leading, spacing: 10) {
            Text("カテゴリ")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if filled {
                    ZStack {
                        // 外側に広がる確定パルス
                        Circle()
                            .stroke(Color.orange.opacity(0.5 * (1 - ringP)), lineWidth: 6)
                            .frame(width: 56, height: 56)
                            .scaleEffect(1.0 + ringP * 1.4)
                        Image(systemName: "fork.knife")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color.orange))
                            .rotationEffect(.degrees(iconRotation))
                    }
                    Text("食費")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .opacity(opacity)
                        .offset(x: 18 * (1 - opacity))
                } else {
                    Text(" ")
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                }
                Spacer()
            }
            .scaleEffect(filled ? scale : 1.0, anchor: .leading)
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(height: 2)
        }
    }

private func typedText(_ full: String, progress: Double) -> String {
        let count = Int(Double(full.count) * progress)
        return String(full.prefix(count))
    }

    private func fieldRow(label: String, text: String, showCaret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if showCaret {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 50)
                        .opacity(caretBlink)
                }
                Spacer()
            }
            Rectangle()
                .fill(Color.gray.opacity(0.25))
                .frame(height: 2)
        }
    }

    private var caretBlink: Double {
        // 0.5 秒周期で点滅 (書き出しは 30fps なので可視)
        let phase = t.truncatingRemainder(dividingBy: 1.0)
        return phase < 0.5 ? 1.0 : 0.0
    }
}

// MARK: - 3) Category Stats

struct CategoryStatsDemoView: View {
    let t: Double
    let tint: Color

    private struct Slice {
        let name: String
        let color: Color
        let value: Double
    }

    private let slices: [Slice] = [
        .init(name: "食費",   color: Color(red: 1.00, green: 0.58, blue: 0.00), value: 32),
        .init(name: "住居",   color: Color(red: 0.36, green: 0.55, blue: 0.94), value: 24),
        .init(name: "交通",   color: Color(red: 0.95, green: 0.30, blue: 0.45), value: 14),
        .init(name: "娯楽",   color: Color(red: 0.69, green: 0.32, blue: 0.87), value: 18),
        .init(name: "その他", color: Color(red: 0.55, green: 0.55, blue: 0.58), value: 12)
    ]

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.99)
                .ignoresSafeArea()
            VStack(spacing: 30) {
                header
                Spacer(minLength: 0)
                pie
                    .scaleEffect(pieScale)
                    .rotationEffect(.degrees(pieRotation))
                Spacer(minLength: 0)
                legend
            }
            .padding(.vertical, 80)
            .padding(.horizontal, 60)
            .scaleEffect(cameraScale, anchor: .center)
        }
    }

    /// 描画進行 + バウンス入りの円グラフスケール。
    private var pieScale: Double {
        let p = DemoEasing.progress(t, from: 0.8, duration: 2.5)
        // 0.7 → 1.08 → 1.0
        if p < 0.7 {
            return 0.7 + (1.08 - 0.7) * DemoEasing.easeOut(p / 0.7)
        } else {
            return 1.08 - (1.08 - 1.0) * DemoEasing.easeOut((p - 0.7) / 0.3)
        }
    }

    /// 描画中に少しだけ回す (動きを出す)。
    private var pieRotation: Double {
        let p = DemoEasing.progress(t, from: 0.8, duration: 2.5)
        return -8 + 8 * DemoEasing.easeOut(p)
    }

    /// 凡例後の盛り上がり〜エンディングでゆっくりズームイン。
    private var cameraScale: Double {
        if t < 4.0 {
            return 1.0
        } else if t < 7.0 {
            // スライスごとに微小なパンチ感
            let p = (t - 4.0) / 3.0
            return 1.0 + 0.02 * sin(p * .pi * 4)
        } else {
            // ラスト 3 秒: 1.0 → 1.06
            return 1.0 + 0.06 * DemoEasing.easeOut((t - 7.0) / 3.0)
        }
    }

    private var header: some View {
        let appear = DemoEasing.easeOut(min(1, t / 0.6))
        return VStack(spacing: 6) {
            Text("カテゴリ別集計")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
            Text("今月の支出: ¥138,400")
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .opacity(appear)
        .offset(y: -8 * (1 - appear))
    }

    private var pie: some View {
        let pieProgress = DemoEasing.easeOut(DemoEasing.progress(t, from: 0.8, duration: 2.5))
        return ZStack {
            ForEach(slices.indices, id: \.self) { i in
                pieSlice(index: i, progress: pieProgress)
            }
            VStack(spacing: 4) {
                Text("¥138,400")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                Text("今月")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 520, height: 520)
    }

    private func pieSlice(index: Int, progress: Double) -> some View {
        let cumBefore = slices[..<index].reduce(0.0) { $0 + $1.value }
        let cumAfter = cumBefore + slices[index].value
        let startFraction = cumBefore / total
        let endFraction = cumAfter / total
        let endAdjusted = startFraction + (endFraction - startFraction) * progress
        // スライスごとのハイライトタイミング: legend が出る前に
        // 4 秒目から 0.3 秒間隔で順番にスライスが「飛び出す」
        let highlightStart = 4.0 + Double(index) * 0.3
        let highlightWindow = DemoEasing.progress(t, from: highlightStart, duration: 0.5)
        // 0 → 1 → 0 のトライアングル波
        let bump = highlightWindow < 0.5
            ? DemoEasing.easeOut(highlightWindow / 0.5)
            : DemoEasing.easeOut((1 - highlightWindow) / 0.5)
        // 中心からスライス中心方向への微小オフセット
        let midAngle = (startFraction + endFraction) / 2.0
        let theta = -90 + 360 * midAngle
        let dx = cos(theta * .pi / 180) * 18 * bump
        let dy = sin(theta * .pi / 180) * 18 * bump
        return PieSliceShape(
            startAngle: .degrees(-90 + 360 * startFraction),
            endAngle:   .degrees(-90 + 360 * endAdjusted)
        )
        .fill(slices[index].color)
        .overlay(
            PieSliceShape(
                startAngle: .degrees(-90 + 360 * startFraction),
                endAngle:   .degrees(-90 + 360 * endAdjusted)
            )
            .stroke(Color.white, lineWidth: 4)
        )
        .offset(x: dx, y: dy)
        .scaleEffect(1.0 + 0.06 * bump)
    }

    private var legend: some View {
        let baseStart = 3.0
        return HStack(spacing: 14) {
            ForEach(slices.indices, id: \.self) { i in
                let p = DemoEasing.easeOut(
                    DemoEasing.progress(t, from: baseStart + Double(i) * 0.18, duration: 0.45)
                )
                VStack(spacing: 6) {
                    Circle().fill(slices[i].color).frame(width: 22, height: 22)
                    Text(slices[i].name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(Int(slices[i].value)) %")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .opacity(p)
                .offset(y: 16 * (1 - p))
            }
        }
    }
}

/// stroke 描画アニメーション用のチェックマーク Path。
/// `.trim(from:to:)` で進行 0 ... 1 を制御する。
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        // 左下 → 中下 → 右上 の 2 線で構成された V 字
        p.move(to: CGPoint(x: w * 0.18, y: h * 0.55))
        p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.78))
        p.addLine(to: CGPoint(x: w * 0.84, y: h * 0.30))
        return p
    }
}

private struct PieSliceShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        p.move(to: center)
        p.addArc(center: center, radius: radius,
                 startAngle: startAngle, endAngle: endAngle, clockwise: false)
        p.closeSubpath()
        return p
    }
}

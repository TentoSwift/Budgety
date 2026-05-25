//
//  MemojiEditorView.swift
//  Budgety
//
//  Memoji / 絵文字 + 背景色でプロフィール画像を作る画面 (iOS 専用)。
//  MemojiView パッケージ (emrearmagan/MemojiView) を使い、円をタップして
//  ミー文字・絵文字を選択。ドラッグで位置を調整でき、背景色は chevron で
//  グリッド展開して多数から選べる。完了すると背景色と合成した正方形アバターを
//  JPEG Data で onDone に返す (= プロフィール写真として書き出して保存)。
//
//  MemojiView は iOS ターゲットにのみリンクされているため、本ファイルは
//  iOS でのみコンパイルされる (Budgety フォルダの新規ファイルは iOS 専用)。
//

import SwiftUI
#if canImport(MemojiView)
import MemojiView
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(MemojiView) && canImport(UIKit)

struct MemojiEditorView: View {
    /// 完了時に (合成済み画像Data, 背景色Hex) を返す。
    var onDone: (Data, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var memojiImage: UIImage? = nil
    @State private var memojiType: MemojiImageType? = nil
    @State private var bgColorHex: String = MemojiEditorView.palette.first ?? "#5B8DEF"
    /// ミー文字の位置調整 (ドラッグ)。
    @State private var memojiOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// ミー文字の拡大縮小 (ピンチ)。
    @State private var memojiScale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    /// 背景色グリッドの展開状態。
    @State private var colorsExpanded: Bool = false

    private let previewSize: CGFloat = 220

    /// 背景色パレット (色相順)。chevron で全色をグリッド表示。
    static let palette: [String] = [
        "#FFE14D", "#FFD23F", "#FFC107", "#FF9F43", "#FF7A45",
        "#FF6B6B", "#FF3B30", "#FF7AA8", "#FF4DA6", "#FF2D9E",
        "#7BE495", "#34C759", "#2BC1A4", "#30B36B", "#1E8E4E",
        "#54D6FF", "#5AC8FA", "#4D9BFF", "#3A7BD5", "#2A52BE",
        "#B388FF", "#9B59B6", "#7C4DFF", "#9B4DCA", "#6A1B9A",
        "#FFFFFF", "#E5E7EB", "#B0B7C0", "#6B7280", "#1C1C1E"
    ]

    private var bgColor: Color { Color(hex: bgColorHex) ?? .gray }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    avatarArea
                    Text(memojiImage == nil
                         ? "タップしてミー文字を選択"
                         : "ドラッグで移動・ピンチで拡大縮小")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    colorSection
                }
                .padding()
            }
            .navigationTitle("Memoji を作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { confirm() } label: { Image(systemName: "checkmark") }
                        .disabled(memojiImage == nil)
                }
            }
        }
    }

    // MARK: - Avatar (Memoji + 背景)

    private var avatarArea: some View {
        ZStack {
            Circle().fill(bgColor.gradient)
            // 表示時に自動でミー文字キーボードを開く。ドラッグで位置調整。
            AutoFocusMemojiView(
                image: $memojiImage,
                memojiType: $memojiType,
                maxLetters: 1,
                textColor: .white
            )
            .padding(34)
            .scaleEffect(memojiScale)
            .offset(memojiOffset)
            // simultaneousGesture: タップ (= 編集) を殺さずにドラッグ移動・ピンチ拡縮。
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        memojiOffset = clampOffset(CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        ))
                    }
                    .onEnded { _ in lastOffset = memojiOffset }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        memojiScale = clampScale(lastScale * value.magnification)
                    }
                    .onEnded { _ in lastScale = memojiScale }
            )
        }
        .frame(width: previewSize, height: previewSize)
        .clipShape(Circle())
    }

    /// ドラッグ位置を円内に収める。
    private func clampOffset(_ s: CGSize) -> CGSize {
        let limit = previewSize * 0.30
        return CGSize(
            width: min(max(s.width, -limit), limit),
            height: min(max(s.height, -limit), limit)
        )
    }

    /// 拡大縮小の範囲を制限する。
    private func clampScale(_ s: CGFloat) -> CGFloat {
        min(max(s, 0.5), 3.0)
    }

    // MARK: - 背景色 (chevron 展開グリッド)

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { colorsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("背景色").font(.title3.weight(.bold))
                    Image(systemName: "chevron.down")
                        .font(.headline.weight(.semibold))
                        .rotationEffect(.degrees(colorsExpanded ? 0 : -90))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if colorsExpanded {
                // 展開時はグリッド。上端から下へ広がるアニメーション。
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                    spacing: 14
                ) {
                    ForEach(Self.palette, id: \.self) { hex in
                        swatch(hex, size: 52)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                // 折りたたみ時は数色を横並びで表示 (スクロールで他の色も選べる)。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Self.palette, id: \.self) { hex in
                            swatch(hex, size: 56)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .clipped()
    }

    private func swatch(_ hex: String, size: CGFloat) -> some View {
        // 塗りは明度を下げる (暗め)。枠線は逆に明るく。
        let fill = brightened(hex, factor: 0.7)
        let isSelected = (bgColorHex == hex)
        // 選択リング + 余白ぶんの外周を常に確保してレイアウトのズレを防ぐ。
        let outer = size + 14
        return Button {
            bgColorHex = hex
        } label: {
            ZStack {
                // 塗りは常に通常サイズ。グラデーションは付けずフラットな色。
                // 枠線はその色を明るくした色 (白系でも縁が見える)。
                Circle()
                    .fill(fill)
                    .overlay(
                        Circle().strokeBorder(brightened(hex, factor: 7.0), lineWidth: 1.5)
                    )
                    .frame(width: size, height: size)
                // 選択中: 塗りは縮めず、少し余白を空けて同色の外側リングを出す。
                if isSelected {
                    Circle()
                        .stroke(fill, lineWidth: 3)
                        .frame(width: size + 10, height: size + 10)
                }
            }
            .frame(width: outer, height: outer)
        }
        .buttonStyle(.plain)
    }

    /// hex の色の brightness に factor を掛けた色を返す (上限1.0)。
    /// 枠線は強め (×7)、塗りは少しだけ (×1.2) など使い分ける。
    private func brightened(_ hex: String, factor: CGFloat) -> Color {
        guard let base = Color(hex: hex) else { return .secondary }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(base).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return Color(UIColor(base))
        }
        return Color(UIColor(hue: h, saturation: s, brightness: min(1, b * factor), alpha: a))
    }

    // MARK: - 書き出し

    @MainActor
    private func confirm() {
        guard let data = renderAvatar() else { dismiss(); return }
        onDone(data, bgColorHex)
        dismiss()
    }

    /// 背景色 (正方形) + Memoji/絵文字 を位置調整込みで合成して JPEG Data にする。
    @MainActor
    private func renderAvatar() -> Data? {
        let side: CGFloat = 240
        let scale = side / previewSize
        let content = ZStack {
            Rectangle().fill(bgColor)
            if let img = memojiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.16)
                    .scaleEffect(memojiScale)
                    .offset(x: memojiOffset.width * scale,
                            y: memojiOffset.height * scale)
            }
        }
        .frame(width: side, height: side)
        .clipped()

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        return renderer.uiImage?.jpegData(compressionQuality: 0.9)
    }
}

// MARK: - 自動でキーボードを開く MemojiView ラッパー

/// パッケージの `MemojiView` (UIKit) をラップし、表示時に自動で
/// ミー文字キーボードを開く (= タップ不要)。内部の UITextView を探して
/// window に入ったら becomeFirstResponder する。
private struct AutoFocusMemojiView: UIViewRepresentable {
    @Binding var image: UIImage?
    @Binding var memojiType: MemojiImageType?
    var maxLetters: Int = 1
    var textColor: UIColor? = .white

    func makeUIView(context: Context) -> MemojiView {
        let view = MemojiView()
        view.isEditable = true
        view.maxLetters = maxLetters
        view.textColor = textColor
        view.onChange = { img, type in
            DispatchQueue.main.async {
                image = img
                memojiType = type
            }
        }
        return view
    }

    func updateUIView(_ uiView: MemojiView, context: Context) {
        uiView.image = image
        guard !context.coordinator.started else { return }
        context.coordinator.started = true
        let coordinator = context.coordinator
        DispatchQueue.main.async { focusWhenReady(uiView, coordinator: coordinator) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var started = false
        var didFocus = false
        var attempts = 0
    }

    /// view が window に入るまで待ってから内部 UITextView を first responder にする。
    private func focusWhenReady(_ view: MemojiView, coordinator: Coordinator) {
        guard !coordinator.didFocus, coordinator.attempts < 25 else { return }
        coordinator.attempts += 1
        if view.window != nil, let tv = Self.findTextView(in: view) {
            coordinator.didFocus = true
            tv.becomeFirstResponder()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusWhenReady(view, coordinator: coordinator)
        }
    }

    private static func findTextView(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }
}

#endif

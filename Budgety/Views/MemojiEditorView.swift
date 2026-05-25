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
    @State private var isEditable: Bool = true
    @State private var bgColorHex: String = MemojiEditorView.palette.first ?? "#5B8DEF"
    /// ミー文字の位置調整 (ドラッグ)。
    @State private var memojiOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
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
                    Text("タップしてミー文字を選択")
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
            // タップで絵文字 / ミー文字キーボードを開き、ドラッグで位置調整。
            MemojiViewRepresentable(
                image: $memojiImage,
                memojiType: $memojiType,
                isEditable: $isEditable,
                maxLetters: 1,
                textColor: .white
            )
            .padding(34)
            .offset(memojiOffset)
            // simultaneousGesture: タップ (= 編集) を殺さずにドラッグで移動。
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

    // MARK: - 背景色 (chevron 展開グリッド)

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { colorsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
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
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                    spacing: 14
                ) {
                    ForEach(Self.palette, id: \.self) { hex in
                        swatch(hex, size: 52)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Self.palette.prefix(8), id: \.self) { hex in
                            swatch(hex, size: 44)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func swatch(_ hex: String, size: CGFloat) -> some View {
        Button {
            bgColorHex = hex
        } label: {
            Circle()
                .fill((Color(hex: hex) ?? .gray).gradient)
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(0.9), lineWidth: bgColorHex == hex ? 3 : 0)
                )
        }
        .buttonStyle(.plain)
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

#endif

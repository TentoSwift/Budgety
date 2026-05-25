//
//  MemojiEditorView.swift
//  Budgety
//
//  Memoji / 絵文字 + 背景色でプロフィール画像を作る画面 (iOS 専用)。
//  MemojiView パッケージ (emrearmagan/MemojiView) を使い、円をタップして
//  ミー文字・絵文字を選択。完了すると背景色と合成した正方形アバターを
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

    /// 背景色パレット。
    static let palette: [String] = [
        "#FF6B6B", "#FF9F43", "#FECA57", "#54D6FF", "#34C759",
        "#5B8DEF", "#AF52DE", "#FF2D55", "#8E8E93"
    ]

    private var bgColor: Color { Color(hex: bgColorHex) ?? .gray }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                avatarArea
                Text("タップしてミー文字を選択")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                colorPicker
                Spacer()
            }
            .padding()
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
            // タップで絵文字 / ミー文字キーボードを開き、選択結果を memojiImage に反映。
            MemojiViewRepresentable(
                image: $memojiImage,
                memojiType: $memojiType,
                isEditable: $isEditable,
                maxLetters: 1,
                textColor: .white
            )
            .padding(34)
        }
        .frame(width: 220, height: 220)
        .contentShape(Circle())
    }

    // MARK: - 背景色

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("背景色")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Self.palette, id: \.self) { hex in
                        Button {
                            bgColorHex = hex
                        } label: {
                            Circle()
                                .fill((Color(hex: hex) ?? .gray).gradient)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle().strokeBorder(.white, lineWidth: bgColorHex == hex ? 3 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 書き出し

    @MainActor
    private func confirm() {
        guard let data = renderAvatar() else { dismiss(); return }
        onDone(data, bgColorHex)
        dismiss()
    }

    /// 背景色 (正方形) + Memoji/絵文字 を合成して JPEG Data にする。
    /// 正方形塗りつぶしなので、円形クリップ表示でも角が透過/黒にならない。
    @MainActor
    private func renderAvatar() -> Data? {
        let side: CGFloat = 240
        let content = ZStack {
            Rectangle().fill(bgColor)
            if let img = memojiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.16)
            }
        }
        .frame(width: side, height: side)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        return renderer.uiImage?.jpegData(compressionQuality: 0.9)
    }
}

#endif

//
//  ImageCropView.swift
//  Budgety
//
//  プロフィール写真などの画像を正方形にトリミングする汎用ビュー (純 SwiftUI)。
//  選択した画像を円形マスクのプレビュー内に表示し、ドラッグで移動・ピンチで
//  拡大縮小して切り取り範囲を決める。決定すると正方形にクロップした UIImage を
//  生成して onCrop に返す (既定 512×512, JPEG)。
//
//  アバターは円形で表示されるため、プレビューは円マスク。ただし実際に書き出すのは
//  その円に外接する正方形領域 (= 円が欠けないよう正方形でクロップ)。
//
//  MemojiEditorView の「ドラッグで移動・ピンチで拡大縮小」の操作感に合わせている。
//  再利用可能なコンポーネントとして作り、適用は ProfileEditView から行う。
//
//  UIKit (UIImage / UIGraphicsImageRenderer) に依存するため iOS/iPadOS 専用。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)

/// 画像を正方形にトリミングするシート。
///
/// - Parameters:
///   - image: 元画像。
///   - outputSize: 書き出す一辺のピクセル数 (既定 512)。
///   - compressionQuality: JPEG 圧縮率 (既定 0.9)。
///   - onCancel: キャンセル時。
///   - onCrop: 決定時。正方形クロップ済みの JPEG Data を返す。
struct ImageCropView: View {
    let image: UIImage
    var outputSize: CGFloat = 512
    var compressionQuality: CGFloat = 0.9
    var onCancel: () -> Void
    var onCrop: (Data) -> Void

    // 現在の変形状態。
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// レイアウト確定前かどうか (最初のフレームで初期倍率を設定する)。
    @State private var didInit = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // クロップ領域は画面幅いっぱいの正方形 (上下に余白)。
                let side = min(geo.size.width, geo.size.height)
                let cropRect = CGRect(
                    x: (geo.size.width - side) / 2,
                    y: (geo.size.height - side) / 2,
                    width: side,
                    height: side
                )
                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        // ベースサイズ = クロップ正方形。scale/offset で操作する。
                        .frame(width: side, height: side)
                        .scaleEffect(scale)
                        .offset(offset)
                        .position(x: cropRect.midX, y: cropRect.midY)
                        .clipped()

                    // 円の外側を暗くするマスク (アバターは円表示)。
                    dimmedOverlay(cropRect: cropRect, in: geo.size)
                        .allowsHitTesting(false)

                    // 円 + 外接正方形のガイド。
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: side, height: side)
                        .position(x: cropRect.midX, y: cropRect.midY)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(side: side))
                .simultaneousGesture(magnifyGesture(side: side))
                .onAppear {
                    previewSide = side
                    guard !didInit else { return }
                    didInit = true
                    scale = baseScale(for: side)
                    lastScale = scale
                }
                .onChange(of: side) { _, newSide in
                    previewSide = newSide
                }
            }
            .navigationTitle("写真を調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定") { confirm() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Overlay

    /// 円の外側を半透明の黒で覆う。
    private func dimmedOverlay(cropRect: CGRect, in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .ignoresSafeArea()
            .overlay {
                Circle()
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    // MARK: - Gestures

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampOffset(
                    CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    ),
                    side: side
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func magnifyGesture(side: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let raw = lastScale * value.magnification
                scale = min(max(raw, baseScale(for: side)), baseScale(for: side) * 6)
                offset = clampOffset(offset, side: side)
            }
            .onEnded { _ in lastScale = scale }
    }

    // MARK: - Clamp

    /// 表示画像がクロップ正方形を隙間なく覆うための最小倍率。
    /// scaledToFill で side×side に収めた時点で既に短辺は side を満たすため 1。
    /// ただし念のため縦横比から算出して 1 未満に落ちないようにする。
    private func baseScale(for side: CGFloat) -> CGFloat {
        // scaledToFill + frame(side,side) の時点で短辺が side を満たすので基準は 1。
        return 1
    }

    /// 画像が正方形からはみ出して空白ができないよう offset をクランプする。
    /// 表示画像の実寸は (side * scale * fillFactor)。scaledToFill で side×side に
    /// 収めた画像の見かけ上の描画サイズは、短辺方向で side、長辺方向で side*(長辺/短辺)。
    private func clampOffset(_ proposed: CGSize, side: CGFloat) -> CGSize {
        let (drawnW, drawnH) = drawnSize(side: side)
        // scale 適用後の実描画サイズ。
        let w = drawnW * scale
        let h = drawnH * scale
        // 正方形 (side) を覆うために許される最大移動量 = (描画サイズ - side)/2。
        let maxX = max(0, (w - side) / 2)
        let maxY = max(0, (h - side) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    /// scaledToFill + frame(side,side) で描画される見かけ上のサイズ (scale 適用前)。
    private func drawnSize(side: CGFloat) -> (CGFloat, CGFloat) {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return (side, side) }
        let aspect = iw / ih
        if aspect >= 1 {
            // 横長: 高さが side に合い、幅がはみ出す。
            return (side * aspect, side)
        } else {
            // 縦長: 幅が side に合い、高さがはみ出す。
            return (side, side / aspect)
        }
    }

    // MARK: - Crop 出力

    /// 現在の表示 transform から元画像上のクロップ矩形を計算し、正方形画像を書き出す。
    private func confirm() {
        let data = renderCropped()
        onCrop(data)
    }

    /// 表示状態を元画像座標に逆写像してクロップし、outputSize の正方形 JPEG を返す。
    ///
    /// 座標系はすべてプレビューの実 side (previewSide) で行う。
    /// 画像は frame(side,side) + scaledToFill で描画されるため、見かけの描画サイズは
    /// drawnSize(side)。それに scale を掛けた w×h が実際に画面に出る大きさ。
    /// クロップ窓 (side×side) は画面中央。画像中心は offset ぶん動いている。
    private func renderCropped() -> Data {
        let side = previewSide > 0 ? previewSide : min(image.size.width, image.size.height)
        let (drawnW, drawnH) = drawnSize(side: side)
        let w = drawnW * scale
        let h = drawnH * scale

        // 描画画像の左上 (画面座標) を原点としたクロップ窓の位置。
        // 描画画像中心は画面中央 + offset にある → 左上は中心 - (w/2, h/2)。
        // クロップ窓左上は画面中央 - (side/2)。両者の差を取る。
        let cropOriginX = (w - side) / 2 - offset.width
        let cropOriginY = (h - side) / 2 - offset.height

        // 元画像の向きを正した CGImage を得てからピクセル空間でクロップする。
        // cgImage は常にピクセル単位なので、描画座標 → ピクセルの係数は
        // (cgImage の実ピクセル幅) / (見かけの描画幅 w)。
        let normalized = image.normalizedUp()
        guard let cg = normalized.cgImage else {
            return normalized.jpegData(compressionQuality: compressionQuality) ?? Data()
        }
        let pxW = CGFloat(cg.width)
        let pxH = CGFloat(cg.height)
        let pxPerDrawX = pxW / w
        let pxPerDrawY = pxH / h

        var srcRect = CGRect(
            x: cropOriginX * pxPerDrawX,
            y: cropOriginY * pxPerDrawY,
            width: side * pxPerDrawX,
            height: side * pxPerDrawY
        )
        // 端数・境界クランプ。
        srcRect.origin.x = min(max(0, srcRect.origin.x), max(0, pxW - srcRect.width))
        srcRect.origin.y = min(max(0, srcRect.origin.y), max(0, pxH - srcRect.height))

        let cropped: UIImage
        if let cgCropped = cg.cropping(to: srcRect.integral) {
            cropped = UIImage(cgImage: cgCropped)
        } else {
            cropped = normalized
        }

        // outputSize の正方形に描き直す。
        let target = CGSize(width: outputSize, height: outputSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let out = renderer.image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: target))
        }
        return out.jpegData(compressionQuality: compressionQuality)
            ?? image.jpegData(compressionQuality: compressionQuality)
            ?? Data()
    }

    // クロップ計算のためにプレビューの実 side (正方形の一辺) を保持する。
    @State private var previewSide: CGFloat = 0
}

// MARK: - UIImage 補助

private extension UIImage {
    /// EXIF などの向き情報を焼き込んで .up に正規化した画像を返す。
    /// これをしないと cgImage.cropping が回転前の生ピクセルに対して行われてズレる。
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

#endif

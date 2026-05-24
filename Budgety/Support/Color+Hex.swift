//
//  Color+Hex.swift
//  Expenso
//

import SwiftUI
#if !os(watchOS)
import CoreImage
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-platform system color shims

extension Color {
    /// iOS の `Color(.systemBackground)` / macOS の `Color(.windowBackgroundColor)` の互換 wrapper。
    /// watchOS には system 色がほぼ無いので一律 `.black` フォールバック。
    static var platformSystemBackground: Color {
        #if os(watchOS)
        return .black
        #elseif canImport(UIKit)
        return Color(.systemBackground)
        #elseif canImport(AppKit)
        return Color(.windowBackgroundColor)
        #else
        return Color(white: 1)
        #endif
    }

    static var platformSecondarySystemBackground: Color {
        #if os(watchOS)
        return Color.gray.opacity(0.15)
        #elseif canImport(UIKit)
        return Color(.secondarySystemBackground)
        #elseif canImport(AppKit)
        return Color(.underPageBackgroundColor)
        #else
        return Color.gray.opacity(0.1)
        #endif
    }

    static var platformSecondarySystemGroupedBackground: Color {
        #if os(watchOS)
        return Color.gray.opacity(0.15)
        #elseif canImport(UIKit)
        return Color(.secondarySystemGroupedBackground)
        #elseif canImport(AppKit)
        return Color(.windowBackgroundColor)
        #else
        return Color.gray.opacity(0.1)
        #endif
    }

    static var platformSystemGroupedBackground: Color {
        #if os(watchOS)
        return .black
        #elseif canImport(UIKit)
        return Color(.systemGroupedBackground)
        #elseif canImport(AppKit)
        return Color(.windowBackgroundColor)
        #else
        return Color.gray.opacity(0.1)
        #endif
    }

    static var platformTertiarySystemBackground: Color {
        #if os(watchOS)
        return Color.gray.opacity(0.2)
        #elseif canImport(UIKit)
        return Color(.tertiarySystemBackground)
        #elseif canImport(AppKit)
        return Color(.controlBackgroundColor)
        #else
        return Color.gray.opacity(0.1)
        #endif
    }

    /// コンテンツ (セル) の上に置くチップ/ピル等の塗り。半透明グレーなので、
    /// ライト/ダークどちらでもセル背景と区別が付く (`*SystemBackground` は
    /// セルと同色になり見えなくなる場合がある)。
    static var platformSecondarySystemFill: Color {
        #if os(watchOS)
        return Color.gray.opacity(0.24)
        #elseif canImport(UIKit)
        return Color(.secondarySystemFill)
        #elseif canImport(AppKit)
        return Color.gray.opacity(0.2)
        #else
        return Color.gray.opacity(0.2)
        #endif
    }

    /// 画像データからドミナント色 (= CIAreaAverage で計算した平均色) を返す。
    /// プロフィール写真からタイル背景の色味を抽出するために使う。
    /// 結果はサイズ・回数あたりのコストがあるので呼び出し側でキャッシュすること。
    static func averageColor(fromImageData data: Data) -> Color? {
        #if os(watchOS)
        return nil
        #else
        let ciImage: CIImage?
        #if canImport(UIKit)
        ciImage = UIImage(data: data).flatMap { CIImage(image: $0) }
        #elseif canImport(AppKit)
        // NSImage → CGImage → CIImage の経路で安定的に取り出す
        if let ns = NSImage(data: data),
           let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ciImage = CIImage(cgImage: cg)
        } else {
            ciImage = nil
        }
        #else
        ciImage = nil
        #endif
        guard let ci = ciImage else { return nil }
        let extent = ci.extent
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Color(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        )
        #endif
    }
}

/// プロフィール写真の平均色を Data ベースでキャッシュする小さなキャッシュ。
/// 同じ写真は何度も描画されるが、CIAreaAverage は毎回計算すると重い。
enum AverageColorCache {
    /// `Data.hashValue` を key にする。NSData の hashValue は内容ハッシュなので
    /// 同じバイト列なら同じキーになる。
    private static var cache: [Int: Color] = [:]

    static func color(for data: Data?) -> Color? {
        guard let data, !data.isEmpty else { return nil }
        let key = data.hashValue
        if let cached = cache[key] { return cached }
        guard let c = Color.averageColor(fromImageData: data) else { return nil }
        cache[key] = c
        return c
    }
}

extension Color {
    /// 文字列から決定的に色を生成。同じ文字列なら常に同じ色を返す。
    /// プロフィール写真未設定時のアバター背景色 (= 名前から自動) に使う。
    /// パレットは Material Design の比較的鮮やかな 14 色からハッシュで選ぶ。
    static func deterministic(from string: String) -> Color {
        let palette: [String] = [
            "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
            "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00",
            "#FF6B6B", "#1DD1A1", "#7D3C98", "#54A0FF",
            "#E84393", "#27AE60"
        ]
        let key = string.trimmingCharacters(in: .whitespaces).isEmpty ? "?" : string
        let hash = abs(key.unicodeScalars.reduce(into: 0) { acc, s in
            acc = acc &* 31 &+ Int(s.value)
        })
        let hex = palette[hash % palette.count]
        return Color(hex: hex) ?? .blue
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

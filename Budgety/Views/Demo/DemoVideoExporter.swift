//
//  DemoVideoExporter.swift
//  Expenso
//
//  `DemoTimeline.frame(at:)` の各タイムスタンプを `ImageRenderer` で
//  CGImage に変換し、`AVAssetWriter` で H.264 MP4 にエンコードする。
//  生成された .mp4 はテンポラリディレクトリに書き出され、共有シートで
//  Photos / Files / AirDrop など好きな場所に保存できる。
//

import SwiftUI
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers

@MainActor
enum DemoVideoExporter {
    enum ExportError: LocalizedError {
        case writerSetup
        case frameRender
        case pixelBuffer
        case finishFailed(String)

        var errorDescription: String? {
            switch self {
            case .writerSetup: String(localized: "ビデオライターの初期化に失敗しました。")
            case .frameRender: String(localized: "フレームの描画に失敗しました。")
            case .pixelBuffer: String(localized: "ピクセルバッファの作成に失敗しました。")
            case .finishFailed(let s): String(localized: "エンコード完了に失敗しました: \(s)")
            }
        }
    }

    /// MP4 を書き出す。`render(t)` は時刻 t (秒) を受けてフレーム View を返す純関数。
    /// `progress` (0...1) はメインスレッドから呼ばれる。
    static func export(
        size: CGSize,
        fps: Int,
        duration: Double,
        fileNameHint: String = "demo",
        render: @escaping (Double) -> AnyView,
        progress: @MainActor @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Budgety-\(fileNameHint)-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttrs
        )

        guard writer.canAdd(input) else { throw ExportError.writerSetup }
        writer.add(input)

        guard writer.startWriting() else { throw ExportError.writerSetup }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(duration * Double(fps)))
        let timescale = CMTimeScale(fps)

        for i in 0..<totalFrames {
            // input のキューが詰まっている時は短く yield する
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let t = Double(i) / Double(fps)
            let view = render(t)
            guard let pixelBuffer = renderPixelBuffer(view: view, size: size) else {
                input.markAsFinished()
                writer.cancelWriting()
                throw ExportError.pixelBuffer
            }
            let pts = CMTime(value: CMTimeValue(i), timescale: timescale)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                input.markAsFinished()
                writer.cancelWriting()
                throw ExportError.frameRender
            }

            if i % max(1, fps / 6) == 0 {
                progress(Double(i + 1) / Double(totalFrames))
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
        progress(1.0)
        return url
    }

    /// 1 フレームを SwiftUI で描画 → CVPixelBuffer に転写。
    /// プレビューと一致させるため Light モード環境で描画する。
    private static func renderPixelBuffer(view: AnyView, size: CGSize) -> CVPixelBuffer? {
        let sized = view
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: sized)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1.0
        guard let cgImage = renderer.cgImage else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        guard let context = CGContext(
            data: base,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}


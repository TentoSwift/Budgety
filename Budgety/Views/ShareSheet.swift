//
//  ShareSheet.swift
//  Expenso
//
//  エクスポート結果をプレビュー → 保存 / 共有させるための SwiftUI ラッパー。
//  - `QuickLookPreview`: QLPreviewController で CSV / PDF を表示。
//    プレビューの右上に共有 / 保存ボタンが組み込みで付くので、追加で
//    UIActivityViewController を出す必要はない。
//  - `ShareSheet`: 旧 API。今も他箇所から使う可能性があるので残す。
//

import SwiftUI
import UIKit
import QuickLook

/// QuickLook で URL の中身をプレビューする画面。
/// PDF は PDFKit ネイティブ表示、CSV は plain text 表示。
/// ナビゲーションバー右上にシステム標準の共有ボタンが付き、「ファイルに保存」
/// 「AirDrop」「印刷」等が選べる。
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { _ in dismiss() }
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// シンプルな UIActivityViewController ラッパー。プレビュー不要で
/// 即共有 sheet を出したい時に使う。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// `.sheet(item:)` 経由で共有 sheet を出すためのラッパー (URL を Identifiable に)。
struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
    /// 表示用 (デバッグやログ用)
    let kind: ExportKind
}

enum ExportKind {
    case csv
    case pdf
}

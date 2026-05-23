//
//  SheetRowInteraction.swift
//  Budgety
//
//  シート一覧の行に UIKit の UIContextMenuInteraction を載せ、
//  「プレビュー（持ち上がった行）のタップで詳細へ遷移」を実現するブリッジ。
//
//  SwiftUI の .contextMenu では、値ベース NavigationLink + メニュー項目ありの場合
//  プレビューのタップが「閉じる」になり、遷移をフックできない。
//  UIContextMenuInteractionDelegate の willPerformPreviewAction を使うことで、
//  プレビュータップ＝コミット（遷移）を実現する。
//

#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// 行に重ねる透明な当たり判定ビュー。タップで `onOpen`、長押しで `makeMenu`、
/// プレビューのタップでも `onOpen` を呼ぶ。
struct SheetRowInteraction: UIViewRepresentable {
    /// 通常タップ & プレビュータップで呼ばれる（= シート詳細を開く）。
    var onOpen: () -> Void
    /// 長押しメニューを生成する（開く度に呼ばれ、最新のロック状態を反映）。
    var makeMenu: () -> UIMenu
    /// プレビューに表示する SwiftUI ビュー。
    var preview: AnyView

    func makeUIView(context: Context) -> RowInteractionView {
        let v = RowInteractionView()
        v.apply(onOpen: onOpen, makeMenu: makeMenu, preview: preview)
        return v
    }

    func updateUIView(_ uiView: RowInteractionView, context: Context) {
        uiView.apply(onOpen: onOpen, makeMenu: makeMenu, preview: preview)
    }

    final class RowInteractionView: UIView, UIContextMenuInteractionDelegate {
        private var onOpen: (() -> Void)?
        private var makeMenu: (() -> UIMenu)?
        private var preview: AnyView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(tap)
            addInteraction(UIContextMenuInteraction(delegate: self))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func apply(onOpen: @escaping () -> Void,
                   makeMenu: @escaping () -> UIMenu,
                   preview: AnyView) {
            self.onOpen = onOpen
            self.makeMenu = makeMenu
            self.preview = preview
        }

        @objc private func handleTap() { onOpen?() }

        // MARK: - UIContextMenuInteractionDelegate

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: { [weak self] in self?.makePreviewController() },
                actionProvider: { [weak self] _ in self?.makeMenu?() ?? UIMenu(children: []) }
            )
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionCommitAnimating
        ) {
            // プレビュー（持ち上がった行）をタップした時にここが呼ばれる。
            // .pop はプレビューが広がって詳細へモーフする演出になるため、
            // .dismiss にしてプレビューを閉じてから通常の push 遷移にする。
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { [weak self] in self?.onOpen?() }
        }

        private func makePreviewController() -> UIViewController? {
            guard let preview else { return nil }
            let host = UIHostingController(rootView: preview)
            host.view.backgroundColor = .clear
            let targetWidth = bounds.width > 1 ? bounds.width : 320
            host.preferredContentSize = host.sizeThatFits(
                in: CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
            )
            return host
        }
    }
}
#endif

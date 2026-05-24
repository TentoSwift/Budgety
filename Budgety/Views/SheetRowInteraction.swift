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
    /// コンテキストメニューの表示/終了を通知（true=表示開始, false=終了開始）。
    /// 表示中は元の行を隠して、プレビューと二重に見えるのを防ぐ。
    var onMenuActiveChange: (Bool) -> Void

    func makeUIView(context: Context) -> RowInteractionView {
        let v = RowInteractionView()
        v.apply(onOpen: onOpen, makeMenu: makeMenu, preview: preview, onMenuActiveChange: onMenuActiveChange)
        return v
    }

    func updateUIView(_ uiView: RowInteractionView, context: Context) {
        uiView.apply(onOpen: onOpen, makeMenu: makeMenu, preview: preview, onMenuActiveChange: onMenuActiveChange)
    }

    final class RowInteractionView: UIView, UIContextMenuInteractionDelegate {
        private var onOpen: (() -> Void)?
        private var makeMenu: (() -> UIMenu)?
        private var preview: AnyView?
        private var onMenuActiveChange: ((Bool) -> Void)?

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
                   preview: AnyView,
                   onMenuActiveChange: @escaping (Bool) -> Void) {
            self.onOpen = onOpen
            self.makeMenu = makeMenu
            self.preview = preview
            self.onMenuActiveChange = onMenuActiveChange
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
            //
            // 遷移を addCompletion（dismiss アニメ完了後）に行うと数百 ms 遅延し、
            // その隙に一覧の別シートをタップできてしまう。即座に onOpen を呼べば
            // すぐ詳細が push され一覧が覆われるので、誤タップを防げる。
            animator.preferredCommitStyle = .dismiss
            onOpen?()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            // メニュー表示開始 → 元の行を隠す（プレビューと二重表示にしない）。
            DispatchQueue.main.async { [weak self] in self?.onMenuActiveChange?(true) }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            // メニュー終了開始 → 元の行を戻す。
            DispatchQueue.main.async { [weak self] in self?.onMenuActiveChange?(false) }
        }

        private func makePreviewController() -> UIViewController? {
            guard let preview else { return nil }
            let host = UIHostingController(rootView: preview)
            // ロック表示など中身が小さいプレビューでも透けないよう、不透明な
            // システム背景を敷く（システムが角丸にクリップするのでカード状になる）。
            host.view.backgroundColor = .systemBackground
            let targetWidth = bounds.width > 1 ? bounds.width : 320
            var size = host.sizeThatFits(
                in: CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
            )
            // SheetDetailView など背の高いプレビューが画面いっぱいにならないよう上限。
            let maxHeight: CGFloat = 540
            size.width = targetWidth
            size.height = (size.height.isFinite && size.height > 1)
                ? min(size.height, maxHeight) : maxHeight
            host.preferredContentSize = size
            return host
        }
    }
}
#endif

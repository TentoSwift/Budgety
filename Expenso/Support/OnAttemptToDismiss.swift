//
//  OnAttemptToDismiss.swift
//  Expenso
//
//  SwiftUI のシートで、ユーザーがスワイプダウンや背景タップで閉じようと
//  した瞬間を検知するための UIKit ブリッジ。
//
//  `.interactiveDismissDisabled(true)` だけだと「閉じる操作を無効化する」
//  しかできず、ユーザーの試みをフックできないので、
//  `UIAdaptivePresentationControllerDelegate` の
//  `presentationControllerShouldDismiss(_:)` に橋渡しして、
//  `shouldAllowDismiss` が false の時だけ `onAttempt` を呼び出す。
//

import SwiftUI
import UIKit

extension View {
    /// シートを閉じようとする操作 (スワイプダウン / 背景タップ) をフックする。
    /// `shouldAllowDismiss` が true の間は通常通り閉じる。
    /// false の時は閉じる操作をブロックして `onAttempt` を呼ぶ。
    func onAttemptToDismiss(
        shouldAllowDismiss: @escaping () -> Bool,
        onAttempt: @escaping () -> Void
    ) -> some View {
        background(
            AttemptToDismissView(
                shouldAllowDismiss: shouldAllowDismiss,
                onAttempt: onAttempt
            )
            .frame(width: 0, height: 0)
        )
    }
}

private struct AttemptToDismissView: UIViewControllerRepresentable {
    let shouldAllowDismiss: () -> Bool
    let onAttempt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(host: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        DispatchQueue.main.async { [weak vc] in
            attachDelegate(from: vc, to: context.coordinator)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.host = self
        DispatchQueue.main.async { [weak uiViewController] in
            attachDelegate(from: uiViewController, to: context.coordinator)
        }
    }

    /// `vc` から親をたどって `presentingViewController != nil` の VC
    /// (= 実際にシートとして提示されているホスト) を見つけ、その
    /// `presentationController.delegate` を Coordinator に差し替える。
    /// 元の delegate (SwiftUI が `dismiss()` バインディング更新のために
    /// セットしているもの) は Coordinator が forwarding で参照する。
    private func attachDelegate(from vc: UIViewController?, to coordinator: Coordinator) {
        guard let vc else { return }
        if let host = sheetHost(from: vc) {
            install(on: host, coordinator: coordinator)
        } else {
            DispatchQueue.main.async { [weak vc] in
                guard let vc, let host = sheetHost(from: vc) else { return }
                install(on: host, coordinator: coordinator)
            }
        }
    }

    private func install(on host: UIViewController, coordinator: Coordinator) {
        guard let pc = host.presentationController else { return }
        // すでに自分が刺さっているなら何もしない (再 update での無限ループ防止)
        if pc.delegate === coordinator { return }
        coordinator.originalDelegate = pc.delegate
        pc.delegate = coordinator
    }

    /// 親チェーンを上がって、`presentingViewController != nil` の VC を返す。
    private func sheetHost(from vc: UIViewController) -> UIViewController? {
        var current: UIViewController? = vc
        while let c = current {
            if c.presentingViewController != nil { return c }
            current = c.parent
        }
        return nil
    }

    /// SwiftUI が `.sheet` 用に元から差している delegate を踏みつぶさないように、
    /// 我々が処理しないメソッドは ObjC forwarding で素通しする。
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var host: AttemptToDismissView
        weak var originalDelegate: UIAdaptivePresentationControllerDelegate?

        init(host: AttemptToDismissView) { self.host = host }

        // `isModalInPresentation == true` (= interactiveDismissDisabled) で
        // スワイプがブロックされた時に呼ばれるフック。ここで確認ダイアログを出す。
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if !host.shouldAllowDismiss() {
                host.onAttempt()
            }
            originalDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
        }

        // `interactiveDismissDisabled(false)` だった場合のフェイルセーフ。
        // shouldDismiss を返すことでスワイプ自体もブロックできる。
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            if !host.shouldAllowDismiss() {
                host.onAttempt()
                return false
            }
            return originalDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true
        }

        // 以下、明示的に元 delegate に転送するメソッド (SwiftUI が isPresented
        // バインディングを更新するために使っているもの)。
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            originalDelegate?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            originalDelegate?.presentationControllerDidDismiss?(presentationController)
        }

        // それ以外のメソッドはまるごと元 delegate に投げる。
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            originalDelegate
        }
    }
}

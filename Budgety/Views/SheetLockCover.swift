//
//  SheetLockCover.swift
//  Budgety
//
//  ロック対象シート (パスワードあり & 未解錠) の画面に SheetLockView を全画面で
//  重ねるモディファイア。バックグラウンド復帰などで再ロックされても、詳細/精算/
//  編集などの「今いる画面」を閉じずにロックだけを重ね、解除すると元の画面に戻る
//  (= 場所を保つ)。
//
//  解錠状態 (SheetLockManager) を直接バインディングにするので、再ロック → 表示、
//  解錠 → 自動的に閉じる、が状態だけで完結する (@State 不要・ちらつきなし)。
//

import SwiftUI

private struct SheetLockCoverModifier: ViewModifier {
    let record: ExpenseSheet?
    @ObservedObject private var lockManager = SheetLockManager.shared
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.lockPresentation(
            // get がロック状態を反映するので、解錠されれば自動的に閉じる。
            isPresented: Binding(get: { isLocked }, set: { _ in })
        ) {
            if let record {
                SheetLockView(
                    record: record,
                    onUnlock: { /* isUnlocked の変化で自動的に閉じる */ },
                    onCancel: { dismiss() }
                )
            }
        }
    }

    /// パスワード設定済みで未解錠なら true (isUnlocked はパスワード無しを true 扱い)。
    private var isLocked: Bool {
        guard let record else { return false }
        return !lockManager.isUnlocked(record)
    }
}

private extension View {
    /// ロック画面の提示。iOS は全画面を覆う fullScreenCover、macOS は sheet
    /// (fullScreenCover は macOS 非対応)。
    @ViewBuilder
    func lockPresentation<C: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        #if os(macOS)
        self.sheet(isPresented: isPresented, content: content)
        #else
        self.fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
}

extension View {
    /// `record` がロック対象 (パスワードあり & 未解錠) の間、SheetLockView を
    /// 全画面で重ねる。解除すると元の画面に戻る。
    func sheetLockCover(_ record: ExpenseSheet?) -> some View {
        modifier(SheetLockCoverModifier(record: record))
    }
}

//
//  DynamicTextView.swift
//  Expenso
//
//  UITextView ベースで Dynamic Type に追従しながら自動行数調整するテキスト入力。
//  Enter キーで改行を入れずに `onSubmit` を発火し、フォーカスを外す挙動を持つ。
//

import SwiftUI
import UIKit

struct DynamicTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focus: Bool
    var placeholder: String = ""
    var font: UIFont = .systemFont(ofSize: 17)
    /// キーボード種別。金額入力では `.decimalPad` / `.numberPad` を指定する。
    var keyboardType: UIKeyboardType = .default
    /// 数字キーボード等に「次へ」アクセサリを出して次のフィールドへ送る。
    /// 設定すると inputAccessoryView (ツールバー) にボタンを表示する。
    var accessoryNextTitle: String? = nil
    var onAccessoryNext: (() -> Void)? = nil
    /// true のとき、空のフィールドで delete を押すとキーボードを閉じる
    /// (数字入力で「もう入れない」時に戻れるようにする)。
    var dismissOnDeleteWhenEmpty: Bool = false
    /// Enter (改行) が入力された時に呼ばれる。フォーカスは内部で外される。
    var onSubmit: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator

        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isUserInteractionEnabled = true

        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.font = UIFontMetrics.default.scaledFont(for: font)
        textView.adjustsFontForContentSizeCategory = true
        textView.keyboardType = keyboardType

        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = .zero

        // 「次へ」アクセサリ (数字キーボードには Return が無いため、これで次のフィールドへ)。
        if let title = accessoryNextTitle {
            let bar = UIToolbar()
            bar.sizeToFit()
            let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            let next = UIBarButtonItem(title: title, style: .done,
                                       target: context.coordinator,
                                       action: #selector(Coordinator.accessoryNextTapped))
            bar.items = [flex, next]
            textView.inputAccessoryView = bar
        }

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // クロージャ等を最新の値に保つ (アクセサリ・onSubmit の stale 参照を防ぐ)。
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        // Dynamic Type / アクセシビリティサイズ変更への追従
        uiView.font = UIFontMetrics.default.scaledFont(for: font)

        // SwiftUI → UIKit のフォーカス制御
        if focus && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !focus && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: DynamicTextView

        init(_ parent: DynamicTextView) {
            self.parent = parent
        }

        @objc func accessoryNextTapped() {
            parent.onAccessoryNext?()
        }

        // UIKit → SwiftUI のフォーカス同期
        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.focus = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.focus = false
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n" {
                // Enter が押された: 改行は入れずに submit を発火しフォーカスを外す
                textView.resignFirstResponder()
                parent.focus = false
                parent.onSubmit?()
                return false
            }
            // 空のフィールドで delete (= replacementText が空 & 削除対象なし) を押したら
            // キーボードを閉じる。dismissOnDeleteWhenEmpty が true の時のみ。
            if parent.dismissOnDeleteWhenEmpty,
               text.isEmpty, range.length == 0, textView.text.isEmpty {
                textView.resignFirstResponder()
                parent.focus = false
                return false
            }
            return true
        }
    }
}

/// プレースホルダーを `.background` で重ねる便利ラッパー。
struct DynamicTextField: View {
    @Binding var text: String
    @Binding var focus: Bool
    var placeholder: String
    var font: UIFont = .systemFont(ofSize: 17)
    var keyboardType: UIKeyboardType = .default
    var accessoryNextTitle: String? = nil
    var onAccessoryNext: (() -> Void)? = nil
    var dismissOnDeleteWhenEmpty: Bool = false
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        DynamicTextView(
            text: $text,
            focus: $focus,
            placeholder: placeholder,
            font: font,
            keyboardType: keyboardType,
            accessoryNextTitle: accessoryNextTitle,
            onAccessoryNext: onAccessoryNext,
            dismissOnDeleteWhenEmpty: dismissOnDeleteWhenEmpty,
            onSubmit: onSubmit
        )
        .background(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(Color(uiColor: .placeholderText))
                    .allowsHitTesting(false)
            }
        }
    }
}

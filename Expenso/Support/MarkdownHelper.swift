//
//  MarkdownHelper.swift
//  Expenso
//
//  ランタイム文字列を SwiftUI で Markdown 描画するためのヘルパー。
//  `Text(LocalizedStringKey)` 経由の暗黙パースは compile-time 文字列でしか働かないため、
//  AI 応答などランタイム生成テキストは AttributedString で明示的にパースする。
//

import Foundation

extension String {
    /// `**太字**` などの Markdown を AttributedString として返す。
    /// Apple の `AttributedString(markdown:)` は CJK と非空白記号 (`-`, `%`, `¥` 等) が
    /// `**` の直後/直前に来るケースで強調を認識しないことがあるため、自前で
    /// 正規表現ベースに `**…**` を太字に変換する。それ以外は素のテキスト扱い。
    var asAttributedMarkdown: AttributedString {
        let pattern = #/\*\*(.+?)\*\*/#
        var result = AttributedString()
        var cursor = self.startIndex
        for match in self.matches(of: pattern) {
            let plain = String(self[cursor..<match.range.lowerBound])
            if !plain.isEmpty {
                result += AttributedString(plain)
            }
            var bold = AttributedString(String(match.output.1))
            bold.inlinePresentationIntent = .stronglyEmphasized
            result += bold
            cursor = match.range.upperBound
        }
        let tail = String(self[cursor...])
        if !tail.isEmpty {
            result += AttributedString(tail)
        }
        return result
    }
}

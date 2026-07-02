//
//  LinkDetection.swift
//  Budgety
//
//  ランタイム文字列 (メモ等) の中の URL を検出して、SwiftUI の Text で
//  タップ可能なリンクとして描画するためのヘルパー。
//  NSDataDetector(.link) で http/https/www. を検出し、AttributedString の
//  該当範囲に `.link` 属性 (+ 控えめな下線 / tint) を付与する。
//  URL 以外の部分は素のテキストのまま維持する。
//

import Foundation
import SwiftUI

extension String {
    /// 文字列中の URL を検出し、リンク属性を付けた `AttributedString` を返す。
    ///
    /// - http/https の URL に加え、`www.` 始まりも NSDataDetector が検出する。
    ///   後者はスキームが無いため `https://` を補って `.link` に設定する。
    /// - URL 部分には `.link` / `.underlineStyle(.single)` を付与し、色は
    ///   ビュー側の tint (アクセントカラー) に従う。
    /// - URL が無い / 空文字の場合は、装飾なしの素の `AttributedString` を返すため
    ///   従来と同じ見た目になる。
    var attributedWithDetectedLinks: AttributedString {
        var attributed = AttributedString(self)

        guard !self.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }

        let nsString = self as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = detector.matches(in: self, options: [], range: fullRange)

        for match in matches {
            guard match.resultType == .link,
                  let url = match.url,
                  let swiftRange = Range(match.range, in: self),
                  let attrRange = Range(swiftRange, in: attributed) else {
                continue
            }
            attributed[attrRange].link = url
            attributed[attrRange].underlineStyle = .single
        }

        return attributed
    }
}

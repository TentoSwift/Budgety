//
//  Member+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI

extension Member {
    var displayName: String { name?.isEmpty == false ? name! : "メンバー" }
    var displayColorHex: String { colorHex ?? "#5B8DEF" }
    var tint: Color { Color(hex: displayColorHex) ?? .blue }

    /// 名前の先頭 1 文字。アバター画像が無い時のフォールバックとして表示する。
    var initial: String {
        guard let first = displayName.first else { return "?" }
        return String(first)
    }
}

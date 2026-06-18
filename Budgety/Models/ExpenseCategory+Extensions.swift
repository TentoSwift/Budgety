//
//  ExpenseCategory+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI

extension ExpenseCategory {
    var displayName: String { name?.isEmpty == false ? name! : String(localized: "カテゴリなし") }
    var displayColorHex: String { colorHex ?? "#888888" }
    var displaySymbol: String { symbol?.isEmpty == false ? symbol! : "tag.slash" }
    var tint: Color { Color(hex: displayColorHex) ?? .gray }

    /// このカテゴリの種別 (支出 / 収入)。デフォルトは支出。
    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw ?? "") ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}

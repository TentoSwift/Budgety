//
//  TransactionKind.swift
//  Expenso
//

import Foundation
import SwiftUI

enum TransactionKind: String, CaseIterable, Identifiable {
    case expense
    case income

    var id: String { rawValue }

    var label: String {
        switch self {
        case .expense: String(localized: "支出")
        case .income: String(localized: "収入")
        }
    }

    var symbol: String {
        switch self {
        case .expense: "arrow.down.circle.fill"
        case .income: "arrow.up.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .expense: .red
        case .income: .green
        }
    }

    /// 表示用の符号付き金額。支出は負、収入は正。
    func signedAmount(_ value: Decimal) -> Decimal {
        switch self {
        case .expense: -value
        case .income: value
        }
    }

    /// 「支払者」「受取者」相当のラベル (種別に応じて切替)
    var partyLabel: String {
        switch self {
        case .expense: String(localized: "支払")
        case .income:  String(localized: "受取")
        }
    }

    /// Picker のナビゲーションタイトル等
    var partySelectionTitle: String {
        String(localized: "\(partyLabel)を選択")
    }
}

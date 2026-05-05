//
//  Expense+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI

extension Expense {
    var displayTitle: String { title ?? "" }
    var displayPaidBy: String { resolvedPayer?.displayName ?? (paidBy ?? "") }
    var payerTint: Color { resolvedPayer?.tint ?? .secondary }
    /// Avatar 用: 解決できた Member の写真 (なければ nil → AvatarView がイニシャル文字で fallback)
    var payerPhotoData: Data? { resolvedPayer?.photoData }

    /// `paidBy` の名前と一致するローカル `Member` を返す。Member は Private ストアのみに存在するため、
    /// Shared ストアの Expense (他人のシート) では nil を返し、表示は `paidBy` 文字列にフォールバックする。
    var resolvedPayer: Member? {
        guard let name = paidBy, !name.isEmpty else { return nil }
        let pc = PersistenceController.shared
        let ctx = managedObjectContext ?? pc.container.viewContext
        // Shared ストアの Expense は他アカウントの paidBy を持ちうるため、自前 Member での解決を避ける
        if !objectID.isTemporaryID,
           let store = ctx.persistentStoreCoordinator?.persistentStore(for: objectID.uriRepresentation()),
           store == pc.sharedStore {
            return nil
        }
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.predicate = NSPredicate(format: "name == %@", name)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    var amountDecimal: Decimal {
        get { (amount ?? 0) as Decimal }
        set { amount = NSDecimalNumber(decimal: newValue) }
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw ?? "") ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// 通貨コード (空なら親シートの既定 → JPY)
    var resolvedCurrencyCode: String {
        if let c = currencyCode, !c.isEmpty { return c }
        if let s = sheet?.resolvedDefaultCurrencyCode, !s.isEmpty { return s }
        return CurrencyCatalog.defaultCode
    }

    /// 通貨記号付きの金額表示 (符号は kind に応じて変える呼び出し元で扱う)
    var formattedAmount: String {
        CurrencyCatalog.format(amountDecimal, code: resolvedCurrencyCode)
    }

    /// 符号付き表示 (収入は正、支出は負として表現)
    var formattedSignedAmount: String {
        let sign = kind == .expense ? "-" : "+"
        return sign + formattedAmount
    }

    var categoryDisplayName: String {
        category?.displayName ?? (categoryRaw?.isEmpty == false ? categoryRaw! : "未分類")
    }

    var categoryTint: Color {
        category?.tint ?? .gray
    }

    var categorySymbol: String {
        category?.displaySymbol ?? "ellipsis.circle"
    }
}

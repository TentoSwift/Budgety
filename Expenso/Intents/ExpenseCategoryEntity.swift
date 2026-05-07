//
//  ExpenseCategoryEntity.swift
//  Expenso
//
//  AppIntents で「カテゴリ」を選ぶための AppEntity ラッパー。
//  Core Data の `ExpenseCategory` を objectID URI で安定識別する。
//  Shortcuts 編集時にユーザーが任意で選べるようにし、未指定なら
//  FoundationModels で推測する経路に流す。
//

import AppIntents
import CoreData
import UIKit
import SwiftUI

struct ExpenseCategoryEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "カテゴリ")
    }
    static var defaultQuery = ExpenseCategoryEntityQuery()

    var id: String
    var name: String
    var sheetName: String
    var kindRaw: String
    var symbol: String
    var colorHex: String
    /// カテゴリの色付き SF Symbol を事前にラスタライズした PNG データ。
    /// `displayRepresentation` から毎回呼ばれるたびに描画するのを避けるため pre-render する。
    var iconData: Data?

    var displayRepresentation: DisplayRepresentation {
        let image: DisplayRepresentation.Image? = {
            if let data = iconData { return DisplayRepresentation.Image(data: data) }
            return DisplayRepresentation.Image(systemName: symbol)
        }()
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(sheetName)",
            image: image
        )
    }
}

struct ExpenseCategoryEntityQuery: EntityQuery {
    @MainActor
    func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        let ctx = PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<ExpenseCategory>(entityName: "ExpenseCategory")
        req.sortDescriptors = [
            NSSortDescriptor(keyPath: \ExpenseCategory.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \ExpenseCategory.createdAt, ascending: true)
        ]
        // 支出カテゴリのみを候補として表示 (= AddExpenseIntent は支出専用)
        req.predicate = NSPredicate(format: "kindRaw == %@ OR kindRaw == nil OR kindRaw == ''",
                                    TransactionKind.expense.rawValue)
        let cats = (try? ctx.fetch(req)) ?? []
        return cats.map { ExpenseCategoryEntity.from($0) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExpenseCategoryEntity] {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext
        var result: [ExpenseCategoryEntity] = []
        for idStr in identifiers {
            guard let url = URL(string: idStr),
                  let oid = pc.container.persistentStoreCoordinator
                    .managedObjectID(forURIRepresentation: url),
                  let cat = try? ctx.existingObject(with: oid) as? ExpenseCategory
            else { continue }
            result.append(ExpenseCategoryEntity.from(cat))
        }
        return result
    }
}

extension ExpenseCategoryEntity {
    @MainActor
    static func from(_ cat: ExpenseCategory) -> ExpenseCategoryEntity {
        let colorHex = cat.displayColorHex
        // 通常のカテゴリは subtitle を空 (= シート名は表示しない)
        return ExpenseCategoryEntity(
            id: cat.objectID.uriRepresentation().absoluteString,
            name: cat.displayName,
            sheetName: "",
            kindRaw: cat.kindRaw ?? TransactionKind.expense.rawValue,
            symbol: cat.displaySymbol,
            colorHex: colorHex,
            iconData: renderColoredSymbol(cat.displaySymbol, colorHex: colorHex)
        )
    }

    /// SF Symbol を `colorHex` の色で描画して PNG Data を返す。
    /// 失敗時は nil (= displayRepresentation で systemName フォールバック)。
    @MainActor
    static func renderColoredSymbol(_ name: String, colorHex: String) -> Data? {
        let color = UIColor(Color(hex: colorHex) ?? .blue)
        let cfg = UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: cfg) else { return nil }
        return symbol.withTintColor(color, renderingMode: .alwaysOriginal).pngData()
    }

    /// AI 提案用: カテゴリのカラー symbol + apple.intelligence を横並びで合成して PNG Data を返す。
    @MainActor
    static func renderAISuggestionSymbol(_ name: String, colorHex: String) -> Data? {
        let color = UIColor(Color(hex: colorHex) ?? .blue)
        let mainCfg = UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
        let aiCfg = UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold)

        guard let main = UIImage(systemName: name, withConfiguration: mainCfg)?
            .withTintColor(color, renderingMode: .alwaysOriginal),
              let ai = UIImage(systemName: "apple.intelligence", withConfiguration: aiCfg)?
                .withTintColor(.systemPurple, renderingMode: .alwaysOriginal)
        else { return renderColoredSymbol(name, colorHex: colorHex) }

        let gap: CGFloat = 12
        let canvasW = main.size.width + gap + ai.size.width
        let canvasH = max(main.size.height, ai.size.height)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))
        let composed = renderer.image { _ in
            main.draw(at: CGPoint(x: 0, y: (canvasH - main.size.height) / 2))
            ai.draw(at: CGPoint(x: main.size.width + gap, y: (canvasH - ai.size.height) / 2))
        }
        return composed.pngData()
    }
}

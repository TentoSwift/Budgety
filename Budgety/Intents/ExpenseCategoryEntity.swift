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
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
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
    /// AddExpenseIntent で選択中のシートに依存する。シートが選ばれていれば、その
    /// シートのカテゴリだけを候補にする (シート間で同名カテゴリが重複しないように)。
    @IntentParameterDependency<AddExpenseIntent>(\.$sheet)
    var addExpense

    @MainActor
    func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext
        let req = NSFetchRequest<ExpenseCategory>(entityName: "ExpenseCategory")
        req.sortDescriptors = [
            NSSortDescriptor(keyPath: \ExpenseCategory.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \ExpenseCategory.createdAt, ascending: true)
        ]
        // 支出カテゴリのみを候補として表示 (= AddExpenseIntent は支出専用)
        var predicates = [NSPredicate(format: "kindRaw == %@ OR kindRaw == nil OR kindRaw == ''",
                                      TransactionKind.expense.rawValue)]
        // シートが選択済みなら、そのシートのカテゴリだけに絞る。
        if let sheetEntity = addExpense?.sheet,
           let url = URL(string: sheetEntity.id),
           let oid = pc.container.persistentStoreCoordinator
            .managedObjectID(forURIRepresentation: url),
           let sheet = try? ctx.existingObject(with: oid) as? ExpenseSheet {
            predicates.append(NSPredicate(format: "sheet == %@", sheet))
        }
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let cats = (try? ctx.fetch(req)) ?? []
        // 先頭に「AI 提案」、末尾に「未分類」sentinel を追加 (どちらも選択肢として出す)
        return [ExpenseCategoryEntity.aiSuggestionEntity()]
            + cats.map { ExpenseCategoryEntity.from($0) }
            + [ExpenseCategoryEntity.skipEntity()]
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExpenseCategoryEntity] {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext
        var result: [ExpenseCategoryEntity] = []
        for idStr in identifiers {
            // AI 提案 sentinel: そのまま返す
            if idStr == ExpenseCategoryEntity.aiSuggestionSentinelID {
                result.append(ExpenseCategoryEntity.aiSuggestionEntity())
                continue
            }
            // 未分類 sentinel: そのまま返す
            if idStr == AddExpenseIntent.skipCategoryID {
                result.append(ExpenseCategoryEntity.skipEntity())
                continue
            }
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
    /// 「AI 提案」を表す sentinel id。`AddExpenseIntent` 内で特殊判定する。
    static let aiSuggestionSentinelID = "__expenso_ai_suggestion__"

    /// Shortcut のカテゴリ選択肢に並べる「AI 提案」項目。
    @MainActor
    static func aiSuggestionEntity() -> ExpenseCategoryEntity {
        let purple = "#AF52DE"
        return ExpenseCategoryEntity(
            id: aiSuggestionSentinelID,
            name: String(localized: "AI 提案"),
            sheetName: String(localized: "タイトルから自動推測"),
            kindRaw: TransactionKind.expense.rawValue,
            symbol: "apple.intelligence",
            colorHex: purple,
            iconData: renderColoredSymbol("apple.intelligence", colorHex: purple)
        )
    }

    /// Shortcut のカテゴリ選択肢に並べる「未分類」項目 (= カテゴリなしで保存)。
    @MainActor
    static func skipEntity() -> ExpenseCategoryEntity {
        let gray = "#8E8E93"
        return ExpenseCategoryEntity(
            id: AddExpenseIntent.skipCategoryID,
            name: String(localized: "カテゴリなし"),
            sheetName: String(localized: "カテゴリなしで保存"),
            kindRaw: "",
            symbol: "tag.slash",
            colorHex: gray,
            iconData: renderColoredSymbol("tag.slash", colorHex: gray)
        )
    }

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

    #if canImport(UIKit)
    /// CategoryIconView と同じ見た目 (= カテゴリ色のグラデ円 + 白の SF Symbol) を
    /// PNG Data として返す。
    @MainActor
    static func renderColoredSymbol(_ name: String, colorHex: String) -> Data? {
        renderBadge(symbol: name, colorHex: colorHex)
    }

    /// AI 提案用: 「色付き円 + 白 symbol」バッジの右下に apple.intelligence を
    /// 重ねて合成した PNG Data を返す。
    @MainActor
    static func renderAISuggestionSymbol(_ name: String, colorHex: String) -> Data? {
        let badgeSize: CGFloat = 96
        guard let badge = renderBadgeImage(symbol: name, colorHex: colorHex, size: badgeSize)
        else { return renderColoredSymbol(name, colorHex: colorHex) }

        // バッジ径の 50% で右下にオーバーレイ。白い縁取りで「ステッカー」風にする。
        let aiSize: CGFloat = badgeSize * 0.50
        let aiCfg = UIImage.SymbolConfiguration(pointSize: aiSize * 0.78, weight: .semibold)
        guard let ai = UIImage(systemName: "apple.intelligence", withConfiguration: aiCfg)?
            .withTintColor(.systemPurple, renderingMode: .alwaysOriginal)
        else { return badge.pngData() }

        // overlap させたいので少しはみ出させる。
        let overlap: CGFloat = aiSize * 0.18
        let canvas = CGSize(width: badgeSize + overlap, height: badgeSize + overlap)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { ctx in
            // バッジ本体を左上に。
            badge.draw(at: .zero)

            // 右下に白い円 (= ステッカーの縁) を描画。
            let stickerRect = CGRect(
                x: canvas.width - aiSize,
                y: canvas.height - aiSize,
                width: aiSize,
                height: aiSize
            )
            ctx.cgContext.saveGState()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: stickerRect).fill()
            ctx.cgContext.restoreGState()

            // 白円の中央に apple.intelligence を載せる。
            let aiOrigin = CGPoint(
                x: stickerRect.midX - ai.size.width  / 2,
                y: stickerRect.midY - ai.size.height / 2
            )
            ai.draw(at: aiOrigin)
        }.pngData()
    }

    /// 「色付き円 + 白 symbol」バッジを `UIImage` として描画。
    @MainActor
    private static func renderBadgeImage(symbol: String, colorHex: String, size: CGFloat = 96) -> UIImage? {
        let color = UIColor(Color(hex: colorHex) ?? .blue)
        let cfg = UIImage.SymbolConfiguration(pointSize: size * 0.45, weight: .semibold)
        guard let symbolImg = UIImage(systemName: symbol, withConfiguration: cfg)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        else { return nil }

        let canvas = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { ctx in
            // SwiftUI の Color.gradient と同じ感覚で、上が明るく下が暗いグラデ円。
            let cg = ctx.cgContext
            cg.saveGState()
            cg.addEllipse(in: CGRect(origin: .zero, size: canvas))
            cg.clip()
            let lighter = color.adjustingBrightness(by: 0.10)
            let darker  = color.adjustingBrightness(by: -0.10)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [lighter.cgColor, darker.cgColor] as CFArray,
                locations: [0.0, 1.0]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: canvas.width / 2, y: 0),
                    end:   CGPoint(x: canvas.width / 2, y: canvas.height),
                    options: []
                )
            } else {
                color.setFill()
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: canvas)).fill()
            }
            cg.restoreGState()

            let p = CGPoint(
                x: (canvas.width  - symbolImg.size.width)  / 2,
                y: (canvas.height - symbolImg.size.height) / 2
            )
            symbolImg.draw(at: p)
        }
    }

    /// バッジ (= 色付き円 + 白 symbol) を PNG として返すラッパー。
    @MainActor
    private static func renderBadge(symbol: String, colorHex: String, size: CGFloat = 96) -> Data? {
        renderBadgeImage(symbol: symbol, colorHex: colorHex, size: size)?.pngData()
    }
    #else
    /// macOS フォールバック: Shortcuts UI が iOS とは異なるため nil で OK。
    @MainActor
    static func renderAISuggestionSymbol(_ name: String, colorHex: String) -> Data? { nil }
    @MainActor
    static func renderColoredSymbol(_ name: String, colorHex: String) -> Data? { nil }
    #endif
}

#if canImport(UIKit)
private extension UIColor {
    /// HSB の brightness に `delta` を加算した新しい色を返す。
    /// `delta` は -1.0…1.0、ガード付き。
    func adjustingBrightness(by delta: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let nb = max(0, min(1, b + delta))
        return UIColor(hue: h, saturation: s, brightness: nb, alpha: a)
    }
}
#endif

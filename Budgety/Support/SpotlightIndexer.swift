//
//  SpotlightIndexer.swift
//  Budgety
//
//  シート (ExpenseSheet) を Spotlight にインデックスし、Spotlight の検索結果から
//  該当シートを直接開けるようにする。
//
//  識別子は ExpenseSheet に安定 UUID が無いため、アプリ内ナビゲーション
//  (`NavigationStack(path: [NSManagedObjectID])`) と同じ objectID の URI 表現を使う。
//  CloudKit 同期環境では objectID は端末ごとに異なるが、Spotlight の索引も端末
//  ローカルなので問題ない。保存済み (永続 ID) のシートのみを索引する。
//

import Foundation
import CoreData
import SwiftUI

#if canImport(CoreSpotlight)
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Spotlight 検索結果 → シートを開く、の橋渡し。
/// `onContinueUserActivity` はビュー階層が生きている時に届くとは限らないので、
/// cold launch 用に識別子を一時保持し、`SheetListView` が消費する。
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()
    private init() {}

    private var pendingSheetIdentifier: String?

    /// Spotlight から「このシートを開いて」と要求された時に呼ぶ。
    func requestOpenSheet(identifier: String) {
        pendingSheetIdentifier = identifier
        NotificationCenter.default.post(name: .expensoOpenSheet, object: nil,
                                        userInfo: ["identifier": identifier])
    }

    /// 保留中の識別子を取り出して消費する (cold launch のフォールバック用)。
    func consumePendingSheetIdentifier() -> String? {
        defer { pendingSheetIdentifier = nil }
        return pendingSheetIdentifier
    }
}

enum SpotlightIndexer {
    /// Spotlight のドメイン識別子 (ドメイン単位の一括削除に使う)。
    static let sheetDomain = "com.tento.budgety.sheet"

    #if canImport(CoreSpotlight)

    @MainActor private static var pendingContext: NSManagedObjectContext?
    @MainActor private static var isReindexing = false
    @MainActor private static var isObserving = false

    @MainActor
    static func start(context: NSManagedObjectContext) {
        reindexAllSheets(in: context)
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSManagedObjectContext.didSaveObjectIDsNotification,
                           object: nil, queue: nil) { note in
            let changedSheets = [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey]
                .contains { key in
                    let ids = note.userInfo?[key] as? Set<NSManagedObjectID>
                    return ids?.contains { $0.entity.name == "ExpenseSheet" } == true
                }
            if changedSheets {
                Task { @MainActor in reindexAllSheets(in: context) }
            }
        }
        var notifications: [Notification.Name] = [.NSPersistentStoreRemoteChange, .expensoStoreReset]
        #if os(iOS)
        notifications.append(UIApplication.didBecomeActiveNotification)
        #endif
        for name in notifications {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in reindexAllSheets(in: context) }
            }
        }
    }

    /// 全世代でドメインを共有する。古いバージョンで登録された保護済みシートも消去する。
    @MainActor
    static func reindexAllSheets(in context: NSManagedObjectContext) {
        pendingContext = context
        guard !isReindexing else { return }
        isReindexing = true
        Task { @MainActor in
            defer { isReindexing = false }
            let index = CSSearchableIndex.default()
            while let context = pendingContext {
                pendingContext = nil
                do {
                    try await index.deleteSearchableItems(withDomainIdentifiers: [sheetDomain])
                    // An update during deletion supersedes this snapshot. Keep all index
                    // operations ordered so an older write cannot republish a locked sheet.
                    if pendingContext != nil { continue }
                    let access = try IntentSheetAccess(checking: context)
                    let items = try access.sheets().map { makeItem(for: $0) }
                    if !items.isEmpty {
                        try await index.indexSearchableItems(items)
                    }
                } catch {
                    #if DEBUG
                    NSLog("[Spotlight] reindex failed: %@", error.localizedDescription)
                    #endif
                }
            }
        }
    }

    /// Spotlight の一意識別子 (= objectID URI) から ExpenseSheet の objectID を復元する。
    @MainActor
    static func objectID(forIdentifier identifier: String,
                         in context: NSManagedObjectContext) -> NSManagedObjectID? {
        try? IntentSheetAccess(checking: context).resolve(identifier).objectID
    }

    // MARK: - CSSearchableItem 生成

    @MainActor
    private static func makeItem(for sheet: ExpenseSheet) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        let name = sheet.displayName
        attributes.title = name.isEmpty ? String(localized: "シート") : name
        let note = (sheet.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        attributes.contentDescription = note.isEmpty ? String(localized: "支出シート") : note
        attributes.keywords = [name,
                               String(localized: "シート"),
                               String(localized: "家計簿"),
                               sheet.resolvedDefaultCurrencyCode].filter { !$0.isEmpty }
        #if canImport(UIKit)
        if let data = thumbnailData(for: sheet) {
            attributes.thumbnailData = data
        }
        #endif
        let identifier = sheet.objectID.uriRepresentation().absoluteString
        let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: sheetDomain,
                                    attributeSet: attributes)
        item.associateAppEntity(ExpenseSheetEntity.from(sheet))
        return item
    }

    #if canImport(UIKit)
    /// シートの SF Symbol を、シート色の角丸背景に白抜きで描いたサムネイル。
    @MainActor
    private static func thumbnailData(for sheet: ExpenseSheet) -> Data? {
        let side: CGFloat = 120
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let background = UIColor(sheet.tint)
        let config = UIImage.SymbolConfiguration(pointSize: side * 0.46, weight: .semibold)
        let symbol = UIImage(systemName: sheet.displaySymbol, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.22)
            background.setFill()
            path.fill()
            if let symbol {
                let size = symbol.size
                symbol.draw(at: CGPoint(x: (side - size.width) / 2,
                                        y: (side - size.height) / 2))
            }
        }
        return image.pngData()
    }
    #endif

    #else  // CoreSpotlight 非対応プラットフォーム (watchOS 等)

    @MainActor static func start(context: NSManagedObjectContext) {}
    @MainActor static func reindexAllSheets(in context: NSManagedObjectContext) {}
    @MainActor
    static func objectID(forIdentifier identifier: String,
                         in context: NSManagedObjectContext) -> NSManagedObjectID? { nil }

    #endif
}

#if canImport(CoreSpotlight)
extension ExpenseSheetEntity: IndexedEntity {}
#endif

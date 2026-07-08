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

    /// 保存/リモート変更が連続した時に索引を作り直しすぎないための debounce。
    private static var pendingReindex: DispatchWorkItem?
    private static var isObserving = false

    /// 起動時に一度呼ぶ。全シートを索引し、以後の保存/リモート変更で自動更新する。
    @MainActor
    static func start(context: NSManagedObjectContext) {
        reindexAllSheets(in: context)
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        for name in [NSManagedObjectContext.didSaveObjectsNotification,
                     Notification.Name.NSPersistentStoreRemoteChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // queue: .main のため必ずメインスレッドで呼ばれる。
                MainActor.assumeIsolated { scheduleReindex(context: context) }
            }
        }
    }

    @MainActor
    private static func scheduleReindex(context: NSManagedObjectContext) {
        pendingReindex?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { reindexAllSheets(in: context) }
        }
        pendingReindex = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 全シートを Spotlight に再登録する (ドメインを空にしてから入れ直すので
    /// 削除・リネームも確実に反映される)。
    @MainActor
    static func reindexAllSheets(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        let sheets = (try? context.fetch(request)) ?? []
        let items: [CSSearchableItem] = sheets.compactMap { sheet in
            sheet.objectID.isTemporaryID ? nil : makeItem(for: sheet)
        }
        #if DEBUG
        NSLog("[Spotlight] reindex: %d sheets fetched, %d indexable (indexingAvailable=%@)",
              sheets.count, items.count, CSSearchableIndex.isIndexingAvailable() ? "YES" : "NO")
        #endif
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [sheetDomain]) { deleteError in
            #if DEBUG
            if let deleteError { NSLog("[Spotlight] delete error: %@", deleteError.localizedDescription) }
            #endif
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { indexError in
                #if DEBUG
                if let indexError {
                    NSLog("[Spotlight] index error: %@", indexError.localizedDescription)
                } else {
                    NSLog("[Spotlight] indexed %d items OK", items.count)
                }
                #endif
            }
        }
    }

    /// Spotlight の一意識別子 (= objectID URI) から ExpenseSheet の objectID を復元する。
    static func objectID(forIdentifier identifier: String,
                         in context: NSManagedObjectContext) -> NSManagedObjectID? {
        guard let url = URL(string: identifier),
              let coordinator = context.persistentStoreCoordinator,
              let oid = coordinator.managedObjectID(forURIRepresentation: url) else { return nil }
        return oid
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
        return CSSearchableItem(uniqueIdentifier: identifier,
                                domainIdentifier: sheetDomain,
                                attributeSet: attributes)
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
    static func objectID(forIdentifier identifier: String,
                         in context: NSManagedObjectContext) -> NSManagedObjectID? { nil }

    #endif
}

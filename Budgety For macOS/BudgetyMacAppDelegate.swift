//
//  BudgetyMacAppDelegate.swift
//  Budgety For macOS
//
//  CKShare 招待リンクの受諾を処理する AppKit デリゲート。
//  macOS では NSApplicationDelegate に
//  `application(_:userDidAcceptCloudKitShareWith:)` が用意されており、
//  Mac の「メール / メッセージ」アプリ等から共有リンクをクリックして
//  受諾フローが完了するとこのメソッドが呼ばれる。
//

import AppKit
import CloudKit
import CoreData
import os

final class BudgetyMacAppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.tento.budgety", category: "ShareAccept")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log.notice("BudgetyMacAppDelegate launched")
    }

    func application(_ application: NSApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Self.log.notice("userDidAcceptCloudKitShareWith fired")
        accept(metadata: metadata)
    }

    /// URL から CKShare.Metadata を取得して受諾する (手動貼り付け用)。
    /// メール / Safari の自動 routing が効かない時の fallback。
    @MainActor
    func acceptShareURL(_ url: URL) async throws {
        let containerID = "iCloud.com.tento.budgety"
        let container = CKContainer(identifier: containerID)
        Self.log.notice("Fetching metadata for URL: \(url.absoluteString, privacy: .public)")
        let metadata = try await container.shareMetadata(for: url)
        accept(metadata: metadata)
    }

    private func accept(metadata: CKShare.Metadata) {
        let pc = PersistenceController.shared
        let container = pc.container

        guard let sharedStore = pc.sharedStore else {
            NotificationCenter.default.post(
                name: .expensoShareAcceptanceFailed,
                object: nil,
                userInfo: ["message": "共有ストアが準備できていません。アプリを再起動してください。"]
            )
            return
        }

        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Self.log.error("acceptShareInvitations failed: \(error.localizedDescription, privacy: .public)")
                    NotificationCenter.default.post(
                        name: .expensoShareAcceptanceFailed,
                        object: nil,
                        userInfo: ["message": "共有の受諾に失敗しました: \(error.localizedDescription)"]
                    )
                } else {
                    // 受諾後は新シートに自分の ParticipantProfile を作って共有相手に名前を見せる
                    Task { @MainActor in
                        await UserProfileStore.shared.ensureUserRecordNameLoaded()
                        await UserProfileStore.shared.refreshAppleIDName()
                        UserProfileStore.shared.ensureProfileForAllSheets(in: pc.container.viewContext)
                        UserProfileStore.shared.hydrateParticipantProfilesFromShares(in: pc.container.viewContext)
                    }
                    NotificationCenter.default.post(
                        name: .expensoShareAccepted,
                        object: nil,
                        userInfo: [
                            "shareTitle": (metadata.share[CKShare.SystemFieldKey.title] as? String) ?? ""
                        ]
                    )
                }
            }
        }
    }
}

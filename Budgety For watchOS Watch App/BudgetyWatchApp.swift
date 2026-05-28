//
//  BudgetyWatchApp.swift
//  Budgety Watch
//
//  watchOS 版 Budgety のエントリポイント。
//  iPhone 版と同じ Core Data + CloudKit (iCloud.com.tento.Expenso) を共有するので、
//  CloudKit 経由でシート / 支出が自動同期される。
//

import SwiftUI
import CoreData
import CloudKit

@main
struct BudgetyWatchApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @WKApplicationDelegateAdaptor(BudgetyWatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .task {
                    // 起動時に自分の userRecordName をキャッシュ + selfMemberID (UUID) を生成。
                    // 支出追加時に payerProfileID / payerMemberID として書き込むため。
                    await UserProfileStore.shared.ensureUserRecordNameLoaded()
                    _ = UserProfileStore.shared.ensureSelfMemberID()
                    // 自分のプロフィール (名前・写真) を Public DB から取得。
                    // 写真はディスク保存でデバイスローカルのため、watch では取得が必要。
                    await UserProfileStore.shared.refreshOwnPublicProfile()
                }
        }
    }
}

/// iCloud 共有シートの招待リンクを watchOS で受諾するための delegate。
/// iOS の SceneDelegate.windowScene(_:userDidAcceptCloudKitShareWith:) と同じ仕組みを
/// watchOS でも提供する。受け取った metadata を Shared store へ取り込み、CloudKit
/// 同期で該当シートが watch に降りてくる。
final class BudgetyWatchAppDelegate: NSObject, WKApplicationDelegate {
    func userDidAcceptCloudKitShare(with metadata: CKShare.Metadata) {
        let pc = PersistenceController.shared
        guard let sharedStore = pc.sharedStore else {
            NotificationCenter.default.post(
                name: .expensoShareAcceptanceFailed,
                object: nil,
                userInfo: ["message": "共有ストアが準備できていません。アプリを再起動してください。"]
            )
            return
        }
        pc.container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NotificationCenter.default.post(
                        name: .expensoShareAcceptanceFailed,
                        object: nil,
                        userInfo: ["message": "共有の受諾に失敗しました: \(error.localizedDescription)"]
                    )
                } else {
                    // 受諾直後に自分の ParticipantProfile を ensure。これがないと
                    // 他参加者のメンバーリストに自分の名前が出ない。
                    Task { @MainActor in
                        await UserProfileStore.shared.ensureUserRecordNameLoaded()
                        UserProfileStore.shared.ensureProfileForAllSheets(in: pc.container.viewContext)
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

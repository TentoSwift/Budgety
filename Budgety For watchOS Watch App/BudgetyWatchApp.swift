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

@main
struct BudgetyWatchApp: App {
    @StateObject private var persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .task {
                    // 起動時に自分の userRecordName をキャッシュ + selfMemberID (UUID) を生成。
                    // 支出追加時に payerProfileID / payerMemberID として書き込むため。
                    await UserProfileStore.shared.ensureUserRecordNameLoaded()
                    _ = UserProfileStore.shared.ensureSelfMemberID()
                }
        }
    }
}

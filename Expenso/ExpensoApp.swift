//
//  ExpensoApp.swift
//  Expenso
//
//  Created by Tento Ishino on 2026/05/04.
//  Copyright © 2026 Tento Ishino. All rights reserved.
//

import SwiftUI
import CoreData

@main
struct ExpensoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let persistenceController = PersistenceController.shared

    @Environment(\.scenePhase) private var scenePhase
    @State private var shareToast: String?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .overlay(alignment: .top) {
                    if let shareToast {
                        Text(shareToast)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .shadow(radius: 4)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoShareAccepted)) { note in
                    let title = (note.userInfo?["shareTitle"] as? String) ?? "シート"
                    showToast("「\(title)」に参加しました")
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoShareAcceptanceFailed)) { note in
                    let message = (note.userInfo?["message"] as? String) ?? "共有の受諾に失敗しました"
                    showToast(message)
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoPremiumExpired)) { _ in
                    showToast("Premium が終了しました。自分が作成した共有を解除しました。")
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoSaveFailed)) { note in
                    let message = (note.userInfo?["message"] as? String) ?? "保存に失敗しました"
                    showToast(message)
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoStoreReset)) { note in
                    let message = (note.userInfo?["message"] as? String) ?? "データベースをリセットしました"
                    showToast(message)
                }
                .task {
                    await PurchaseManager.shared.refreshEntitlements()
                    await FXRatesService.shared.refreshIfStale()
                    await UserProfileStore.shared.ensureUserRecordNameLoaded()
                    let ctx = persistenceController.container.viewContext
                    UserProfileStore.shared.syncFromSelfMember(in: ctx)
                    UserProfileStore.shared.propagateProfile(in: ctx)
                }
                // CloudKit が新しいデータを取り込んだら自分の Member も再 sync して
                // ローカルのプロフィール (UserProfileStore) を最新に保つ
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                    let ctx = persistenceController.container.viewContext
                    UserProfileStore.shared.syncFromSelfMember(in: ctx)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // フォアグラウンド復帰時にも entitlement を再確認。
                    // (購読期限切れの伝播や、共有解除のリトライをここでも走らせる)
                    if newPhase == .active {
                        Task { await PurchaseManager.shared.refreshEntitlements() }
                    }
                }
        }
    }

    private func showToast(_ message: String) {
        withAnimation { shareToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { shareToast = nil }
        }
    }
}

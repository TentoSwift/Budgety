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
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["EXPENSO_DEBUG_REVOKE"] == "1" {
                        await PurchaseManager.runExpiryRevokeForDebug()
                    }
                    #endif
                    await FXRatesService.shared.refreshIfStale()
                    await UserProfileStore.shared.ensureUserRecordNameLoaded()
                    let ctx = persistenceController.container.viewContext
                    // 別端末で先にプロフィールが設定されていれば、同期で来た ParticipantProfile から取り込む
                    UserProfileStore.shared.hydrateFromParticipantProfile(in: ctx)
                    // 定期項目の未生成 occurrence を Expense に展開
                    RecurringExpenseGenerator.generateAll(in: ctx)
                }
                // CloudKit が新しいデータを取り込んだら ParticipantProfile から再 hydrate。
                // 通知は viewContext へのマージ完了より早く飛ぶことがあるため、
                // 200ms ほど待ってから fetch して取りこぼしを防ぐ。
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        let ctx = persistenceController.container.viewContext
                        if (UserProfileStore.shared.userRecordName ?? "").isEmpty {
                            await UserProfileStore.shared.ensureUserRecordNameLoaded()
                        }
                        UserProfileStore.shared.hydrateFromParticipantProfile(in: ctx)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task { await PurchaseManager.shared.refreshEntitlements() }
                        let ctx = persistenceController.container.viewContext
                        RecurringExpenseGenerator.generateAll(in: ctx)
                        Task { @MainActor in
                            if (UserProfileStore.shared.userRecordName ?? "").isEmpty {
                                await UserProfileStore.shared.ensureUserRecordNameLoaded()
                            }
                            UserProfileStore.shared.hydrateFromParticipantProfile(in: ctx)
                        }
                    case .background:
                        // バックグラウンドに移る前に次回の BGAppRefreshTask を予約。
                        // iOS は背景時にしか走らせないので、この瞬間がチャンス。
                        AppDelegate.scheduleAppRefresh()
                    default:
                        break
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

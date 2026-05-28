//
//  BudgetyMacApp.swift
//  Budgety For macOS
//
//  macOS 用エントリポイント。iOS / visionOS と同じ Core Data + CloudKit スタックを共有し、
//  WindowGroup でメインウィンドウを表示する。
//  CKShare 招待リンクの受諾は NSApplicationDelegate (BudgetyMacAppDelegate) に委譲する。
//

import SwiftUI
import CoreData

@main
struct BudgetyMacApp: App {
    let persistenceController = PersistenceController.shared
    @NSApplicationDelegateAdaptor(BudgetyMacAppDelegate.self) private var appDelegate

    @State private var toast: String?

    var body: some Scene {
        WindowGroup(id: "main") {
            BudgetyMacContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .frame(minWidth: 900, minHeight: 600)
                // macOS は Mac App Store が更新通知を管理するので独自の
                // 「アップデートがあります」ダイアログは出さない。
                .overlay(alignment: .top) {
                    if let toast {
                        Text(toast)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .task {
                    // 為替レートを最新化 (キャッシュが当日中なら何もしない)
                    await FXRatesService.shared.refreshIfStale()
                    await UserProfileStore.shared.ensureUserRecordNameLoaded()
                    await UserProfileStore.shared.refreshAppleIDName()
                    // 同 Apple ID の他デバイスで編集された自分のプロフィールを取り込む
                    await UserProfileStore.shared.refreshOwnPublicProfile()
                    let ctx = persistenceController.container.viewContext
                    // 他参加者のプロフィール (Public DB) を prefetch
                    await UserProfileStore.shared.prefetchAllProfileURNs(in: ctx)
                    // CKShare がまだ非同期で取得中の可能性があるので数秒後に再 prefetch
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await UserProfileStore.shared.prefetchAllProfileURNs(in: ctx)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        let ctx = persistenceController.container.viewContext
                        if (UserProfileStore.shared.userRecordName ?? "").isEmpty {
                            await UserProfileStore.shared.ensureUserRecordNameLoaded()
                        }
                        await UserProfileStore.shared.refreshOwnPublicProfile()
                        await UserProfileStore.shared.prefetchAllProfileURNs(in: ctx)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoShareAccepted)) { note in
                    let title = (note.userInfo?["shareTitle"] as? String) ?? "共有"
                    showToast("「\(title)」に参加しました")
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoShareAcceptanceFailed)) { note in
                    let msg = (note.userInfo?["message"] as? String) ?? "共有の受諾に失敗しました"
                    showToast(msg)
                }
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            BudgetyMacSettingsView()
                .frame(width: 500, height: 350)
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { toast = nil }
        }
    }
}

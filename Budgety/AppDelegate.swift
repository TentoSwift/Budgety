//
//  AppDelegate.swift
//  Expenso
//

import UIKit
import CloudKit
import CoreData
import BackgroundTasks
import UserNotifications
import os

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let backgroundRefreshIdentifier = "com.tento.Expenso.refresh"
    private static let bgLog = Logger(subsystem: "com.tento.Expenso", category: "bgtask")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // BGAppRefreshTask の handler 登録は launch のかなり早いタイミングで
        // 行わないと iOS から拒否される。AppDelegate の didFinish... は
        // SwiftUI App の `.task` よりも前なので確実。
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: nil
        ) { task in
            Self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        Self.scheduleAppRefresh()

        // フォアグラウンドでも割り勘通知のバナーを出すため delegate を設定。
        UNUserNotificationCenter.current().delegate = self
        // CloudKit のサイレントプッシュでバックグラウンド起動 → import → 割り勘検出ができるよう登録。
        application.registerForRemoteNotifications()
        return true
    }

    /// CloudKit のサイレントプッシュ受信。NSPersistentCloudKitContainer がバックグラウンドで
    /// import を行うので、その結果が viewContext にマージされたら (= remote change) 割り勘を
    /// 検出して通知する。最大 ~25 秒でタイムアウト。
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let nc = NotificationCenter.default
        var finished = false
        var observer: NSObjectProtocol?
        let finish: (UIBackgroundFetchResult) -> Void = { result in
            guard !finished else { return }
            finished = true
            if let observer { nc.removeObserver(observer) }
            completionHandler(result)
        }
        observer = nc.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // import の viewContext へのマージ完了を少し待ってから検出。
                try? await Task.sleep(nanoseconds: 300_000_000)
                SplitNotificationManager.shared.processChanges(
                    in: PersistenceController.shared.container.viewContext)
                finish(.newData)
            }
        }
        // import が来なかった場合のフォールバック。
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { finish(.noData) }
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// 次回の background refresh を OS に予約する。実際にいつ走るかは iOS が決める
    /// (= 数時間〜数日。ユーザーの利用パターンや充電状態で変わる)。
    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        // 最短 30 分後以降に実行 (実際はもっと先になることが多い)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            bgLog.debug("scheduleAppRefresh: queued (>= 30min)")
        } catch {
            bgLog.error("scheduleAppRefresh: \(error.localizedDescription)")
        }
    }

    /// 実際に iOS が起こしてくれた時の処理。
    /// `BGAppRefreshTask` は最大 ~30 秒の予算しかないので、軽い refresh のみ。
    private static func handleAppRefresh(task: BGAppRefreshTask) {
        bgLog.debug("handleAppRefresh: fired")
        // 次回ぶんを必ず予約 (= 失敗で連鎖終了するのを防ぐ)
        scheduleAppRefresh()

        // 予算切れの時は走っている処理を諦めさせる expirationHandler を登録
        let work = Task { @MainActor in
            await PurchaseManager.shared.refreshEntitlements()
            // refreshEntitlements の中で hasActive + confirmExpiry を経て
            // 必要なら revokeAllOwnedShares が走る。
            bgLog.debug("handleAppRefresh: refreshEntitlements done")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            bgLog.error("handleAppRefresh: expired before completion")
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// アプリ前面でも割り勘通知をバナー表示する。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound]
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            accept(metadata: metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        accept(metadata: cloudKitShareMetadata)
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
                    NotificationCenter.default.post(
                        name: .expensoShareAcceptanceFailed,
                        object: nil,
                        userInfo: ["message": "共有の受諾に失敗しました: \(error.localizedDescription)"]
                    )
                } else {
                    // 受諾後は新シートに自分の ParticipantProfile を書き込み、共有相手に名前/画像を見せる。
                    // ensureProfileForAllSheets は既に PP がある既存シートには触れない (per-sheet 値を保護)。
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

// Notification.Name extension は Support/Notifications.swift に移動
// (= iOS / watchOS の両方から参照されるため共有)

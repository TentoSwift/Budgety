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
    @State private var premiumExpiredAlertShown: Bool = false
    /// 初回起動時のみオンボーディングを出す。UserDefaults 永続化。
    @AppStorage("hasShownOnboarding") private var hasShownOnboarding: Bool = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .appUpdateGate()
                .sheet(isPresented: Binding(
                    get: { !hasShownOnboarding },
                    set: { if !$0 { hasShownOnboarding = true } }
                )) {
                    OnboardingView { hasShownOnboarding = true }
                        .interactiveDismissDisabled()
                }
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
                    // 共有相手にあなたが誰か分かるよう、プロフィール未設定なら設定 UI を出す
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoShareAcceptanceFailed)) { note in
                    let message = (note.userInfo?["message"] as? String) ?? "共有の受諾に失敗しました"
                    showToast(message)
                }
                .onReceive(NotificationCenter.default.publisher(for: .expensoPremiumExpired)) { _ in
                    premiumExpiredAlertShown = true
                }
                .alert("Premium が終了しました", isPresented: $premiumExpiredAlertShown) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("自分が作成した共有を解除しました。設定済みのシートロックはそのまま残ります。")
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
                    #if DEBUG
                    // CloudKit Production デプロイ準備: Development スキーマを一括生成する。
                    // `EXPENSO_INIT_CK_SCHEMA=1` を付けて iCloud サインイン済みで一度だけ起動。
                    if ProcessInfo.processInfo.environment["EXPENSO_INIT_CK_SCHEMA"] == "1" {
                        persistenceController.initializeCloudKitSchemaForDeploy()
                    }
                    #endif
                    await PurchaseManager.shared.refreshEntitlements()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["EXPENSO_DEBUG_REVOKE"] == "1" {
                        await PurchaseManager.runExpiryRevokeForDebug()
                    }
                    #endif
                    await FXRatesService.shared.refreshIfStale()
                    await UserProfileStore.shared.ensureUserRecordNameLoaded()
                    // Apple ID 名を取得して自分の displayName に反映 (初回は許可ダイアログ)
                    await UserProfileStore.shared.refreshAppleIDName()
                    let ctx = persistenceController.container.viewContext
                    if BuildInfo.profileFeatureEnabled {
                        UserProfileStore.shared.hydrateFromParticipantProfile(in: ctx)
                        UserProfileStore.shared.propagateProfileToAllSheets(in: ctx)
                    }
                    // 過去の PP 逆引きで self Member.recordName に他人の ID が紛れた可能性を
                    // ケアするための one-shot 正規化 (= canonical 経由で再判定)。
                    UserProfileStore.shared.sanitizeSelfMemberRecordName(in: ctx)
                    // 共有シートで `payerProfileID == 自分の旧 userRecordName` になっている
                    // 行を canonical (email ベース等) に自動マイグレートする。
                    UserProfileStore.shared.migrateLegacyPayerProfileIDs(in: ctx)
                    // 別端末で編集された自分のプロフィールを Public DB から取り込む
                    // (= 起動時の auto upload は Public DB の quota を消費するので削除。
                    //  upload は ProfileEditView での明示保存時のみ実行する)
                    await UserProfileStore.shared.refreshOwnPublicProfile()
                    // 自分のシート数を Public プロフィールに publish (前回から変化した時のみ)
                    await UserProfileStore.shared.publishSheetCountIfChanged()
                    await UserProfileStore.shared.prefetchAllProfileURNs(in: ctx)
                    // CKShare の participant nameComponents を PP にハイドレートして
                    // Apple ID 名がそのまま表示されるようにする (iCloud Extended Share Access)
                    UserProfileStore.shared.hydrateParticipantProfilesFromShares(in: ctx)
                    #if DEBUG
                    diagnoseAllShares(in: ctx)
                    #endif
                    // 定期項目の未生成 occurrence を Expense に展開
                    RecurringExpenseGenerator.generateAll(in: ctx)
                    // v0.x で UserDefaults に格納していたシートロック情報を Core Data 側へ移行
                    SheetLockManager.shared.migrateLegacyEntriesIfNeeded(context: ctx)
                    // 割り勘通知: 許可要求 + baseline 確定 (既存ぶんはサイレント既読化)
                    await SplitNotificationManager.shared.requestAuthorizationIfNeeded()
                    SplitNotificationManager.shared.processChanges(in: ctx)
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
                        // CKShare の participant 情報も再ハイドレート (新 PP が syc されてきた可能性)
                        UserProfileStore.shared.hydrateParticipantProfilesFromShares(in: ctx)
                        // 旧 canonical (email:...) → URN 移行も remote change で再実行
                        // (CKShare メタデータが遅延ロードされた後に走らせる)
                        UserProfileStore.shared.migrateLegacyPayerProfileIDs(in: ctx)
                        // 他メンバーが追加した「自分への割り勘」を検出して通知
                        SplitNotificationManager.shared.processChanges(in: ctx)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task { await PurchaseManager.shared.refreshEntitlements() }
                        // iCloud サインイン状態を再取得 (設定でサインインして戻った場合に追従)
                        persistenceController.refreshAccountStatus()
                        let ctx = persistenceController.container.viewContext
                        RecurringExpenseGenerator.generateAll(in: ctx)
                        Task { @MainActor in
                            if (UserProfileStore.shared.userRecordName ?? "").isEmpty {
                                await UserProfileStore.shared.ensureUserRecordNameLoaded()
                            }
                            // 同 Apple ID の他デバイスで編集された自分のプロフィールを取り込む
                            await UserProfileStore.shared.refreshOwnPublicProfile()
                            // 前面化のたびにシート数が変わっていれば publish
                            await UserProfileStore.shared.publishSheetCountIfChanged()
                            if BuildInfo.profileFeatureEnabled {
                                UserProfileStore.shared.hydrateFromParticipantProfile(in: ctx)
                                UserProfileStore.shared.propagateProfileToAllSheets(in: ctx)
                            }
                        }
                    case .background:
                        // バックグラウンドに移る前に次回の BGAppRefreshTask を予約。
                        // iOS は背景時にしか走らせないので、この瞬間がチャンス。
                        AppDelegate.scheduleAppRefresh()
                        // バックグラウンドに移ったらシートロックを全て再要求 (= 次回フォアグラウンドで再入力)
                        Task { @MainActor in
                            SheetLockManager.shared.lockAll()
                        }
                    default:
                        break
                    }
                }
        }
        // WWDC 2025 #238 で導入された AssistiveAccess Scene。
        // 端末が AA モード時はこちらが起動 (= ContentView ではなく簡易版が表示される)。
        AssistiveAccess {
            AssistiveAccessView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.locale, Locale(identifier: "ja_JP"))
        }
    }

    private func showToast(_ message: String) {
        withAnimation { shareToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { shareToast = nil }
        }
    }

    /// 全シートの ParticipantProfile.recordName (= 共有相手の URN を含む) を集めて
    /// Public DB から fetch する。背景処理。
    @MainActor
    private func prefetchAllParticipantProfiles(in ctx: NSManagedObjectContext) async {
        let req = NSFetchRequest<ParticipantProfile>(entityName: "ParticipantProfile")
        let pps = (try? ctx.fetch(req)) ?? []
        var urns: Set<String> = []
        for pp in pps {
            guard let rn = pp.recordName, !rn.isEmpty,
                  rn != "_defaultOwner_", rn != "__defaultOwner__" else { continue }
            // "email:..." 形式はまだ Phase 1 では Public DB キーに使えないので除外
            // (Phase 2 で URN に統一する)
            if rn.hasPrefix("email:") || rn.hasPrefix("phone:") { continue }
            urns.insert(rn)
        }
        // 自分の URN も refresh しておく
        if let own = UserProfileStore.shared.userRecordName, !own.isEmpty {
            urns.insert(own)
        }
        if !urns.isEmpty {
            await PublicProfileSync.shared.fetchProfiles(forURNs: Array(urns))
        }
    }

    /// DEBUG: 全シートの CKShare 参加者から取得可能な identity 情報をログ出力。
    /// `com.apple.developer.icloud-extended-share-access` エンタイトルメント追加後の
    /// 挙動確認用 (Console.app の category=ShareDiagnostics でフィルタ可)。
    @MainActor
    private func diagnoseAllShares(in ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(req)) ?? []
        for s in sheets {
            guard let share = ShareCoordinator.shared.existingShare(for: s) else { continue }
            ShareParticipantDiagnostics.dump(share: share, context: s.displayName)
        }
    }
}

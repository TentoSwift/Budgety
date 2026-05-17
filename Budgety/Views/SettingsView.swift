//
//  SettingsView.swift
//  Expenso
//

import SwiftUI
import SwiftData
import CloudKit

struct SettingsView: View {
    @StateObject private var pm = PurchaseManager.shared
    @StateObject private var fx = FXRatesService.shared
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var profile = UserProfileStore.shared
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showPaywall: Bool = false
    @State private var showEraseConfirm: Bool = false
    @State private var iCloudAccountStatus: CKAccountStatus = .couldNotDetermine

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pm.isPremium {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Budgety Premium").bold()
                                Text("シート共有機能が有効です")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        Button {
                            showPaywall = true
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.yellow)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Premium にアップグレード")
                                        .foregroundStyle(.primary)
                                        .fontWeight(.semibold)
                                    Text("シートを他のユーザーと共有")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section("プロフィール") {
                    HStack(spacing: 12) {
                        AvatarView(
                            photoData: nil,
                            displayName: profile.resolvedDisplayName,
                            colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                            size: 40
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.resolvedDisplayName)
                                .foregroundStyle(.primary)
                            Text("Apple ID の名前を使用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Section("カテゴリ") {
                    Text("カテゴリはシートごとに設定します。各シート画面の右上「⋯」メニューからカテゴリ管理を開けます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("iCloud 同期") {
                    iCloudStatusRows
                    Text("シートのデータは iCloud に保存され、同じ Apple ID の iPhone・iPad・Mac で自動同期されます。無料でご利用いただけます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("シートの共有") {
                    if pm.isPremium {
                        Label("招待を送る (オーナー)", systemImage: "person.badge.shield.checkmark")
                        Text("シート画面の右上の人型アイコンから相手のメールアドレスを入力すると、iCloud アカウントを検索し「編集可能 / 閲覧のみ」の権限を付与してから招待リンクをメールで送信します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("招待を送るのは Premium 限定", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                        Text("Premium にアップグレードすると、家族や友人を権限付きで招待できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Label("招待を受けて参加 (無料)", systemImage: "envelope.open.fill")
                        .foregroundStyle(.green)
                    Text("オーナーから送られた招待メールのリンクをタップすると、課金なしでそのシートに参加できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if pm.isPremium {
                    Section {
                        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                            Label("サブスクリプションを管理", systemImage: "arrow.up.forward.app")
                        }
                    } footer: {
                        Text("サブスクリプションのプラン変更や解約は App Store の設定から行えます。")
                            .font(.caption)
                    }
                } else {
                    Section {
                        Button {
                            Task { await pm.restore() }
                        } label: {
                            Label(pm.isProcessing ? "復元中..." : "購入を復元", systemImage: "arrow.clockwise")
                        }
                        .disabled(pm.isProcessing)
                    }
                }

                Section("為替レート") {
                    HStack {
                        Label("基準通貨", systemImage: "dollarsign.circle")
                        Spacer()
                        Text(fx.baseCurrency).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("最終更新", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if let date = fx.lastRateDate {
                            Text(date).foregroundStyle(.secondary)
                        } else {
                            Text("未取得").foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await fx.refresh() }
                    } label: {
                        if fx.isFetching {
                            HStack {
                                ProgressView()
                                Text("取得中...")
                            }
                        } else {
                            Label("今すぐ更新", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(fx.isFetching)
                    if let err = fx.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    NavigationLink {
                        ClaudeIntegrationView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Claude と連携")
                                Text("自然言語で支出を記録")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.purple.gradient)
                        }
                    }
                }

                Section("バージョン") {
                    HStack {
                        Text("Budgety")
                        Spacer()
                        Text(Bundle.main.versionDisplay)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("デバッグ") {
                    NavigationLink("閉じる確認ダイアログ サンプル") {
                        DismissConfirmDemoView()
                            .navigationTitle("Dismiss Confirm Demo")
                    }
                    NavigationLink("プロモ用デモアニメーション") {
                        DemoShowcaseView()
                    }
                    NavigationLink("アシスティブアクセス画面プレビュー") {
                        AssistiveAccessView()
                            .navigationTitle("AA プレビュー")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    #if DEBUG
                    Button("Premium 期限切れの解除フローを試す") {
                        Task { @MainActor in
                            await PurchaseManager.runExpiryRevokeForDebug()
                        }
                    }
                    Button("「テスト」シートにサンプル支出を 30 件追加") {
                        SampleDataGenerator.populateTestSheet(in: viewContext)
                        Haptics.success()
                    }
                    #endif
                }

                Section {
                    Button(role: .destructive) {
                        showEraseConfirm = true
                    } label: {
                        Label("全データを削除", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("シート・支出・カテゴリ・メンバー・繰り返し項目・テンプレ・プロフィール (名前/写真/色) を含む全データを削除し、設定 (シートロック等) も初期化します。自分が作成した共有は解除され iCloud からも削除されます。受信した共有シートはオーナー側のデータには影響しません。元に戻せません。")
                        .font(.caption)
                }
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .task {
                UserProfileStore.shared.ensureSelfMemberExists(in: viewContext)
            }
            .onAppear {
                if ProcessInfo.processInfo.environment["EXPENSO_DEMO"] == "paywall" {
                    showPaywall = true
                }
            }
            .confirmationDialog(
                "全データを削除しますか?",
                isPresented: $showEraseConfirm,
                titleVisibility: .visible
            ) {
                Button("削除する", role: .destructive) {
                    Task { @MainActor in
                        Haptics.warning()
                        await PersistenceController.shared.eraseAllData()
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("すべてのデータ・プロフィール・設定を削除し、アプリを初期状態に戻します。元に戻せません。削除後はアプリを再起動してください。")
            }
        }
    }

    @ViewBuilder
    private var iCloudStatusRows: some View {
        let (icon, color, text) = iCloudStatusDisplay
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(.primary)
                Text(syncStateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .task {
            await refreshAccountStatus()
        }
    }

    private var iCloudStatusDisplay: (icon: String, color: Color, text: String) {
        switch iCloudAccountStatus {
        case .available:
            return ("icloud.fill", .blue, "iCloud にサインイン済み")
        case .noAccount:
            return ("icloud.slash", .orange, "iCloud にサインインしていません")
        case .restricted:
            return ("exclamationmark.icloud.fill", .red, "iCloud アクセスが制限されています")
        case .temporarilyUnavailable:
            return ("icloud.slash", .orange, "iCloud に一時的にアクセスできません")
        case .couldNotDetermine:
            return ("icloud", .secondary, "iCloud 状態を確認中...")
        @unknown default:
            return ("icloud", .secondary, "iCloud 状態不明")
        }
    }

    private var syncStateText: String {
        if iCloudAccountStatus != .available {
            return "ローカル単独モードで動作"
        }
        return persistence.initialSyncComplete ? "同期完了" : "同期中..."
    }

    @MainActor
    private func refreshAccountStatus() async {
        let container = CKContainer(identifier: "iCloud.com.tento.budgety")
        do {
            iCloudAccountStatus = try await container.accountStatus()
        } catch {
            iCloudAccountStatus = .couldNotDetermine
        }
    }
}

private extension Bundle {
    var versionDisplay: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

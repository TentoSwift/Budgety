//
//  SettingsView.swift
//  Expenso
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pm = PurchaseManager.shared
    @StateObject private var fx = FXRatesService.shared
    @Environment(\.managedObjectContext) private var viewContext
    @State private var showPaywall: Bool = false
    @State private var showEraseConfirm: Bool = false
    @State private var showProfileEditor: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pm.isPremium {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Expenso Premium").bold()
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

                Section {
                    Button {
                        showProfileEditor = true
                    } label: {
                        HStack(spacing: 14) {
                            AvatarView(
                                photoData: profile.photoData,
                                displayName: profile.resolvedDisplayName,
                                colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                                size: 56
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.resolvedDisplayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("プロフィールを編集")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("プロフィール")
                } footer: {
                    Text("アカウント全体で使われるアバターと名前です。共有シートの相手にも表示されます。")
                }

                Section("カテゴリ") {
                    Text("カテゴリはシートごとに設定します。各シート画面の右上「⋯」メニューからカテゴリ管理を開けます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("iCloud 同期") {
                    Label("同期は自動で行われます", systemImage: "icloud.fill")
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

                Section("バージョン") {
                    HStack {
                        Text("Expenso")
                        Spacer()
                        Text(Bundle.main.versionDisplay)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showEraseConfirm = true
                    } label: {
                        Label("全データを削除", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("シート・支出・カテゴリをすべて削除します。自分が作成したシートは iCloud からも削除されます。受信した共有シートはオーナー側のデータには影響しません。元に戻せません。")
                        .font(.caption)
                }
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showProfileEditor) {
                UserProfileEditView()
            }
            .task {
                profile.ensureSelfMemberExists(in: viewContext)
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
                    PersistenceController.shared.eraseAllData()
                    Haptics.warning()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("シート・支出・カテゴリをすべて削除します。元に戻せません。")
            }
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

//
//  SettingsView.swift
//  Expenso
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @StateObject private var pm = PurchaseManager.shared
    @StateObject private var fx = FXRatesService.shared
    @StateObject private var profile = UserProfileStore.shared
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall: Bool = false
    @State private var showingProfileEdit: Bool = false
    /// 既定通貨の override。空文字 = 自動 (システムの地域)。
    @AppStorage(CurrencyCatalog.preferredCurrencyKey) private var preferredCurrency: String = ""

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
                    Button {
                        showingProfileEdit = true
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(
                                photoData: profile.photoData,
                                displayName: profile.resolvedDisplayName,
                                colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                                size: 40
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.resolvedDisplayName)
                                    .foregroundStyle(.primary)
                                Text("名前・写真・背景色を編集")
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

                Section {
                    Picker(selection: $preferredCurrency) {
                        // 自動 = システムの地域設定に従う
                        Text("自動 (\(CurrencyCatalog.option(for: CurrencyCatalog.localeDefaultCode).displayName))")
                            .tag("")
                        ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                            Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                        }
                    } label: {
                        Label("既定の通貨", systemImage: "yensign.circle")
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("通貨")
                } footer: {
                    Text("新しいシートの既定通貨や、検索結果の合計の換算に使われます。「自動」ではシステムの地域設定（現在: \(CurrencyCatalog.localeDefaultCode)）に従います。")
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

                Section {
                    NavigationLink {
                        EraseAllDataView()
                    } label: {
                        Label {
                            Text("全データを削除")
                        } icon: {
                            Image(systemName: "trash.fill")
                                .foregroundStyle(.red)
                        }
                    }
                } footer: {
                    Text("全データを削除して、アプリを初期状態に戻します。元に戻せません。")
                        .font(.caption)
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("閉じる")
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showingProfileEdit) {
                ProfileEditView()
            }
            .task {
                UserProfileStore.shared.ensureSelfMemberExists(in: viewContext)
            }
            .onAppear {
                if ProcessInfo.processInfo.environment["EXPENSO_DEMO"] == "paywall" {
                    showPaywall = true
                }
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

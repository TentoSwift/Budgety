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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showPaywall: Bool = false
    @State private var showingProfileEdit: Bool = false
    @State private var showingOnboarding: Bool = false
    /// 既定通貨の override。空文字 = 自動 (システムの地域)。
    @AppStorage(CurrencyCatalog.preferredCurrencyKey) private var preferredCurrency: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pm.isPremium {
                        Label {
                            Text("Budgety Premium").bold()
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
                    infoRow("基準通貨", systemImage: "dollarsign.circle") {
                        Text(fx.baseCurrency)
                    }
                    infoRow("最終更新", systemImage: "clock.arrow.circlepath") {
                        Text(fx.lastRateDate ?? "未取得")
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
                    infoRow("Budgety") {
                        Text(Bundle.main.versionDisplay)
                    }
                    Button {
                        showingOnboarding = true
                    } label: {
                        Label {
                            Text("ようこそ画面を表示")
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                        }
                    }
                    NavigationLink {
                        LicenseListScreen()
                    } label: {
                        Label("ライセンス", systemImage: "doc.text")
                    }
                    Link(destination: URL(string: "https://tentoswift.github.io/budgety-privacy/")!) {
                        Label {
                            HStack {
                                Text("プライバシーポリシー")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(.blue)
                        }
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
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showingProfileEdit) {
                ProfileEditView()
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView { showingOnboarding = false }
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

    /// ラベル + 値の行。AX サイズでは横に収まらないので AnyLayout で縦積みに切替。
    /// systemImage を渡すと Label アイコン付き、省略すると素の Text ラベル。
    @ViewBuilder
    private func infoRow<Trailing: View>(
        _ label: String,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            if let systemImage {
                Label(label, systemImage: systemImage)
            } else {
                Text(label)
            }
            if !isAX { Spacer(minLength: 8) }
            trailing()
                .foregroundStyle(.secondary)
                .frame(maxWidth: isAX ? .infinity : nil,
                       alignment: isAX ? .leading : .trailing)
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

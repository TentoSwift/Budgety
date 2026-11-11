//
//  SettingsView.swift
//  Expenso
//

import SwiftUI
import SwiftData
#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import CoreTransferable
import UniformTypeIdentifiers

private struct SiriSearchShortcut: Transferable {
    let url: URL
    static let contentType = UTType(filenameExtension: "shortcut") ?? .data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: contentType) { SentTransferredFile($0.url) }
    }

    static let bundled: Self? = {
        let variant: String
        switch Bundle.main.bundleIdentifier {
        case "com.tento.budgety.dev": variant = "development"
        case "com.tento.budgety": variant = "production"
        default: return nil
        }
        return Bundle.main.url(forResource: "SiriExpenseSearch-" + variant, withExtension: "shortcut").map(Self.init(url:))
    }()
}

private struct SiriSearchShortcutSection: View {
    @State private var exporting = false
    @State private var exportFailed = false

    var body: some View {
        Section {
            if let shortcut = SiriSearchShortcut.bundled {
                Button { exporting = true } label: {
                    Label("「支出を検索」をファイルに保存", systemImage: "square.and.arrow.down")
                }
                .fileExporter(isPresented: $exporting, item: shortcut, contentTypes: [SiriSearchShortcut.contentType],
                              defaultFilename: "支出を検索") { result in
                    if case .failure = result { exportFailed = true }
                }
                .alert("ショートカットを保存できませんでした", isPresented: $exportFailed) {
                    Button("閉じる", role: .cancel) {}
                }
            } else {
                Link("ショートカットを作成", destination: URL(string: "shortcuts://create-shortcut")!)
            }
        } header: {
            Text("ホーム画面から「支出を検索」と頼む")
        } footer: {
            if SiriSearchShortcut.bundled != nil {
                Text("初回だけ、保存したファイルを「ファイル」アプリで開き、「ショートカットを追加」をタップしてください。次からはSiriに「支出を検索」と言い、続けて支出名を答えます。")
            } else {
                Text("Budgetyの「支出名で明細を確認」を追加し、支出名を「毎回尋ねる」に設定します。「支出を検索」という名前で保存すると、Siriにその名前を言うだけで使えます。")
            }
        }
    }
}
#endif

struct SettingsView: View {
    @StateObject private var fx = FXRatesService.shared
    @StateObject private var profile = UserProfileStore.shared
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingProfileEdit: Bool = false
    /// 既定通貨の override。空文字 = 自動 (システムの地域)。
    @AppStorage(CurrencyCatalog.preferredCurrencyKey) private var preferredCurrency: String = ""
    /// デバッグ: 定期項目の完全仮想化フラグ (保存せず表示時に算出)。
    @AppStorage(RecurringOccurrenceService.virtualizationKey) private var recurringVirtualization: Bool = false

    var body: some View {
        NavigationStack {
            Form {
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
                                Text("名前・写真を編集")
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
                    infoRow(String(localized: "基準通貨"), systemImage: "dollarsign.circle") {
                        Text(fx.baseCurrency)
                    }
                    infoRow(String(localized: "最終更新"), systemImage: "clock.arrow.circlepath") {
                        Text(fx.lastRateDate ?? String(localized: "未取得"))
                    }
                    if let err = fx.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                #if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
                if #available(iOS 27.3, *) {
                    Section {
                        Text("「先月のランチ代の明細を教えて」")
                        Text("「このシートの最近の支出名と金額を教えて」")
                        Text("「家計にランチ代800円を記録して」")
                        Text("「家計で先月いくら使った？」")
                    } header: {
                        Text("Siri AI")
                    } footer: {
                        Text("Budgetyを開いていればアプリ名は不要です。「家計」は自分のシート名に置き換えてください。パスワード付きのシートは対象外です。")
                    }
                    SiriSearchShortcutSection()
                }
                #endif

                // Claude / MCP 連携は macOS 専用 (アプリ本体を MCP サーバーとして登録する方式)。
                // iOS はバイナリを CLI 起動できないため、この導線は macOS のみに置く。
                // iOS では設定できないため、案内のみ footer に表示する。
                Section {
                    Label("Claude / MCP 連携", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Claude / MCP との連携は macOS 版でご利用いただけます。Mac 版の設定画面からセットアップできます。")
                        .font(.caption)
                }

                Section("バージョン") {
                    infoRow("Budgety") {
                        Text(Bundle.main.versionDisplay)
                    }
                    NavigationLink {
                        LicenseListScreen()
                    } label: {
                        Label("ライセンス", systemImage: "doc.text")
                    }
                    Link(destination: URL(string: "https://apps.apple.com/app/id6768543053?action=write-review")!) {
                        Label {
                            HStack {
                                Text("App Store でレビュー")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    Link(destination: URL(string: "https://tentoswift.github.io/budgety-privacy/support.html")!) {
                        Label {
                            HStack {
                                Text("サポート")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundStyle(.green)
                        }
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

                if BuildInfo.isInternalBuild, RecurringOccurrenceService.featureEnabled {
                    Section {
                        NavigationLink {
                            RecurringDiagnosticsView()
                        } label: {
                            Label("定期項目の診断", systemImage: "repeat.circle")
                        }
                        Toggle(isOn: $recurringVirtualization) {
                            Label("定期を仮想化 (保存しない)", systemImage: "wand.and.stars")
                        }
                    } header: {
                        Text("デバッグ")
                    } footer: {
                        Text("ON で定期項目を保存せず、表示時にルールから算出します (実験的)。既存の生成済みデータはそのまま残ります。")
                            .font(.caption)
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
            .sheet(isPresented: $showingProfileEdit) {
                ProfileEditView()
            }
            .task {
                UserProfileStore.shared.ensureSelfMemberExists(in: viewContext)
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
    /// App Store 配布版 (= 製品版) は短い "1.0" のみ。
    /// Debug ビルド / TestFlight (sandboxReceipt) はビルド番号付き "1.0 (2026052804)"。
    var versionDisplay: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        #if DEBUG
        return "\(v) (\(b))"
        #else
        let isTestFlight = appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        return isTestFlight ? "\(v) (\(b))" : v
        #endif
    }
}

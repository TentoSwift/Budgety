//
//  AppUpdateChecker.swift
//  Budgety
//
//  強制 / 任意アップデートの判定と UI。
//  設定値 (最低必要バージョン・最新バージョン・App Store URL) は GitHub Pages
//  (gh-pages) に置いた version.json から取得する。アプリ更新なしでファイルを
//  書き換えるだけで挙動を変えられる。
//
//  - インストール版 <  minimumVersion → 強制 (閉じられないブロック画面)
//  - インストール版 <  latestVersion  → 任意 (閉じられる案内)
//  - 取得失敗 (オフライン等) → 何もしない (fail-open。ユーザーをロックしない)
//
//  ルートビューに `.appUpdateGate()` を付けるだけで有効になる。
//

import SwiftUI
import Combine

@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    enum Status: Equatable {
        case unknown
        case upToDate
        case optional(latest: String, message: String?, url: URL)
        case forced(message: String?, url: URL)
    }

    @Published private(set) var status: Status = .unknown
    /// 任意更新の案内を一度閉じたら、同セッション中は再表示しない。
    @Published var optionalDismissed: Bool = false
    /// 任意更新アラートを抑制するフラグ。
    /// オンボーディングなど別の modal 表示中に有効化することで、
    /// alert がそちらを蹴り出して閉じてしまうのを防ぐ。
    @Published var suppressOptionalAlert: Bool = false

    /// gh-pages にホストした設定 JSON。
    private let configURL = URL(string: "https://tentoswift.github.io/Budgety/version.json")!
    /// App Store URL が JSON に無い時のフォールバック (Budgety: id6768543053)。
    private let fallbackStoreURL = URL(string: "https://apps.apple.com/app/id6768543053")!

    private var lastChecked: Date?

    private struct Config: Decodable {
        let minimumVersion: String?
        let latestVersion: String?
        let message: String?
        let appStoreURL: String?
    }

    /// 現在インストールされているアプリの短縮バージョン (CFBundleShortVersionString)。
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 設定を取得して状態を更新する。`force` でない限り直近 1 時間はスキップ。
    func check(force: Bool = false) async {
        if !force, let last = lastChecked, Date().timeIntervalSince(last) < 3600 { return }
        do {
            var req = URLRequest(url: configURL)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            req.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: req)
            let cfg = try JSONDecoder().decode(Config.self, from: data)
            lastChecked = Date()
            apply(cfg)
        } catch {
            // fail-open: 取得できなければブロックしない。
            #if DEBUG
            print("⚠️ AppUpdateChecker failed: \(error)")
            #endif
        }
    }

    private func apply(_ cfg: Config) {
        let current = Self.currentVersion
        let storeURL = cfg.appStoreURL.flatMap(URL.init(string:)) ?? fallbackStoreURL
        let minimum = cfg.minimumVersion ?? "0"
        let latest = cfg.latestVersion ?? minimum

        if isVersion(current, lessThan: minimum) {
            status = .forced(message: cfg.message, url: storeURL)
        } else if isVersion(current, lessThan: latest) {
            status = .optional(latest: latest, message: cfg.message, url: storeURL)
        } else {
            status = .upToDate
        }
    }

    /// "1.2.0" < "1.10.0" を正しく判定するため数値比較を使う。
    private func isVersion(_ a: String, lessThan b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}

// MARK: - Gate modifier

private struct AppUpdateGate: ViewModifier {
    @StateObject private var checker = AppUpdateChecker.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .overlay {
                if case let .forced(message, url) = checker.status {
                    ForceUpdateView(message: message, storeURL: url)
                        .transition(.opacity)
                        .zIndex(1000)
                }
            }
            .animation(.easeInOut, value: checker.status)
            .alert("アップデートがあります", isPresented: optionalBinding) {
                Button("App Store を開く") {
                    if case let .optional(_, _, url) = checker.status { openURL(url) }
                }
                Button("後で", role: .cancel) { checker.optionalDismissed = true }
            } message: {
                if case let .optional(latest, message, _) = checker.status {
                    Text(message ?? "新しいバージョン \(latest) が利用できます。")
                }
            }
            .task { await checker.check() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await checker.check() } }
            }
    }

    private var optionalBinding: Binding<Bool> {
        Binding(
            get: {
                if checker.suppressOptionalAlert { return false }
                if case .optional = checker.status { return !checker.optionalDismissed }
                return false
            },
            set: { newValue in if !newValue { checker.optionalDismissed = true } }
        )
    }
}

extension View {
    /// ルートビューに付けると、強制 / 任意アップデートの判定と UI を有効化する。
    func appUpdateGate() -> some View { modifier(AppUpdateGate()) }
}

// MARK: - Forced update screen

/// 閉じられない全画面のブロック表示。背面のアプリ操作を完全に塞ぐ。
private struct ForceUpdateView: View {
    let message: String?
    let storeURL: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("アップデートが必要です")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message ?? "最新バージョンに更新してから続けてください。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    openURL(storeURL)
                } label: {
                    Text("App Store で更新")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }
            .frame(maxWidth: 420)
        }
        // 背面へのタップ・ジェスチャを遮断する。
        .contentShape(Rectangle())
    }
}

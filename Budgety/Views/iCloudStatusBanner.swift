//
//  iCloudStatusBanner.swift
//  Expenso
//
//  シート未作成時の空状態 + 同期待ち画面で表示する iCloud 状態サマリー。
//

import SwiftUI
import CloudKit

struct iCloudStatusBanner: View {
    @StateObject private var persistence = PersistenceController.shared
    @State private var status: CKAccountStatus = .couldNotDetermine

    private var display: (icon: String, color: Color, title: String, subtitle: String)? {
        switch status {
        case .available:
            if persistence.initialSyncComplete {
                return nil // 同期完了 → バナー不要
            }
            return ("icloud.and.arrow.down",
                    .blue,
                    String(localized: "iCloud から取得中..."),
                    String(localized: "他の端末で作ったシートが降りてくるまでお待ちください。"))
        case .noAccount:
            return ("icloud.slash",
                    .orange,
                    String(localized: "iCloud に未サインイン"),
                    String(localized: "ローカル単独モードで動作します。設定からサインインすると同期されます。"))
        case .restricted:
            return ("exclamationmark.icloud.fill",
                    .red,
                    String(localized: "iCloud が制限されています"),
                    String(localized: "MDM や Screen Time の制限を確認してください。"))
        case .temporarilyUnavailable:
            return ("icloud.slash",
                    .orange,
                    String(localized: "iCloud に接続できません"),
                    String(localized: "ネットワーク状況を確認して、しばらくしてから再度お試しください。"))
        case .couldNotDetermine:
            return ("icloud",
                    .secondary,
                    String(localized: "iCloud 状態を確認中..."),
                    "")
        @unknown default:
            return nil
        }
    }

    var body: some View {
        if let d = display {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: d.icon)
                        .foregroundStyle(d.color)
                    Text(d.title)
                        .font(.subheadline.weight(.semibold))
                }
                if !d.subtitle.isEmpty {
                    Text(d.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(d.color.opacity(0.10))
            )
            .padding(.horizontal)
            .task {
                await refresh()
            }
        } else {
            EmptyView()
        }
    }

    @MainActor
    private func refresh() async {
        let container = CKContainer(identifier: "iCloud.com.tento.budgety")
        do {
            status = try await container.accountStatus()
        } catch {
            status = .couldNotDetermine
        }
    }
}

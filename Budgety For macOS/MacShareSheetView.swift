//
//  MacShareSheetView.swift
//  Budgety For macOS
//
//  Mac 用のシート共有 UI。UICloudSharingController が使えないので
//  ShareCoordinator の API をそのまま使う自前 SwiftUI 実装。
//
//  機能:
//  - 既存参加者一覧 (アバター + 名前 + 役割 + 権限) を表示
//  - メール入力で新規招待 (Premium 限定: オーナー側のみ)
//  - 参加者の削除
//  - 共有 URL のコピー (リンク経由でも招待できる)
//  - 共有解除 (全参加者削除 + 公開 OFF)
//

import SwiftUI
import CloudKit
import AppKit

struct MacShareSheetView: View {
    @ObservedObject var sheet: ExpenseSheet
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pm = PurchaseManager.shared
    @StateObject private var pub = PublicProfileSync.shared

    @State private var share: CKShare?
    @State private var participants: [CKShare.Participant] = []
    @State private var loading: Bool = true
    @State private var error: String?

    @State private var inviteEmail: String = ""
    @State private var inviting: Bool = false
    @State private var inviteSucceedMessage: String?

    @State private var shareURL: URL?
    @State private var preparingURL: Bool = false
    @State private var showingRevokeConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView()
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !sheet.isOwnedByCurrentUser {
                            recipientNotice
                        } else if let err = error {
                            errorBanner(err)
                        }
                        if !participants.isEmpty {
                            participantsSection
                        }
                        if sheet.isOwnedByCurrentUser {
                            if pm.isPremium {
                                inviteSection
                                shareLinkSection
                                if share != nil {
                                    revokeSection
                                }
                            } else {
                                premiumGate
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 600)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            Task { await reload() }
        }
        .confirmationDialog(
            "このシートの共有を解除しますか?",
            isPresented: $showingRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button("共有を解除", role: .destructive) {
                Task { await revoke() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("参加者全員が削除され、リンクからの参加もできなくなります。シート自体は削除されません。")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(sheet.tint.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: sheet.symbol ?? "person.2.fill")
                    .foregroundStyle(.white)
                    .font(.callout.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sheet.displayName).font(.headline)
                Text("シートを共有").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("参加者")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(participants.enumerated()), id: \.offset) { idx, p in
                    participantRow(p)
                    if idx < participants.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
        }
    }

    private func participantRow(_ p: CKShare.Participant) -> some View {
        let identity = p.userIdentity
        let urn = identity.userRecordID?.recordName ?? ""
        let isSelfPlaceholder = UserProfileStore.isSelfPlaceholderRecordName(urn)
        let displayName: String = {
            if let comps = identity.nameComponents {
                let s = PersonNameComponentsFormatter().string(from: comps)
                if !s.isEmpty { return s }
            }
            if isSelfPlaceholder { return UserProfileStore.shared.resolvedDisplayName }
            if let cached = pub.profileOrPrefetch(for: urn), !cached.displayName.isEmpty {
                return cached.displayName
            }
            if let email = identity.lookupInfo?.emailAddress { return email }
            return "メンバー"
        }()
        let isMe = isSelfPlaceholder
        let role: String = {
            switch p.role {
            case .owner: return "オーナー"
            case .privateUser: return "参加者"
            case .publicUser: return "リンク参加"
            default: return ""
            }
        }()
        let acceptance: String = {
            switch p.acceptanceStatus {
            case .pending: return "招待中"
            case .accepted: return "参加済み"
            case .removed: return "削除済み"
            default: return ""
            }
        }()
        let photo: Data? = isMe
            ? UserProfileStore.shared.photoData
            : pub.profileOrPrefetch(for: urn)?.photoData
        return HStack(spacing: 12) {
            AvatarView(
                photoData: photo,
                displayName: displayName,
                colorHex: "#8E8E93",
                size: 36
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(displayName) (自分)" : displayName)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(role).font(.caption2).foregroundStyle(.secondary)
                    if !acceptance.isEmpty {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(acceptance).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if sheet.isOwnedByCurrentUser, p.role != .owner {
                Button(role: .destructive) {
                    Task { await removeParticipant(p) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("この参加者を削除")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("メールアドレスで招待")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                TextField("name@example.com", text: $inviteEmail)
                    .textFieldStyle(.roundedBorder)
                    .disabled(inviting)
                Button {
                    Task { await invite() }
                } label: {
                    if inviting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("招待")
                    }
                }
                .disabled(inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty || inviting)
                .keyboardShortcut(.return)
            }
            if let msg = inviteSucceedMessage {
                Text(msg).font(.caption).foregroundStyle(.green)
            }
            Text("相手は iCloud にサインインしている必要があります。招待は CKShare 経由で送られます。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var shareLinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("共有リンク")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                if let url = shareURL {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                } else {
                    Button {
                        Task { await prepareLink() }
                    } label: {
                        if preparingURL {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("リンクを取得")
                        }
                    }
                    .disabled(preparingURL)
                    Spacer()
                }
            }
            Text("このリンクを知っている人が iCloud アカウントで参加できます (招待者は事前に追加が必要)。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var revokeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: .destructive) {
                showingRevokeConfirm = true
            } label: {
                Label("このシートの共有を解除", systemImage: "person.2.slash")
                    .frame(maxWidth: .infinity)
            }
            Text("このシートを共有しているすべての参加者が外され、リンクも無効になります。シート自体は残ります。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var premiumGate: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("招待は Premium 限定", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
            Text("Premium にアップグレードすると、家族や友人をこのシートに招待できます。受け取った共有シートに参加するのは無料です。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.3)))
    }

    @ViewBuilder
    private var recipientNotice: some View {
        Label("このシートは他のユーザーから共有されています。招待 / 削除はオーナーのみが行えます。",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
    }

    private func errorBanner(_ msg: String) -> some View {
        Label(msg, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
    }

    // MARK: - Actions

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        let current = ShareCoordinator.shared.existingShare(for: sheet)
        share = current
        participants = current?.participants
            .filter { $0.acceptanceStatus != .removed }
            ?? []
        // 参加者の URN を prefetch しておく (写真表示用)
        let urns = participants.compactMap { $0.userIdentity.userRecordID?.recordName }
        if !urns.isEmpty {
            await PublicProfileSync.shared.fetchProfiles(forURNs: urns)
        }
        // 既に URL が取れているなら表示
        if let s = current { shareURL = s.url }
    }

    @MainActor
    private func invite() async {
        let email = inviteEmail.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return }
        inviting = true
        defer { inviting = false }
        error = nil
        inviteSucceedMessage = nil
        do {
            let result = try await ShareCoordinator.shared.invite(
                email: email,
                permission: .readWrite,
                to: sheet
            )
            inviteEmail = ""
            inviteSucceedMessage = "\(email) を招待しました"
            shareURL = result.url
            await reload()
        } catch {
            self.error = "招待に失敗しました: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func removeParticipant(_ p: CKShare.Participant) async {
        guard let share else { return }
        error = nil
        do {
            try await ShareCoordinator.shared.remove(participant: p, from: share)
            await reload()
        } catch {
            self.error = "削除に失敗しました: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func prepareLink() async {
        preparingURL = true
        defer { preparingURL = false }
        error = nil
        do {
            let (s, url) = try await ShareCoordinator.shared.prepareShareLink(for: sheet)
            share = s
            shareURL = url
            await reload()
        } catch {
            self.error = "リンクの取得に失敗しました: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func revoke() async {
        error = nil
        let ok = await ShareCoordinator.shared.revokeAllOwnedShares()
        if !ok {
            self.error = "共有解除に失敗した share がありました。"
        }
        await reload()
    }
}

//
//  CloudSharingView.swift
//  Expenso
//

import SwiftUI
import CoreData
import CloudKit
import UIKit
import MessageUI

struct CloudSharingView: View {
    @ObservedObject var record: ExpenseSheet
    @Environment(\.dismiss) private var dismiss
    @StateObject private var purchaseManager = PurchaseManager.shared

    @State private var email: String = ""
    @State private var permission: CKShare.ParticipantPermission = .readWrite
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?
    @State private var iCloudHint: String?
    @State private var existingShare: CKShare?
    @State private var participantsRefresh: Int = 0
    @State private var mailData: MailData?
    @State private var showMailUnavailable: Bool = false
    @State private var showCopiedToast: Bool = false
    @State private var pendingURL: URL?
    @State private var showPaywall: Bool = false
    @State private var isLoadingShare: Bool = false

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValidEmail: Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return trimmedEmail.range(of: pattern, options: .regularExpression) != nil
    }

    private var isOwner: Bool { record.isOwnedByCurrentUser }

    var body: some View {
        NavigationStack {
            Group {
                if !isOwner {
                    participantView
                } else if purchaseManager.isPremium {
                    premiumForm
                } else {
                    premiumGate
                }
            }
            .navigationTitle(isOwner ? "シートを共有" : "共有シートの情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .overlay(alignment: .top) {
                if showCopiedToast {
                    Text("コピーしました")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(item: $mailData) { data in
                MailComposeView(data: data) { result in
                    mailData = nil
                    if case .failure(let err) = result {
                        errorMessage = err.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
            .alert("メール送信ができません", isPresented: $showMailUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("この端末ではメール送信が設定されていません。「リンクをコピー」で他のアプリから送ってください。")
            }
            .task {
                if purchaseManager.isPremium {
                    await checkICloudStatus()
                    refreshShare()
                }
            }
        }
    }

    private var premiumForm: some View {
        Form {
            groupHeader
            if let share = existingShare {
                participantsSection(share: share)
                shareIDSection(share: share)
            }
            inviteSection
            shareLinkSection
            if let errorMessage { errorSection(message: errorMessage) }
            if let iCloudHint { hintSection(text: iCloudHint) }
        }
    }

    private var participantView: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName).bold()
                        Text("既定通貨: \(record.resolvedDefaultCurrencyCode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.2.circle.fill")
                        .foregroundStyle(record.tint)
                }
            } footer: {
                Text("このシートはオーナーから共有されています。シートのデータはオーナー側と同期され、あなたは追加・編集ができます。")
            }

            // premiumForm (オーナー画面) と同じ条件・同じレンダラで参加者を表示する。
            if let share = existingShare {
                participantsSection(share: share)
                shareIDSection(share: share)
            }

            Section {
                Button(role: .destructive) {
                    Task { await leaveSharedSheet() }
                } label: {
                    HStack {
                        if isProcessing { ProgressView() }
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("シートから退出")
                        Spacer()
                    }
                }
                .disabled(isProcessing)
            } footer: {
                Text("退出するとあなたの端末からこのシートが消えます。オーナーや他の参加者のデータは残ります。")
            }

            if let errorMessage { errorSection(message: errorMessage) }
        }
        .refreshable { await refreshShareAsync() }
        .task {
            await checkICloudStatus()
            await refreshShareAsync()
        }
    }

    /// 共有情報の取得を非同期で行う。Core Data の `fetchShares` が即返らないケース
    /// (Shared ストアに来たばかりの sheet 等) に対応するため、軽くリトライする。
    @MainActor
    private func refreshShareAsync() async {
        isLoadingShare = true
        defer { isLoadingShare = false }
        for attempt in 0..<3 {
            if let share = ShareCoordinator.shared.existingShare(for: record) {
                existingShare = share
                await fetchAllParticipantProfiles(share)
                return
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        // 取得できなかった場合も existingShare は nil のまま
    }

    @MainActor
    private func leaveSharedSheet() async {
        isProcessing = true
        errorMessage = nil
        do {
            // ctx.delete(record) ではなく purge を使う。
            // delete だとオーナーや他参加者の側のシートまで消えてしまう。
            try await ShareCoordinator.shared.leaveSharedSheet(record)
            Haptics.warning()
            dismiss()
        } catch {
            errorMessage = "退出に失敗しました: \(error.localizedDescription)"
        }
        isProcessing = false
    }

    private var premiumGate: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.icloud.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("招待を送るには Premium が必要です")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("シートのオーナー (招待を送る人) のみ課金が必要です。\n招待された相手は無料でこのシートに参加できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showPaywall = true
            } label: {
                Label("Premium を見る", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer()
        }
        .padding()
    }

    private var groupHeader: some View {
        Section {
            Label {
                Text(record.displayName).bold()
            } icon: {
                Image(systemName: "person.2.circle.fill")
                    .foregroundStyle(Color(hex: record.displayColorHex) ?? .blue)
            }
        } footer: {
            Text("メールアドレスから iCloud アカウントを検索し、権限を付与した上で招待します。受け取った相手は同期で参加できます。")
        }
    }

    @ViewBuilder
    private func participantsSection(share: CKShare) -> some View {
        let displayed = share.participants
        if !displayed.isEmpty {
            Section {
                ForEach(Array(displayed.enumerated()), id: \.offset) { _, participant in
                    ParticipantRow(
                        participant: participant,
                        sheet: record,
                        isOwnerView: isOwner
                    ) { permission in
                        await update(participant: participant, share: share, to: permission)
                    } onRemove: {
                        await removeParticipant(participant, from: share)
                    }
                }
            } header: {
                Text("参加者")
            }
            .id(participantsRefresh)
        }
    }

    private func fetchAllParticipantProfiles(_ share: CKShare) async {
        // ParticipantProfile は Core Data + CloudKit Sharing 経由で自動同期されるため、
        // 明示的なプロフェッチは不要 (互換のため空実装で残す)。
    }

    @ViewBuilder
    private func shareIDSection(share: CKShare) -> some View {
        let recordName = share.recordID.recordName
        let zoneName = share.recordID.zoneID.zoneName
        let ownerName = share.recordID.zoneID.ownerName
        Section {
            VStack(alignment: .leading, spacing: 6) {
                row(label: "Record", value: recordName)
                row(label: "Zone", value: zoneName)
                row(label: "Owner", value: ownerName)
            }
            Button {
                UIPasteboard.general.string = recordName
                withAnimation { showCopiedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { showCopiedToast = false }
                }
            } label: {
                Label("Record ID をコピー", systemImage: "doc.on.doc")
                    .font(.caption)
            }
        } header: {
            Text("CKShare ID")
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
        }
    }

    private var inviteSection: some View {
        Group {
            Section("招待先のメールアドレス") {
                TextField("name@icloud.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("権限") {
                Picker("権限", selection: $permission) {
                    Text("編集可能").tag(CKShare.ParticipantPermission.readWrite)
                    Text("閲覧のみ").tag(CKShare.ParticipantPermission.readOnly)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    Task { await sendInvitation() }
                } label: {
                    HStack {
                        if isProcessing {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(isProcessing ? "招待を準備中..." : "権限を付与して招待を送る")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || !isValidEmail)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("招待先の Apple ID に登録済みのメールアドレスを入力してください。iCloud に登録されていないアドレスでは招待できません。")
            }
        }
    }

    @ViewBuilder
    private var shareLinkSection: some View {
        let resolvedURL: URL? = pendingURL ?? existingShare?.url
        Section {
            if let url = resolvedURL {
                ShareLink(item: url,
                          subject: Text("Budgety「\(record.displayName)」への招待"),
                          message: Text(invitationMessage(url: url))) {
                    Label("AirDrop ・ メッセージ ・ 他のアプリ", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    withAnimation { showCopiedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation { showCopiedToast = false }
                    }
                } label: {
                    Label("リンクをコピー", systemImage: "doc.on.doc")
                }
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await prepareLinkOnly() }
                } label: {
                    HStack {
                        if isProcessing {
                            ProgressView()
                        } else {
                            Image(systemName: "link.circle")
                        }
                        Text(isProcessing ? "リンクを準備中..." : "共有リンクを準備")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isProcessing)
            }
        } header: {
            Text("リンクで共有")
        } footer: {
            if resolvedURL == nil {
                Text("リンクを生成して、上で招待した相手に AirDrop / メッセージ等で送れます。招待されていない人がリンクをタップしても参加できません。")
            } else {
                Text("このリンクは上で招待した相手だけが使えます (Apple ID 必須)。招待されていない人がタップしても参加できません。")
            }
        }
    }

    private func invitationMessage(url: URL) -> String {
        """
        Budgety のシート「\(record.displayName)」に招待します。
        下のリンクをタップして参加してください:
        \(url.absoluteString)
        """
    }

    @MainActor
    private func prepareLinkOnly() async {
        isProcessing = true
        errorMessage = nil
        do {
            let result = try await ShareCoordinator.shared.prepareShareLink(for: record)
            existingShare = result.share
            pendingURL = result.url
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
    }

    private func errorSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func hintSection(text: String) -> some View {
        Section {
            Label(text, systemImage: "icloud.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func sendInvitation() async {
        isProcessing = true
        errorMessage = nil
        do {
            let result = try await ShareCoordinator.shared.invite(
                email: trimmedEmail,
                permission: permission,
                to: record
            )
            existingShare = result.share
            pendingURL = result.url
            email = ""
            participantsRefresh += 1
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
    }

    @MainActor
    private func update(participant: CKShare.Participant, share: CKShare, to newPermission: CKShare.ParticipantPermission) async {
        participant.permission = newPermission
        do {
            let pc = PersistenceController.shared
            guard let store = pc.privateStore else { throw ShareError.storeNotReady }
            try await pc.container.persistUpdatedShare(share, in: store)
            participantsRefresh += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeParticipant(_ participant: CKShare.Participant, from share: CKShare) async {
        do {
            try await ShareCoordinator.shared.remove(participant: participant, from: share)
            participantsRefresh += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshShare() {
        existingShare = ShareCoordinator.shared.existingShare(for: record)
    }

    private func checkICloudStatus() async {
        let status = try? await CKContainer(identifier: "iCloud.com.tento.Expenso").accountStatus()
        await MainActor.run {
            iCloudHint = Self.hint(for: status)
        }
    }

    private static func hint(for status: CKAccountStatus?) -> String? {
        switch status {
        case .some(.available), .none: return nil
        case .some(.noAccount): return "iCloud にサインインしていません。設定アプリから iCloud にサインインしてください。"
        case .some(.restricted): return "iCloud アカウントが制限されています。"
        case .some(.couldNotDetermine): return "iCloud の状態を確認できませんでした。"
        case .some(.temporarilyUnavailable): return "iCloud が一時的に利用できません。"
        @unknown default: return nil
        }
    }
}

private struct ParticipantRow: View {
    let participant: CKShare.Participant
    @ObservedObject var sheet: ExpenseSheet
    var isOwnerView: Bool = true
    let onPermissionChange: (CKShare.ParticipantPermission) async -> Void
    let onRemove: () async -> Void

    @ObservedObject private var userProfile = UserProfileStore.shared

    private var recordName: String? {
        guard let rn = participant.userIdentity.userRecordID?.recordName,
              !rn.isEmpty,
              rn != "_defaultOwner_",
              rn != "__defaultOwner__" else { return nil }
        return rn
    }

    /// この行が現在の iCloud ユーザー (= 自分) を表すか。
    /// CKShare の currentUserParticipant と同じ判定になるよう userRecordName で比較する。
    /// 自分がオーナーの場合、CKShare 上の recordName は `_defaultOwner_` プレースホルダ
    /// になるため、role == .owner + sheet が自分の所有 もケースとして拾う。
    private var isSelf: Bool {
        if let myRN = userProfile.userRecordName, !myRN.isEmpty, recordName == myRN {
            return true
        }
        if participant.role == .owner, sheet.isOwnedByCurrentUser {
            return true
        }
        return false
    }

    /// 表示用 recordName。`_defaultOwner_` プレースホルダの場合は `UserProfileStore` に
    /// キャッシュされている実 recordName をフォールバックに使う。
    private var displayedRecordName: String? {
        if let rn = recordName { return rn }
        if isSelf, let myRN = userProfile.userRecordName, !myRN.isEmpty {
            return myRN
        }
        return nil
    }

    private var emailAddress: String? {
        participant.userIdentity.lookupInfo?.emailAddress
    }

    /// このシート配下に居る、この participant に対応する ParticipantProfile を引く。
    private var participantProfile: ParticipantProfile? {
        guard let rn = recordName,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == rn })
    }

    private var isAccepted: Bool {
        participant.acceptanceStatus == .accepted
    }

    private var primaryText: String {
        // 自分の行は UserProfileStore からローカルプロフィールを採用する。
        // ParticipantProfile は他のユーザー向けに自分のプロフィールを propagate する仕組みであり、
        // 自分自身の sheet では空のことがあるため。
        if isSelf {
            return userProfile.resolvedDisplayName
        }
        if isAccepted, let n = participantProfile?.displayName, !n.isEmpty {
            return n
        }
        if participant.acceptanceStatus == .pending, let email = emailAddress {
            return email
        }
        if let info = participant.userIdentity.lookupInfo {
            if let email = info.emailAddress { return email }
            if let phone = info.phoneNumber { return phone }
        }
        if let nc = participant.userIdentity.nameComponents {
            return PersonNameComponentsFormatter().string(from: nc)
        }
        return "メンバー"
    }

    private var secondaryText: String? {
        if isSelf {
            return emailAddress
        }
        if isAccepted, let n = participantProfile?.displayName, !n.isEmpty {
            return emailAddress
        }
        return nil
    }

    private var avatarColorHex: String {
        if isSelf, let hex = userProfile.avatarBgColorHex, !hex.isEmpty {
            return hex
        }
        if isAccepted, let hex = participantProfile?.colorHex, !hex.isEmpty {
            return hex
        }
        switch participant.role {
        case .owner: return "#5856D6"
        default: return participant.acceptanceStatus == .pending ? "#FF9500" : "#8E8E93"
        }
    }

    private var statusText: String {
        switch participant.acceptanceStatus {
        case .pending: "招待中"
        case .accepted: "参加済み"
        case .removed: "削除済み"
        case .unknown: "不明"
        @unknown default: "不明"
        }
    }

    private var roleText: String {
        switch participant.role {
        case .owner: "オーナー"
        case .privateUser: "プライベート"
        case .publicUser: "公開"
        case .unknown: ""
        @unknown default: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if isSelf {
                    AvatarView(
                        photoData: userProfile.photoData,
                        displayName: primaryText,
                        colorHex: avatarColorHex,
                        size: 40
                    )
                } else if let pp = participantProfile {
                    ObservedParticipantProfileAvatar(profile: pp, size: 40)
                } else {
                    AvatarView(
                        photoData: nil,
                        displayName: primaryText,
                        colorHex: avatarColorHex,
                        size: 40
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let sub = secondaryText {
                        Text(sub)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(roleText)
                        if participant.role != .owner {
                            Text("·")
                            Text(statusText)
                                .foregroundStyle(participant.acceptanceStatus == .pending ? .orange : .secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let rn = displayedRecordName {
                        Text(rn)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
            }
            if isOwnerView, participant.role != .owner {
                HStack {
                    Picker("権限", selection: Binding(
                        get: { participant.permission },
                        set: { newValue in Task { await onPermissionChange(newValue) } }
                    )) {
                        Text("編集可能").tag(CKShare.ParticipantPermission.readWrite)
                        Text("閲覧のみ").tag(CKShare.ParticipantPermission.readOnly)
                    }
                    .pickerStyle(.segmented)
                    Button(role: .destructive) {
                        Task { await onRemove() }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.minus")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
            } else if !isOwnerView, participant.role != .owner {
                Text(participant.permission == .readWrite ? "編集可能" : "閲覧のみ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 52)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MailData: Identifiable {
    let id = UUID()
    let recipient: String
    let subject: String
    let body: String
}

private struct MailComposeView: UIViewControllerRepresentable {
    let data: MailData
    let onFinish: (Result<MFMailComposeResult, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        if !data.recipient.isEmpty { vc.setToRecipients([data.recipient]) }
        vc.setSubject(data.subject)
        vc.setMessageBody(data.body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (Result<MFMailComposeResult, Error>) -> Void
        init(onFinish: @escaping (Result<MFMailComposeResult, Error>) -> Void) {
            self.onFinish = onFinish
        }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true) { [self] in
                if let error {
                    onFinish(.failure(error))
                } else {
                    onFinish(.success(result))
                }
            }
        }
    }
}

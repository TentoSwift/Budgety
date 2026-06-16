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
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?
    @State private var iCloudHint: String?
    @State private var existingShare: CKShare?
    @State private var participantsRefresh: Int = 0
    /// swipeAction で削除しようとしている参加者。nil 解除でアラート閉じ。
    @State private var pendingRemove: ParticipantRemoveTarget?
    /// 「シートから退出」ボタンの確認アラート表示用。
    @State private var showLeaveConfirm: Bool = false
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
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .alert(
                "この参加者を削除しますか?",
                isPresented: Binding(
                    get: { pendingRemove != nil },
                    set: { if !$0 { pendingRemove = nil } }
                ),
                presenting: pendingRemove
            ) { target in
                Button("削除", role: .destructive) {
                    let p = target.participant
                    let s = target.share
                    Task { await removeParticipant(p, from: s) }
                    pendingRemove = nil
                }
                Button("キャンセル", role: .cancel) { pendingRemove = nil }
            } message: { target in
                Text("\(target.displayName) はこの共有シートから外されます。相手の端末からもシートが見えなくなります。")
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
            }

            Section {
                Button(role: .destructive) {
                    showLeaveConfirm = true
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
        .alert("シートから退出しますか?", isPresented: $showLeaveConfirm) {
            Button("退出", role: .destructive) {
                Task { await leaveSharedSheet() }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("「\(record.displayName)」がこの端末から消えます。オーナーや他の参加者のデータは残ります。")
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
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(record.tint.gradient)
                        .frame(width: 76, height: 76)
                        .shadow(color: record.tint.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: record.symbol ?? "person.2.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(spacing: 2) {
                    Text(record.displayName)
                        .font(.title3.weight(.semibold))
                    Text("既定通貨 \(record.resolvedDefaultCurrencyCode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func participantsSection(share: CKShare) -> some View {
        let displayed = share.participants
        if !displayed.isEmpty {
            Section {
                ForEach(Array(displayed.enumerated()), id: \.offset) { _, participant in
                    ParticipantRow(participant: participant, sheet: record)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if isOwner && participant.role != .owner {
                                Button(role: .destructive) {
                                    pendingRemove = ParticipantRemoveTarget(
                                        participant: participant,
                                        share: share
                                    )
                                } label: {
                                    Label("削除", systemImage: "person.crop.circle.badge.minus")
                                }
                            }
                        }
                }
            } header: {
                Text("参加者")
            }
            .id(participantsRefresh)
        }
    }

    /// 参加者削除の確認アラート用ターゲット。
    private struct ParticipantRemoveTarget: Identifiable {
        let id = UUID()
        let participant: CKShare.Participant
        let share: CKShare
        var displayName: String {
            participant.userIdentity.nameComponents.flatMap {
                PersonNameComponentsFormatter().string(from: $0)
            } ?? participant.userIdentity.lookupInfo?.emailAddress ?? "参加者"
        }
    }

    private func fetchAllParticipantProfiles(_ share: CKShare) async {
        // ParticipantProfile は Core Data + CloudKit Sharing 経由で自動同期されるため、
        // 明示的なプロフェッチは不要 (互換のため空実装で残す)。
    }


    private var inviteSection: some View {
        Section {
            TextField("name@icloud.com", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await sendInvitation() }
            } label: {
                HStack {
                    if isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                    }
                    Text(isProcessing ? "招待を準備中..." : "招待する")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .foregroundStyle(isValidEmail ? Color.accentColor : Color.secondary)
            }
            .disabled(isProcessing || !isValidEmail)
        } header: {
            Text("Apple Account のメールアドレスで招待")
        } footer: {
            Text("「招待する」を押すと一覧に「招待中」として登録されます（メールを送らなくても登録は完了）。続いて開くメール作成画面から送るか、下の「リンクを送る」で別の方法でもリンクを渡せます。相手がリンクをタップすると参加できます。")
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
            Text("リンクを送る")
        } footer: {
            Text("「招待する」で登録した相手に、AirDrop やメッセージなどでこのリンクを送ることもできます。相手はリンクをタップして参加できます。")
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
        // メールクリア前に宛先を退避 (メール作成画面の To に使う)。
        let recipient = trimmedEmail
        do {
            let result = try await ShareCoordinator.shared.invite(
                email: recipient,
                permission: .readWrite,
                to: record
            )
            existingShare = result.share
            pendingURL = result.url
            email = ""
            participantsRefresh += 1
            Haptics.success()
            // 参加可能リストへ登録できたので、招待リンク入りのメール作成画面を開く。
            // メール未設定の端末では代替手段 (リンクをコピー) を案内する。
            if MFMailComposeViewController.canSendMail() {
                mailData = MailData(
                    recipient: recipient,
                    subject: "Budgety「\(record.displayName)」への招待",
                    body: invitationMessage(url: result.url)
                )
            } else {
                showMailUnavailable = true
            }
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
        let status = try? await CKContainer(identifier: "iCloud.com.tento.budgety").accountStatus()
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

    @ObservedObject private var userProfile = UserProfileStore.shared

    private var recordName: String? {
        guard let rn = participant.userIdentity.userRecordID?.recordName,
              !rn.isEmpty,
              rn != "_defaultOwner_",
              rn != "__defaultOwner__" else { return nil }
        return rn
    }

    /// この行が現在の iCloud ユーザー (= 自分) を表すか。
    /// CKShare では「見ている本人」のエントリは userRecordID.recordName が `__defaultOwner__`
    /// placeholder になるため、それも自分扱い。さらに canonical (= participant.budgetyCanonicalID
    /// と canonicalSelfIDs の交点) でもマッチする。
    private var isSelf: Bool {
        let rn = participant.userIdentity.userRecordID?.recordName ?? ""
        if rn == "__defaultOwner__" || rn == "_defaultOwner_" {
            return true
        }
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        let selfIDs = userProfile.canonicalSelfIDs(forShare: share)
        if let cid = participant.budgetyCanonicalID, selfIDs.contains(cid) {
            return true
        }
        if let myRN = userProfile.userRecordName, !myRN.isEmpty, rn == myRN {
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
    /// PP.recordName は canonical ID (オーナーなら userRecordName、参加者なら "email:...")
    /// で書かれているため、まず canonical で引き、失敗したら旧スキーマ (raw userRecordID)
    /// でもマッチさせる。自分の行は canonicalSelfIDs の集合で複数候補を試す。
    private var participantProfile: ParticipantProfile? {
        guard let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        var candidates: Set<String> = []
        if let cid = participant.budgetyCanonicalID, !cid.isEmpty {
            candidates.insert(cid)
        }
        if let rn = recordName { candidates.insert(rn) }
        if isSelf {
            let share = ShareCoordinator.shared.existingShare(for: sheet)
            candidates.formUnion(userProfile.canonicalSelfIDs(forShare: share))
        }
        guard !candidates.isEmpty else { return nil }
        return profiles.first(where: {
            guard let rn = $0.recordName, !rn.isEmpty else { return false }
            return candidates.contains(rn)
        })
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
        // 参加者: CKShare の userIdentity.nameComponents (= Apple ID 名) を最優先。
        // 取れない場合のフォールバックとして PP > email > phone > メンバー。
        if let nc = participant.userIdentity.nameComponents {
            let formatted = PersonNameComponentsFormatter().string(from: nc)
            if !formatted.isEmpty { return formatted }
        }
        if let n = participantProfile?.displayName, !n.isEmpty {
            return n
        }
        if let info = participant.userIdentity.lookupInfo {
            if let email = info.emailAddress { return email }
            if let phone = info.phoneNumber { return phone }
        }
        return "メンバー"
    }

    private var secondaryText: String? {
        if isSelf {
            return emailAddress
        }
        // CKShare の nameComponents が取れて表示している場合は email を補助行に
        if participant.userIdentity.nameComponents != nil {
            return emailAddress
        }
        return nil
    }

    private var avatarColorHex: String {
        if isSelf, let hex = userProfile.avatarBgColorHex, !hex.isEmpty {
            return hex
        }
        if let hex = participantProfile?.colorHex, !hex.isEmpty {
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
                        if participant.role == .owner {
                            Text("オーナー")
                        } else {
                            // CloudKit のロール (privateUser/publicUser) は内部的な区分で
                            // ユーザーには無意味かつ「非公開?」と誤解を招くため表示しない。
                            // 意味のある参加状況 (招待中 / 参加済み) だけを出す。
                            Text(statusText)
                                .foregroundStyle(participant.acceptanceStatus == .pending ? .orange : .secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
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

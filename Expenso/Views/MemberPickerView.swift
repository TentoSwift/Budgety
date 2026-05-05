//
//  MemberPickerView.swift
//  Expenso
//

import SwiftUI
import CoreData
import CloudKit

struct MemberPickerView: View {
    @Binding var selected: Member?
    /// 渡されたら、シートのオーナー + 参加者だけを表示する。nil なら自分のみ。
    let record: ExpenseSheet?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @State private var share: CKShare?

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Member.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \Member.createdAt, ascending: true)
        ],
        animation: .default
    ) private var allMembers: FetchedResults<Member>

    init(selected: Binding<Member?>, record: ExpenseSheet? = nil) {
        self._selected = selected
        self.record = record
    }

    /// 自分の Member (UserProfileStore.selfMemberID または displayName 一致)
    private var selfMember: Member? {
        if let id = profile.selfMemberID, let m = allMembers.first(where: { $0.id == id }) {
            return m
        }
        return allMembers.first(where: { $0.name == profile.resolvedDisplayName })
    }

    /// CKShare に居る、自分以外の参加者 (オーナー含む)
    private var otherParticipants: [CKShare.Participant] {
        guard let share = share else { return [] }
        let myUserID = share.currentUserParticipant?.userIdentity.userRecordID
        return share.participants.filter { p in
            p.userIdentity.userRecordID != myUserID
        }
    }

    var body: some View {
        List {
            unspecifiedSection
            // Member の有無に依存せず、UserProfileStore のプロフィールから直接「自分」を表示。
            // 選択時に Member を ensure する。
            selfFromProfileSection
            if !otherParticipants.isEmpty { otherParticipantsSection }
        }
        .navigationTitle("支払者を選択")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: record?.objectID) {
            await loadShare()
        }
        // CKShare の参加者更新もここで拾って再描画させる
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            Task { await loadShare() }
        }
    }

    private var unspecifiedSection: some View {
        Section {
            Button {
                selected = nil
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: 36, height: 36)
                        Image(systemName: "questionmark")
                            .foregroundStyle(.secondary)
                    }
                    Text("未選択")
                        .foregroundStyle(.primary)
                    Spacer()
                    if selected == nil {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// 既存 Member があればそれを観測ベースで描画。無ければ UserProfileStore から直接表示し、
    /// タップで Member を ensure (作成 or 更新) してから selected に設定。
    @ViewBuilder
    private var selfFromProfileSection: some View {
        Section {
            if let me = selfMember {
                Button {
                    selected = me
                    dismiss()
                } label: {
                    selfRowContent(
                        avatar: AnyView(ObservedMemberAvatar(member: me, size: 36)),
                        name: me.displayName,
                        isSelected: selected?.objectID == me.objectID
                    )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    ensureSelfMemberAndSelect()
                } label: {
                    selfRowContent(
                        avatar: AnyView(AvatarView(
                            photoData: profile.photoData,
                            displayName: profile.resolvedDisplayName,
                            colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                            size: 36
                        )),
                        name: profile.resolvedDisplayName,
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func selfRowContent(avatar: AnyView, name: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            avatar
            Text(name)
                .foregroundStyle(.primary)
            Text("自分")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }

    private func ensureSelfMemberAndSelect() {
        // applyToSelfMember が selfMemberID を保証 + Member を作成/更新する
        profile.applyToSelfMember(in: viewContext)
        if let id = profile.selfMemberID,
           let me = allMembers.first(where: { $0.id == id }) {
            selected = me
        }
        dismiss()
    }

    private var otherParticipantsSection: some View {
        Section {
            ForEach(otherParticipants, id: \.userIdentity.userRecordID) { p in
                participantRow(p)
            }
        } header: {
            Text("シートのメンバー")
        } footer: {
            Text("支払者として記録できるのはこのシートのオーナーと参加者のみです。")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func participantRow(_ p: CKShare.Participant) -> some View {
        let info = participantDisplayInfo(p)
        let isSelected = selected?.name == info.name
        Button {
            selectFromParticipant(info)
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: info.name, colorHex: info.colorHex, photoData: info.photoData, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .foregroundStyle(.primary)
                    Text(p.role == .owner ? "オーナー" : (p.acceptanceStatus == .pending ? "招待中" : "参加者"))
                        .font(.caption2)
                        .foregroundStyle(p.acceptanceStatus == .pending ? .orange : .secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private struct ParticipantInfo {
        let name: String
        let colorHex: String
        let photoData: Data?
    }

    /// 同シート配下の ParticipantProfile を recordName 一致で引く
    private func participantProfile(for p: CKShare.Participant) -> ParticipantProfile? {
        guard let record = record,
              let rn = p.userIdentity.userRecordID?.recordName,
              !rn.isEmpty, rn != "_defaultOwner_", rn != "__defaultOwner__",
              let profiles = record.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == rn })
    }

    private func participantDisplayInfo(_ p: CKShare.Participant) -> ParticipantInfo {
        let pp = participantProfile(for: p)
        let name: String = {
            if let n = pp?.displayName, !n.isEmpty { return n }
            if let nc = p.userIdentity.nameComponents {
                let formatted = PersonNameComponentsFormatter().string(from: nc)
                if !formatted.isEmpty { return formatted }
            }
            if let email = p.userIdentity.lookupInfo?.emailAddress, !email.isEmpty { return email }
            return p.role == .owner ? "オーナー" : "メンバー"
        }()
        let color = (pp?.colorHex).flatMap { $0.isEmpty ? nil : $0 } ?? "#8E8E93"
        return ParticipantInfo(name: name, colorHex: color, photoData: pp?.photoData)
    }

    /// 参加者を選択した時、ローカルに同名 Member が居れば再利用、なければ作成して `selected` に紐づける。
    /// (Expense.paidBy には文字列が保存されるだけなので、Member を作る目的は UI 上の選択状態保持)
    private func selectFromParticipant(_ info: ParticipantInfo) {
        if let existing = allMembers.first(where: { $0.name == info.name }) {
            selected = existing
        } else {
            let m = Member(context: viewContext)
            m.id = UUID()
            m.name = info.name
            m.colorHex = info.colorHex
            m.photoData = info.photoData
            m.sortOrder = (allMembers.map(\.sortOrder).max() ?? -1) + 1
            m.createdAt = .now
            PersistenceController.shared.save()
            selected = m
        }
        dismiss()
    }

    @MainActor
    private func loadShare() async {
        guard let record = record else {
            share = nil
            return
        }
        share = ShareCoordinator.shared.existingShare(for: record)
        // ParticipantProfile は CloudKit Sharing 経由で自動同期されるためここでは何もしない
    }
}


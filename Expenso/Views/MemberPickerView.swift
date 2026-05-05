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
    @ObservedObject private var profileCache = RemoteProfileCache.shared

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
            if let me = selfMember { selfSection(me) }
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

    private func selfSection(_ me: Member) -> some View {
        Section {
            Button {
                selected = me
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    AvatarView(member: me, size: 36)
                    Text(me.displayName)
                        .foregroundStyle(.primary)
                    Text("自分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if selected?.objectID == me.objectID {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
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

    private func participantDisplayInfo(_ p: CKShare.Participant) -> ParticipantInfo {
        let recordName = p.userIdentity.userRecordID?.recordName
        let cached: RemoteProfileCache.CachedProfile? = recordName.flatMap {
            $0.isEmpty || $0 == "_defaultOwner_" || $0 == "__defaultOwner__" ? nil : profileCache.profile(for: $0)
        }
        let name: String = {
            if let n = cached?.displayName, !n.isEmpty { return n }
            if let nc = p.userIdentity.nameComponents {
                let formatted = PersonNameComponentsFormatter().string(from: nc)
                if !formatted.isEmpty { return formatted }
            }
            if let email = p.userIdentity.lookupInfo?.emailAddress, !email.isEmpty { return email }
            return p.role == .owner ? "オーナー" : "メンバー"
        }()
        let color = (cached?.colorHex).flatMap { $0.isEmpty ? nil : $0 } ?? "#8E8E93"
        return ParticipantInfo(name: name, colorHex: color, photoData: cached?.photoData)
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
        // 参加者プロフィールをキャッシュへ取得
        if let share = share {
            let names = share.participants.compactMap { $0.userIdentity.userRecordID?.recordName }
                .filter { !$0.isEmpty && $0 != "_defaultOwner_" && $0 != "__defaultOwner__" }
            await profileCache.fetchIfStale(names)
        }
    }
}


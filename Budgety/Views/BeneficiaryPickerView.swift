//
//  BeneficiaryPickerView.swift
//  Expenso
//
//  支出を誰の負担として扱うか (受益者) を複数選択するピッカー。
//  内部表現は profileID (= UserProfileStore.userRecordName / ParticipantProfile.recordName) の Set。
//

import SwiftUI
import CoreData
import CloudKit

struct BeneficiaryPickerView: View {
    @Binding var selected: Set<String>
    let record: ExpenseSheet

    @Environment(\.dismiss) private var dismiss
    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pub = PublicProfileSync.shared
    @State private var share: CKShare?

    /// 自分の canonical 自己 ID (オーナーなら userRecordName、参加者なら "email:...")
    private var selfProfileID: String? {
        let id = profile.canonicalSelfID(forShare: share) ?? profile.userRecordName
        return (id?.isEmpty == false) ? id : nil
    }

    /// 自分の取りうるすべての ID 集合 (canonical + 旧 userRecordName + cross-device 履歴)。
    /// PP の recordName がこの集合に含まれるなら「自分」と判定して others から除外する。
    private var selfIDSet: Set<String> {
        profile.canonicalSelfIDs(forShare: share)
    }

    /// 自分以外の参加者 (オーナー含む)。URN ベースで dedup。
    /// iCloud Extended Share Access エンタイトルメントで URN が全 viewer に
    /// 一意に見えるので、PP.recordName (= URN) と一致させて Apple ID 名が出るようにする。
    private var otherProfileIDs: [String] {
        var result: [String] = []
        var seen = Set<String>()
        // 「自分」とみなされる ID は全部 seen に入れて others から除外する
        for id in selfIDSet { seen.insert(id) }
        if let myID = selfProfileID { seen.insert(myID) }

        // CKShare ロード済 → participants を source of truth として使う
        // (共有解除済み・未参加 (.pending) のメンバーは picker に出さない)
        if let share {
            for p in share.participants {
                guard p.acceptanceStatus == .accepted else { continue }
                let rn = p.userIdentity.userRecordID?.recordName ?? ""
                guard !rn.isEmpty,
                      !UserProfileStore.isSelfPlaceholderRecordName(rn),
                      seen.insert(rn).inserted else { continue }
                result.append(rn)
            }
        } else {
            // CKShare 未ロード時のみ PP フォールバック
            let profiles = (record.participantProfiles as? Set<ParticipantProfile>) ?? []
            for pp in profiles.sorted(by: { ($0.displayName ?? "") < ($1.displayName ?? "") }) {
                guard let rn = pp.recordName,
                      !rn.isEmpty,
                      rn != "_defaultOwner_", rn != "__defaultOwner__",
                      seen.insert(rn).inserted else { continue }
                result.append(rn)
            }
        }
        return result
    }

    var body: some View {
        List {
            Section {
                Button("全員選択") { selectAll() }
                    .disabled(allSelected)
                Button("全員解除") { selected.removeAll() }
                    .foregroundStyle(.red)
                    .disabled(selected.isEmpty)
            } footer: {
                Text("チェックを入れたメンバーで支出額を均等に割って精算します。全員未選択の場合は「全員均等割り」として扱います。")
                    .font(.caption2)
            }

            if let myID = selfProfileID {
                Section {
                    row(profileID: myID, isSelf: true)
                }
            }

            if !otherProfileIDs.isEmpty {
                Section("シートのメンバー") {
                    ForEach(otherProfileIDs, id: \.self) { id in
                        row(profileID: id, isSelf: false)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("受益者を選択")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: record.objectID) {
            await loadShare()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            Task { await loadShare() }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了", systemImage: "checkmark") { dismiss() }
            }
        }
    }

    private var allMemberIDs: [String] {
        var ids: [String] = []
        if let me = selfProfileID { ids.append(me) }
        ids.append(contentsOf: otherProfileIDs)
        return ids
    }

    private var allSelected: Bool {
        let all = allMemberIDs
        return !all.isEmpty && all.allSatisfy { selected.contains($0) }
    }

    private func selectAll() {
        for id in allMemberIDs { selected.insert(id) }
    }

    @ViewBuilder
    private func row(profileID: String, isSelf: Bool) -> some View {
        let info = record.memberDisplayInfo(for: profileID)
        let isOn = selected.contains(profileID)
        Button {
            if isOn { selected.remove(profileID) } else { selected.insert(profileID) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    photoData: info.photoData,
                    displayName: info.name,
                    colorHex: info.colorHex,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).foregroundStyle(.primary)
                    if isSelf {
                        Text("自分").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadShare() async {
        share = ShareCoordinator.shared.existingShare(for: record)
    }
}

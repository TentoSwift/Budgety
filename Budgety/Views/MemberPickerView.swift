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
    /// 「支払」「受取」を切り替えるための種別 (タイトル等に使う)。
    let kind: TransactionKind
    /// 編集中の支出から渡される、保存済みの paidBy / payerProfileID。
    /// `selected` が nil でもこれと一致する行に「✓」を付けるための補助情報。
    let fallbackPaidBy: String?
    let fallbackProfileID: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pub = PublicProfileSync.shared

    @State private var share: CKShare?

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Member.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \Member.createdAt, ascending: true)
        ],
        animation: .default
    ) private var allMembers: FetchedResults<Member>

    init(selected: Binding<Member?>,
         record: ExpenseSheet? = nil,
         kind: TransactionKind = .expense,
         fallbackPaidBy: String? = nil,
         fallbackProfileID: String? = nil) {
        self._selected = selected
        self.record = record
        self.kind = kind
        self.fallbackPaidBy = fallbackPaidBy
        self.fallbackProfileID = fallbackProfileID
    }

    /// 自分の Member (UserProfileStore.selfMemberID または displayName 一致)
    private var selfMember: Member? {
        if let id = profile.selfMemberID, let m = allMembers.first(where: { $0.id == id }) {
            return m
        }
        return allMembers.first(where: { $0.name == profile.resolvedDisplayName })
    }

    /// 自分の per-sheet ParticipantProfile (= シート単位の override 含む)。
    /// row のアバター/名前を Member ではなく PP 由来で出すための参照。
    /// canonical (このシート用) と旧 userRecordName の両方にマッチさせる。
    private var selfPerSheetProfile: ParticipantProfile? {
        guard BuildInfo.profileFeatureEnabled else { return nil }
        guard let record,
              let profiles = record.participantProfiles as? Set<ParticipantProfile> else { return nil }
        var candidates: Set<String> = []
        if let urn = profile.userRecordName, !urn.isEmpty { candidates.insert(urn) }
        if let cid = profile.canonicalSelfID(forShare: share), !cid.isEmpty { candidates.insert(cid) }
        return profiles.first(where: {
            guard let rn = $0.recordName, !rn.isEmpty else { return false }
            return candidates.contains(rn)
        })
    }

    /// CKShare に居る、自分以外の参加者 (オーナー含む)。
    /// CKShare では「見ている本人」のエントリは userRecordID.recordName が
    /// `__defaultOwner__` placeholder に匿名化される。これをそのまま `!=` 比較すると
    /// 別人どうし両方が placeholder の場合誤マッチするので、placeholder 判定で除外する。
    /// 招待中で未参加 (.pending) の人は picker に出さない (= 払い者に選べないように)。
    private var otherParticipants: [CKShare.Participant] {
        guard let share = share else { return [] }
        return share.participants.filter { p in
            guard p.acceptanceStatus == .accepted else { return false }
            let rn = p.userIdentity.userRecordID?.recordName ?? ""
            return !UserProfileStore.isSelfPlaceholderRecordName(rn)
        }
    }

    var body: some View {
        List {
            unspecifiedSection
            // Member の有無に依存せず、UserProfileStore のプロフィールから直接「自分」を表示。
            // 選択時に Member を ensure する。
            selfFromProfileSection
            if !otherParticipants.isEmpty { otherParticipantsSection }
            virtualMembersSection
            if !legacyPayers.isEmpty { legacyPayersSection }
        }
        .listStyle(.plain)
        .navigationTitle(kind.partySelectionTitle)
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
                    // 他のメンバー行のアバター (size 36) と同じ @ScaledMetric スケーリングにする。
                    UnspecifiedAvatarView(size: 36)
                    Text("未選択")
                        .foregroundStyle(.primary)
                    Spacer()
                    // 真に未選択 = selected が nil AND 編集対象 Expense の payerProfileID も空。
                    // Member の解決に失敗しただけで fallbackProfileID が入っている場合は
                    // 他の行 (オーナー / 参加者 / legacy) で ✓ が付くため、ここには付けない。
                    if selected == nil && (fallbackProfileID ?? "").isEmpty {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// 自分が選択中かを判定する。canonical self ID (このシート用) と、
    /// backward compat のための旧 `userRecordName` の両方にマッチさせる。
    /// 後者は MacB のように CKContainer.userRecordID() がオーナー側 CKShare の
    /// participant.userIdentity.userRecordID と一致しないケースで残された旧 Expense を
    /// 「自分」として認識できるようにするため。
    private func selfRowIsSelected(_ me: Member) -> Bool {
        let selfIDs = profile.canonicalSelfIDs(forShare: share)
        if let s = selected {
            // objectID 一致は厳密一致なので残す
            if s.objectID == me.objectID { return true }
            if let srn = s.recordName, !srn.isEmpty, selfIDs.contains(srn) { return true }
            return false
        }
        // selected == nil (= 編集モードで未読込) の時は Expense.payerProfileID で判定
        if let pid = fallbackProfileID, !pid.isEmpty, selfIDs.contains(pid) { return true }
        return false
    }

    /// 自分の row を描画。シート単位の PP があれば PP を最優先 (= per-sheet override が効く)、
    /// 無ければローカル Member、それも無ければ UserProfileStore から直接表示する。
    @ViewBuilder
    private var selfFromProfileSection: some View {
        Section {
            if let me = selfMember {
                let pp = selfPerSheetProfile
                Button {
                    selected = me
                    dismiss()
                } label: {
                    selfRowContent(
                        avatar: pp.map { AnyView(ObservedParticipantProfileAvatar(profile: $0, size: 36)) }
                            ?? AnyView(ObservedMemberAvatar(member: me, size: 36)),
                        name: pp.flatMap { $0.displayName?.isEmpty == false ? $0.displayName : nil } ?? me.displayName,
                        isSelected: selfRowIsSelected(me)
                    )
                }
                .buttonStyle(.plain)
            } else {
                let pp = selfPerSheetProfile
                Button {
                    ensureSelfMemberAndSelect()
                } label: {
                    selfRowContent(
                        avatar: pp.map { AnyView(ObservedParticipantProfileAvatar(profile: $0, size: 36)) }
                            ?? AnyView(AvatarView(
                                photoData: profile.photoData,
                                displayName: profile.resolvedDisplayName,
                                colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                                size: 36
                            )),
                        name: pp.flatMap { $0.displayName?.isEmpty == false ? $0.displayName : nil } ?? profile.resolvedDisplayName,
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name)
                        .foregroundStyle(.primary)
                    Text("自分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }

    private func ensureSelfMemberAndSelect() {
        // ローカル Member を確保 (selfMemberID キャッシュも更新される)
        profile.ensureSelfMemberExists(in: viewContext)
        if let id = profile.selfMemberID,
           let me = allMembers.first(where: { $0.id == id }) {
            // このシート用の canonical self ID を Member.recordName に書き込んでおく。
            // 呼び出し側 (AddExpenseView 等) は `selected.recordName` を
            // expense.payerProfileID に転写するので、ここで canonical を入れておくと
            // 共有先からも自分として正しく解決される。
            if let cid = profile.canonicalSelfID(forShare: share), me.recordName != cid {
                me.recordName = cid
                me.updatedAt = .now
                try? viewContext.save()
            }
            selected = me
        }
        dismiss()
    }

    /// シートに紐付く Expense / RecurringRule / Template の paidBy 集合から、
    /// 自分の userRecordName / CKShare 参加者 / Member.recordName のいずれにも該当しない
    /// 名前 (= 「過去の支払者」) を抽出する。
    /// 値は表示名のソート済み配列。重複は名前単位で除外。
    private var legacyPayers: [LegacyPayerInfo] {
        guard let record else { return [] }
        let selfIDs = profile.canonicalSelfIDs(forShare: share)
        let participantIDs = Set(otherParticipants.compactMap { $0.budgetyCanonicalID })
        let participantNames = Set(otherParticipants.map { participantDisplayInfo($0).name })
        let selfNames = Set([profile.resolvedDisplayName, "自分"])
        let memberRecordNames = Set(allMembers.compactMap { $0.recordName }.filter { !$0.isEmpty })

        // シート配下の Expense の (paidBy, payerProfileID) ペアを集める
        var byName: [String: LegacyPayerInfo] = [:]
        let expenseReq = NSFetchRequest<Expense>(entityName: "Expense")
        expenseReq.predicate = NSPredicate(format: "sheet == %@", record)
        let expenses = (try? viewContext.fetch(expenseReq)) ?? []
        for e in expenses {
            let name = (e.paidBy ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let pid = e.payerProfileID ?? ""
            // 自分 / 既知参加者 / 既知 Member.recordName と被るものはスキップ
            if !pid.isEmpty, selfIDs.contains(pid) { continue }
            if !pid.isEmpty, participantIDs.contains(pid) { continue }
            if !pid.isEmpty, memberRecordNames.contains(pid) { continue }
            if selfNames.contains(name) { continue }
            if participantNames.contains(name) { continue }
            if byName[name] == nil {
                byName[name] = LegacyPayerInfo(name: name, profileID: pid.isEmpty ? nil : pid, memberID: e.payerMemberID)
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    private var legacyPayersSection: some View {
        Section {
            ForEach(legacyPayers) { info in
                Button {
                    selectLegacyPayer(info)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.platformTertiarySystemBackground)
                                .frame(width: 36, height: 36)
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name)
                                .foregroundStyle(.primary)
                            Text("過去の記録")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if legacyRowIsSelected(info) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    mergeMenuItems(for: info)
                }
            }
        } header: {
            Text("過去の支払者")
        } footer: {
            Text("現在のシート参加者にいない名前で記録された支出があります。タップして選び直すか、行を長押し (右クリック) して「○○に統合する」を選んで一括正規化できます。")
                .font(.caption2)
        }
    }

    /// 「過去の支払者」行の context menu。シート参加者と自分を統合先候補として並べる。
    @ViewBuilder
    private func mergeMenuItems(for info: LegacyPayerInfo) -> some View {
        // 「自分に統合」: このシート向けの canonical self ID を使う
        if let myCID = profile.canonicalSelfID(forShare: share), !myCID.isEmpty {
            Button {
                mergeLegacyPayer(info, toRecordName: myCID, toName: profile.resolvedDisplayName, toMemberID: profile.selfMemberID)
            } label: {
                Label("\(profile.resolvedDisplayName) (自分) に統合", systemImage: "arrow.merge")
            }
        }
        // 参加者ごとに「○○に統合」
        ForEach(otherParticipants, id: \.userIdentity.userRecordID) { p in
            let pInfo = participantDisplayInfo(p)
            if let rn = pInfo.recordName {
                Button {
                    let matchedMember = allMembers.first(where: { $0.recordName == rn })
                    mergeLegacyPayer(info, toRecordName: rn, toName: pInfo.name, toMemberID: matchedMember?.id)
                } label: {
                    Label("\(pInfo.name) に統合", systemImage: "arrow.merge")
                }
            }
        }
        Divider()
        Button(role: .destructive) {
            clearLegacyPayer(info)
        } label: {
            Label("支払者を未選択に戻す", systemImage: "xmark.circle")
        }
    }

    /// シート配下の Expense / RecurringRule / Template のうち、`legacy` と一致する payer 情報を持つものを
    /// 一括で `(recordName, name, memberID)` に書き換える。
    @MainActor
    private func mergeLegacyPayer(_ legacy: LegacyPayerInfo, toRecordName: String, toName: String, toMemberID: UUID?) {
        guard let record else { return }
        let expReq = NSFetchRequest<Expense>(entityName: "Expense")
        expReq.predicate = NSPredicate(format: "sheet == %@", record)
        let expenses = (try? viewContext.fetch(expReq)) ?? []
        var didChange = false
        for e in expenses where matchesLegacy(e.paidBy, e.payerProfileID, e.payerMemberID, legacy) {
            e.paidBy = toName
            e.payerProfileID = toRecordName
            e.payerMemberID = toMemberID
            didChange = true
        }
        if didChange {
            PersistenceController.shared.save()
            Haptics.success()
        }
        dismiss()
    }

    /// 「未選択」に戻す。シート配下で legacy と一致する Expense の payer 情報を空にする。
    @MainActor
    private func clearLegacyPayer(_ legacy: LegacyPayerInfo) {
        guard let record else { return }
        let expReq = NSFetchRequest<Expense>(entityName: "Expense")
        expReq.predicate = NSPredicate(format: "sheet == %@", record)
        let expenses = (try? viewContext.fetch(expReq)) ?? []
        var didChange = false
        for e in expenses where matchesLegacy(e.paidBy, e.payerProfileID, e.payerMemberID, legacy) {
            e.paidBy = ""
            e.payerProfileID = ""
            e.payerMemberID = nil
            didChange = true
        }
        if didChange {
            PersistenceController.shared.save()
            Haptics.warning()
        }
        dismiss()
    }

    private func matchesLegacy(_ paidBy: String?, _ profileID: String?, _ memberID: UUID?, _ legacy: LegacyPayerInfo) -> Bool {
        if let mid = legacy.memberID, mid == memberID { return true }
        if let pid = legacy.profileID, !pid.isEmpty, pid == (profileID ?? "") { return true }
        if (paidBy ?? "") == legacy.name { return true }
        return false
    }


    /// legacy 行が選択中かを判定する。identity は profileID (= recordName) 一致のみで判断する。
    /// 名前一致や memberID 一致は採用しない。
    private func legacyRowIsSelected(_ info: LegacyPayerInfo) -> Bool {
        guard let pid = info.profileID, !pid.isEmpty else { return false }
        if let s = selected {
            if let srn = s.recordName, !srn.isEmpty, srn == pid { return true }
            return false
        }
        if let fp = fallbackProfileID, !fp.isEmpty, fp == pid { return true }
        return false
    }

    /// 「過去の支払者」を選択 = 対応する Member を resolve (or ensure) して selected に紐づける。
    /// その Expense を保存し直せば payerProfileID は変わらないが、明示的にこの行を「現在の支払者」
    /// として固定する効果がある。ユーザーは別の参加者を選び直すことで、データを正規化できる。
    private func selectLegacyPayer(_ info: LegacyPayerInfo) {
        // 既存 Member を探す: memberID → recordName → 名前一致
        var found: Member?
        if let mid = info.memberID {
            found = allMembers.first(where: { $0.id == mid })
        }
        if found == nil, let pid = info.profileID, !pid.isEmpty {
            found = allMembers.first(where: { $0.recordName == pid })
        }
        if found == nil {
            found = allMembers.first(where: { $0.name == info.name })
        }
        if let m = found {
            selected = m
        } else {
            // 何も無ければ作る (= UI でも見えるように)
            let m = Member(context: viewContext)
            m.id = UUID()
            m.name = info.name
            m.colorHex = "#8E8E93"
            m.recordName = info.profileID
            m.sortOrder = (allMembers.map(\.sortOrder).max() ?? -1) + 1
            m.createdAt = .now
            PersistenceController.shared.save()
            selected = m
        }
        dismiss()
    }

    private struct LegacyPayerInfo: Identifiable, Hashable {
        let name: String
        let profileID: String?
        let memberID: UUID?
        var id: String { (profileID?.isEmpty == false ? profileID! : "name:") + name }
    }

    private var otherParticipantsSection: some View {
        Section {
            ForEach(otherParticipants, id: \.userIdentity.userRecordID) { p in
                participantRow(p)
            }
        } header: {
            Text("シートのメンバー")
        } footer: {
            Text("\(kind.partyLabel)として記録できるのはこのシートのオーナー・参加者・バーチャルメンバーです。")
                .font(.caption2)
        }
    }

    /// バーチャルメンバー (アプリ未使用の相手) を支払者候補として選べるセクション。
    @ViewBuilder
    private var virtualMembersSection: some View {
        if let record, !record.virtualMemberProfiles.isEmpty {
            Section {
                ForEach(record.virtualMemberProfiles, id: \.objectID) { pp in
                    let name = pp.displayNameOrEmpty.isEmpty ? "メンバー" : pp.displayNameOrEmpty
                    let isSelected = (selected?.recordName ?? "") == (pp.recordName ?? "")
                        || (selected == nil && (fallbackProfileID ?? "") == (pp.recordName ?? ""))
                    Button {
                        selectFromParticipant(ParticipantInfo(
                            name: name,
                            colorHex: pp.displayColorHex,
                            photoData: pp.photoData,
                            recordName: pp.recordName
                        ))
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: name, colorHex: pp.displayColorHex, photoData: pp.photoData, size: 36)
                            Text(name).foregroundStyle(.primary)
                            Spacer()
                            if isSelected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("バーチャルメンバー")
            }
        }
    }

    /// 参加者行が選択中かを判定する。identity は participant の canonical ID と
    /// `selected.recordName` (または `fallbackProfileID`) の一致のみで判断する。
    /// 名前一致による fallback は採用しない (= 別人の同名衝突を避ける)。
    private func participantRowIsSelected(_ p: CKShare.Participant, info: ParticipantInfo) -> Bool {
        guard let cid = p.budgetyCanonicalID, !cid.isEmpty else { return false }
        if let s = selected {
            if let memberRN = s.recordName, !memberRN.isEmpty, memberRN == cid { return true }
            return false
        }
        if let pid = fallbackProfileID, !pid.isEmpty, pid == cid { return true }
        return false
    }

    @ViewBuilder
    private func participantRow(_ p: CKShare.Participant) -> some View {
        let info = participantDisplayInfo(p)
        let isSelected = participantRowIsSelected(p, info: info)
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
        /// CKShare 参加者の userRecordName。Member.recordName に保存し、
        /// Expense.payerProfileID として永続化することで、シート参加者間で
        /// 払った相手を一意に同期できる。
        let recordName: String?
    }

    /// 同シート配下の ParticipantProfile を canonical ID 一致で引く。
    /// PP.recordName は canonical (オーナーなら userRecordName、参加者なら "email:...")
    /// で書かれているため、raw userRecordID では一致しないことに注意。
    private func participantProfile(for p: CKShare.Participant) -> ParticipantProfile? {
        guard BuildInfo.profileFeatureEnabled else { return nil }
        guard let record = record,
              let cid = p.budgetyCanonicalID, !cid.isEmpty,
              let profiles = record.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == cid })
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
        return ParticipantInfo(name: name, colorHex: color, photoData: pp?.photoData, recordName: p.budgetyCanonicalID)
    }

    /// 参加者を選択した時、ローカルに対応する Member が居れば再利用、なければ作成して `selected` に紐づける。
    /// 既存 Member のマッチは recordName 優先 (= CKShare ID 一致) で行い、無ければ同名フォールバック。
    /// 新規作成時は recordName を保存することで、Expense.payerProfileID として正しく一意な
    /// 識別子が永続化され、精算画面で他端末からも解決できるようになる。
    private func selectFromParticipant(_ info: ParticipantInfo) {
        let matched: Member? = {
            // recordName があるとき (バーチャルメンバー / CKShare 参加者) は recordName 一致のみで
            // 解決する。一致が無ければ新規作成に回し、同名の別メンバーへ名前フォールバックで
            // 誤マッチ (別人を支払者にする / 別人 Member の recordName を上書きする) のを防ぐ。
            if let rn = info.recordName, !rn.isEmpty {
                return allMembers.first(where: { $0.recordName == rn })
            }
            // recordName を持たない旧データのみ名前一致でフォールバックする。
            return allMembers.first(where: { $0.name == info.name })
        }()
        if let existing = matched {
            // 既存 Member の denormalized プロフィール (名前/色/写真) を最新の ParticipantProfile
            // 値で上書きする。古いキャッシュが残ると Expense 表示で旧プロフィールが出てしまう。
            var changed = false
            if (existing.recordName ?? "").isEmpty, let rn = info.recordName, !rn.isEmpty {
                existing.recordName = rn
                changed = true
            }
            if existing.name != info.name {
                existing.name = info.name
                changed = true
            }
            if existing.colorHex != info.colorHex {
                existing.colorHex = info.colorHex
                changed = true
            }
            if existing.photoData != info.photoData {
                existing.photoData = info.photoData
                changed = true
            }
            if changed {
                existing.updatedAt = .now
                PersistenceController.shared.save()
            }
            selected = existing
        } else {
            let m = Member(context: viewContext)
            m.id = UUID()
            m.name = info.name
            m.colorHex = info.colorHex
            m.photoData = info.photoData
            m.recordName = info.recordName
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

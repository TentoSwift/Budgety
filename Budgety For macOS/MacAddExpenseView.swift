//
//  MacAddExpenseView.swift
//  Budgety For macOS
//
//  macOS 用のシンプルな支出追加・編集フォーム。
//  - title / amount / date / kind / category / note
//  - 支払い者 (payer): シートのメンバーから 1 人選択
//  - 受益者 (beneficiaries): シートのメンバーから複数選択 (空 = 全員均等割)
//

import SwiftUI
import CoreData
import CloudKit

struct MacAddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var pub = PublicProfileSync.shared

    let sheet: ExpenseSheet
    let expense: Expense?

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = .now
    @State private var kind: TransactionKind = .expense
    @State private var note: String = ""
    @State private var selectedCategory: ExpenseCategory?
    @State private var payerProfileID: String = ""
    @State private var selectedBeneficiaries: Set<String> = []
    @State private var didLoad: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var share: CKShare?

    // AI カテゴリ提案 (FoundationModels)
    @State private var aiCategorySuggestion: ExpenseCategory?
    @State private var isComputingAICategory: Bool = false
    @State private var aiSuggestTask: Task<Void, Never>?

    private var categories: [ExpenseCategory] {
        let set = (sheet.categories as? Set<ExpenseCategory>) ?? []
        return set
            .filter { $0.kind == kind }
            .sorted { ($0.sortOrder, $0.displayName) < ($1.sortOrder, $1.displayName) }
    }

    private var canSave: Bool {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) != nil
    }

    // MARK: - Members

    /// 自分の canonical ID。
    private var selfProfileID: String {
        let store = UserProfileStore.shared
        return store.canonicalSelfID(forShare: share) ?? store.userRecordName ?? ""
    }

    /// 「自分」とみなされる ID 集合 (canonical + 旧 URN)。dedup 用。
    private var selfIDSet: Set<String> {
        UserProfileStore.shared.canonicalSelfIDs(forShare: share)
    }

    /// 自分以外の参加者の URN (= userRecordID.recordName) 配列。
    /// iCloud Extended Share Access エンタイトルメントで URN が全 viewer に
    /// 一意に見えるようになったので、ID キーは URN で統一する。
    /// PP.recordName も hydrate 時に URN で書かれているので一致する。
    ///
    /// 重要: CKShare が取れている場合は **CKShare.participants を source of truth** とする。
    /// 解除済みのメンバーが PP に残っていても picker には出さない (= 「共有解除済の
    /// 人がまだ選択できる」バグの対策)。CKShare がまだ取れていない場合のみ PP に
    /// フォールバックする。
    private var otherProfileIDs: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for id in selfIDSet { seen.insert(id) }
        seen.insert(selfProfileID)
        if let share {
            // CKShare がある → participants だけを使う (PP は補完しない)
            // 招待中で未参加 (acceptanceStatus == .pending) のメンバーは選択させない。
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
            let pps = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
            for pp in pps.sorted(by: { ($0.displayName ?? "") < ($1.displayName ?? "") }) {
                guard let rn = pp.recordName, !rn.isEmpty,
                      rn != "_defaultOwner_", rn != "__defaultOwner__",
                      seen.insert(rn).inserted else { continue }
                result.append(rn)
            }
        }
        return result
    }

    /// 全メンバー (自分 + 他) の表示用 ID 配列。
    private var allMemberIDs: [String] {
        var ids: [String] = []
        if !selfProfileID.isEmpty { ids.append(selfProfileID) }
        ids.append(contentsOf: otherProfileIDs)
        return ids
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("種別", selection: $kind) {
                        Text("支出").tag(TransactionKind.expense)
                        Text("収入").tag(TransactionKind.income)
                    }
                    .pickerStyle(.segmented)
                }
                Section("タイトル") {
                    TextField("コンビニ、ランチ など", text: $title)
                }
                Section("金額 (\(sheet.resolvedDefaultCurrencyCode))") {
                    TextField("0", text: $amountText)
                        .onChange(of: amountText) { _, new in
                            // 全角数字 / 全角ピリオドを半角に正規化してから許可文字でフィルタ
                            let normalized = new
                                .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? new
                            let allowed = normalized
                                .filter { $0.isASCII && ($0.isNumber || $0 == ".") }
                            if allowed != new { amountText = allowed }
                        }
                }
                Section("日付") {
                    DatePicker("日付", selection: $date, displayedComponents: .date)
                }
                Section("カテゴリ") {
                    Picker("カテゴリ", selection: $selectedCategory) {
                        Text("未選択").tag(ExpenseCategory?.none)
                        ForEach(categories, id: \.objectID) { c in
                            Text(c.displayName).tag(Optional(c))
                        }
                    }
                }
                aiCategorySuggestionSection
                Section("支払い者") {
                    payerPicker
                }
                Section {
                    beneficiariesList
                } header: {
                    HStack {
                        Text("受益者")
                        Spacer()
                        Button(action: { selectAllBeneficiaries() }) {
                            Text("全員").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        Button(action: { selectedBeneficiaries.removeAll() }) {
                            Text("解除").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(selectedBeneficiaries.isEmpty)
                    }
                } footer: {
                    Text("選んだ人で均等割り。全員未選択の場合は「全員均等割り」として扱います。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("メモ (任意)") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
                if expense != nil {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("この支出を削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.never)

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("OK") { save() }
                    .keyboardShortcut(.return)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 560, height: 720)
        .confirmationDialog(
            "この支出を削除しますか？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) { deleteExpense() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("元に戻せません。")
        }
        .task { await loadShareAndDefaults() }
        .onChange(of: title) { _, newValue in
            kickAICategorySuggest(title: newValue)
        }
        .onChange(of: kind) { _, _ in
            aiSuggestTask?.cancel()
            aiSuggestTask = nil
            aiCategorySuggestion = nil
            isComputingAICategory = false
            kickAICategorySuggest(title: title)
        }
    }

    // MARK: - AI Category Suggestion

    @ViewBuilder
    private var aiCategorySuggestionSection: some View {
        if expense == nil {
            if isComputingAICategory {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(LinearGradient(
                                colors: [.purple, .pink, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                        Text("AI でカテゴリを推測中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            } else if let cat = aiCategorySuggestion,
                      selectedCategory?.objectID != cat.objectID {
                Section {
                    Button {
                        selectedCategory = cat
                        aiCategorySuggestion = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "apple.intelligence")
                                .foregroundStyle(Color.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Image(systemName: "apple.intelligence")) 提案")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    CategoryIconView(category: cat, size: 22)
                                    Text(cat.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                            }
                            Spacer()
                            Text("適用")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @MainActor
    private func kickAICategorySuggest(title: String) {
        aiSuggestTask?.cancel()
        aiSuggestTask = nil
        aiCategorySuggestion = nil
        isComputingAICategory = false

        guard expense == nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        guard CategoryAISuggestor.isAvailable else { return }

        let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let kindCats = cats.filter { c in
            let raw = c.kindRaw ?? ""
            return raw == kind.rawValue || (kind == .expense && raw.isEmpty)
        }
        let names = kindCats.map { $0.displayName }
        guard !names.isEmpty else { return }

        let snapshotKind = kind
        isComputingAICategory = true
        aiSuggestTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            let suggested = await CategoryAISuggestor.suggest(
                title: trimmed,
                kind: snapshotKind,
                categories: names
            )
            if Task.isCancelled { return }
            isComputingAICategory = false
            if let suggested,
               let match = kindCats.first(where: { $0.displayName == suggested }) {
                aiCategorySuggestion = match
            }
        }
    }

    // MARK: - Pickers

    @ViewBuilder
    private var payerPicker: some View {
        ForEach(allMemberIDs, id: \.self) { id in
            payerRow(id)
        }
    }

    private func payerRow(_ id: String) -> some View {
        let info = sheet.memberDisplayInfo(for: id)
        let isMe = selfIDSet.contains(id)
        let isOn = (payerProfileID == id)
        return Button {
            payerProfileID = id
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    photoData: info.photoData,
                    displayName: info.name,
                    colorHex: info.colorHex,
                    size: 28
                )
                Text(isMe ? "\(info.name) (自分)" : info.name)
                    .foregroundStyle(.primary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var beneficiariesList: some View {
        ForEach(allMemberIDs, id: \.self) { id in
            beneficiaryRow(id)
        }
    }

    private func beneficiaryRow(_ id: String) -> some View {
        let info = sheet.memberDisplayInfo(for: id)
        let isMe = selfIDSet.contains(id)
        let isOn = selectedBeneficiaries.contains(id)
        return Button {
            if isOn { selectedBeneficiaries.remove(id) }
            else    { selectedBeneficiaries.insert(id) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    photoData: info.photoData,
                    displayName: info.name,
                    colorHex: info.colorHex,
                    size: 28
                )
                Text(isMe ? "\(info.name) (自分)" : info.name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectAllBeneficiaries() {
        for id in allMemberIDs { selectedBeneficiaries.insert(id) }
    }

    // MARK: - Load / Save

    @MainActor
    private func loadShareAndDefaults() async {
        share = ShareCoordinator.shared.existingShare(for: sheet)
        await UserProfileStore.shared.ensureUserRecordNameLoaded()
        UserProfileStore.shared.hydrateParticipantProfilesFromShares(in: viewContext)
        guard !didLoad else { return }
        didLoad = true
        if let e = expense {
            title = e.displayTitle
            amountText = NSDecimalNumber(decimal: e.amountDecimal).stringValue
            date = e.date ?? .now
            kind = e.kind
            note = e.note ?? ""
            selectedCategory = e.category
            payerProfileID = e.payerProfileID ?? selfProfileID
            selectedBeneficiaries = Set(e.beneficiaryIDList)
        } else {
            selectedCategory = nil
            payerProfileID = selfProfileID
            selectedBeneficiaries = []
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) else { return }

        let profile = UserProfileStore.shared

        let target: Expense
        if let existing = expense {
            target = existing
        } else {
            target = Expense(context: viewContext)
            if let store = sheet.objectID.persistentStore {
                viewContext.assign(target, to: store)
            }
            target.sheet = sheet
            target.createdAt = .now
        }
        target.title = trimmed
        target.amount = NSDecimalNumber(decimal: amount)
        target.kindRaw = kind.rawValue
        target.currencyCode = sheet.resolvedDefaultCurrencyCode
        target.date = date
        target.note = note
        target.categoryRaw = selectedCategory?.name
        if let cat = selectedCategory,
           cat.objectID.persistentStore == sheet.objectID.persistentStore {
            target.category = cat
        } else {
            target.category = nil
        }
        // 支払い者
        target.payerProfileID = payerProfileID
        if selfIDSet.contains(payerProfileID), let mid = profile.selfMemberID {
            target.payerMemberID = mid
        } else {
            target.payerMemberID = nil
        }
        // 受益者 (ピッカーで選んだ ID をそのまま CSV に)
        target.beneficiaryIDList = Array(selectedBeneficiaries)

        PersistenceController.shared.save()
        dismiss()
    }

    private func deleteExpense() {
        guard let e = expense else { return }
        viewContext.delete(e)
        PersistenceController.shared.save()
        dismiss()
    }
}

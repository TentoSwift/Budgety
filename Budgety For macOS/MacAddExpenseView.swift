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

    private var categories: [ExpenseCategory] {
        let set = (sheet.categories as? Set<ExpenseCategory>) ?? []
        return set
            .filter { $0.kind == kind }
            .sorted { ($0.sortOrder, $0.displayName) < ($1.sortOrder, $1.displayName) }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
        && Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) != nil
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
    private var otherProfileIDs: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for id in selfIDSet { seen.insert(id) }
        seen.insert(selfProfileID)
        if let share {
            for p in share.participants {
                let rn = p.userIdentity.userRecordID?.recordName ?? ""
                guard !rn.isEmpty,
                      !UserProfileStore.isSelfPlaceholderRecordName(rn),
                      seen.insert(rn).inserted else { continue }
                result.append(rn)
            }
        }
        // PP からも補完 (CKShare がまだ取れていない場合のフォールバック)
        let pps = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
        for pp in pps.sorted(by: { ($0.displayName ?? "") < ($1.displayName ?? "") }) {
            guard let rn = pp.recordName, !rn.isEmpty,
                  rn != "_defaultOwner_", rn != "__defaultOwner__",
                  seen.insert(rn).inserted else { continue }
            result.append(rn)
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

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("保存") { save() }
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
                Circle()
                    .fill(Color(hex: info.colorHex) ?? .blue)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Text(String(info.name.first ?? "?").uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
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
                Circle()
                    .fill(Color(hex: info.colorHex) ?? .blue)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Text(String(info.name.first ?? "?").uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
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
        // 開いた時点で Apple ID 名 + CKShare nameComponents を強制 hydrate
        // (PP が未作成のタイミングで picker が "メンバー" のままになるのを防ぐ)
        await UserProfileStore.shared.ensureUserRecordNameLoaded()
        await UserProfileStore.shared.refreshAppleIDName()
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
            selectedCategory = categories.first
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

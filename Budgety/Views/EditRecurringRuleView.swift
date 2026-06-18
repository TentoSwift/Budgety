//
//  EditRecurringRuleView.swift
//  Expenso
//

import SwiftUI
import CoreData
import CloudKit

struct EditRecurringRuleView: View {
    enum Mode {
        case create(record: ExpenseSheet)
        case edit(rule: RecurringRule)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    let mode: Mode

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var kind: TransactionKind = .expense
    @State private var currencyCode: String = CurrencyCatalog.defaultCode
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var interval: Int = 1
    @State private var startDate: Date = .now
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = .now
    @State private var selectedCategory: ExpenseCategory?
    @State private var selectedPayer: Member?
    /// ユーザーが picker で明示的に「未選択」を選んだか。
    @State private var payerExplicitlyCleared: Bool = false
    @State private var note: String = ""
    @State private var didLoad: Bool = false

    /// 受益者 (誰の負担として扱うか) の profileID 集合。空 = 割り勘オフ (支払者単独負担)。
    @State private var selectedBeneficiaries: Set<String> = []
    /// 割り勘トグル。オフ = この定期項目は支払者のみの負担。
    @State private var splitEnabled: Bool = false
    /// バーチャルメンバー追加 (Premium 機能)。
    @State private var showAddMemberPrompt = false
    @State private var newMemberName = ""
    @State private var memberPaywall = false

    private var contextSheet: ExpenseSheet? {
        switch mode {
        case .create(let r): return r
        case .edit(let rule): return rule.sheet
        }
    }

    /// 現在のシートに対する CKShare (= 支払者の canonical ID 解決に使う)。非共有なら nil。
    @MainActor
    private var contextShare: CKShare? {
        contextSheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
    }

    /// Member に対応する per-sheet ParticipantProfile を引く。
    private func currentParticipantProfile(for member: Member) -> ParticipantProfile? {
        guard let rn = member.recordName, !rn.isEmpty,
              rn != "_defaultOwner_", rn != "__defaultOwner__",
              let sheet = contextSheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == rn })
    }

    /// 自分の per-sheet ParticipantProfile (= 未選択時のデフォルト候補表示用)。
    /// canonical (このシート用) と旧 userRecordName 両方にマッチさせる。
    @MainActor
    private var selfParticipantProfileInSheet: ParticipantProfile? {
        guard let sheet = contextSheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        var candidates: Set<String> = []
        if let urn = profile.userRecordName, !urn.isEmpty { candidates.insert(urn) }
        if let cid = profile.canonicalSelfID(forShare: contextShare), !cid.isEmpty { candidates.insert(cid) }
        return profiles.first(where: {
            guard let rn = $0.recordName, !rn.isEmpty else { return false }
            return candidates.contains(rn)
        })
    }

    private var amountDecimal: Decimal? {
        guard !amountText.isEmpty else { return nil }
        return Decimal(string: amountText)
    }

    // MARK: - Payer resolution (AddExpenseView と同じ semantics)

    /// 選択中の支払者の payerProfileID。シート文脈に応じた canonical を返す。
    @MainActor
    private var selectedPayerProfileID: String? {
        selectedPayer?.resolvedProfileID(forShare: contextShare)
    }

    /// 保存時に書き込むべき支払者 ID。selectedPayer が nil でも、明示クリアされて
    /// いなければ自分の canonical ID にフォールバックする。
    @MainActor
    private var effectivePayerProfileID: String? {
        if payerExplicitlyCleared { return nil }
        if let id = selectedPayerProfileID { return id }
        if let pp = selfParticipantProfileInSheet,
           let rn = pp.recordName, !rn.isEmpty { return rn }
        if let cid = profile.canonicalSelfID(forShare: contextShare), !cid.isEmpty { return cid }
        let urn = profile.userRecordName ?? ""
        return urn.isEmpty ? nil : urn
    }

    /// canonical ID が決まらない時の最終フォールバック (自分の表示名)。
    @MainActor
    private var effectivePaidByFallback: String? {
        if payerExplicitlyCleared { return nil }
        if selectedPayer != nil { return nil }
        if effectivePayerProfileID != nil { return nil }
        let name = profile.resolvedDisplayName
        return name.isEmpty ? nil : name
    }

    /// 編集モードで Member 解決ができなかった場合に表示する名前 (保存済みの paidBy)。
    private var payerFallbackName: String? {
        if case .edit(let rule) = mode {
            let n = rule.paidBy ?? ""
            return n.isEmpty ? nil : n
        }
        return nil
    }

    private var payerFallbackProfileID: String? {
        if case .edit(let rule) = mode {
            let p = rule.payerProfileID ?? ""
            return p.isEmpty ? nil : p
        }
        return nil
    }

    // MARK: - Sharing / split visibility

    /// シートに自分以外の参加者が居るか (= 共有中)。
    private var hasOtherParticipants: Bool {
        guard let sheet = contextSheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return false }
        let myRN = profile.userRecordName ?? ""
        return profiles.contains { p in
            let rn = p.recordName ?? ""
            return !rn.isEmpty && rn != myRN
        }
    }

    /// 編集中の定期項目に既に支払者 / 受益者の情報が入っているか。
    private var existingSharingInfo: Bool {
        guard case .edit(let rule) = mode else { return false }
        if let pid = rule.payerProfileID, !pid.isEmpty { return true }
        if let n = rule.paidBy, !n.isEmpty { return true }
        if let bs = rule.beneficiaryProfileIDs, !bs.isEmpty { return true }
        return false
    }

    /// 支払者 / 割り勘セクションを表示するか。共有中・既存共有データあり・Premium なら表示。
    private var shouldShowSharingFields: Bool {
        if hasOtherParticipants || existingSharingInfo { return true }
        if let sheet = contextSheet, PurchaseManager.hasPremiumAccess(to: sheet) { return true }
        return false
    }

    /// 現時点で payer が「未選択」として扱われているか。
    @MainActor
    private var payerEffectivelyUnselected: Bool {
        if selectedPayer != nil { return false }
        if payerExplicitlyCleared { return true }
        if case .edit(let rule) = mode {
            return (rule.payerProfileID ?? "").isEmpty && (rule.paidBy ?? "").isEmpty
        }
        return false
    }

    /// MemberPickerView 用の binding ラッパー。「未選択」を選んだら割り勘も解除する。
    private var pickerPayerBinding: Binding<Member?> {
        Binding(
            get: { selectedPayer },
            set: { newValue in
                payerExplicitlyCleared = (newValue == nil)
                if newValue == nil {
                    splitEnabled = false
                    selectedBeneficiaries.removeAll()
                }
                selectedPayer = newValue
            }
        )
    }

    // MARK: - Beneficiary (割り勘) helpers

    /// 受益者をインラインで選ぶ 1 行 (アバター + 名前 + チェック)。タップで選択をトグル。
    @ViewBuilder
    private func beneficiaryInlineRow(_ id: String, sheet: ExpenseSheet) -> some View {
        let info = sheet.memberDisplayInfo(for: id)
        let isOn = selectedBeneficiaries.contains(id)
        Button {
            if isOn { selectedBeneficiaries.remove(id) } else { selectedBeneficiaries.insert(id) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    photoData: info.photoData,
                    displayName: info.name,
                    colorHex: info.colorHex,
                    size: 32
                )
                Text(info.name).foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
    }

    /// 割り勘の「全員」: シートの全メンバーを受益者に追加。
    @MainActor
    private func selectAllBeneficiaries(sheet: ExpenseSheet) {
        for id in sheet.acceptedMemberProfileIDs() { selectedBeneficiaries.insert(id) }
    }

    /// 割り勘 picker に表示する ID 列。現メンバー + 既保存だが現メンバーに居ない人を末尾に。
    @MainActor
    private func beneficiaryPickerIDs(sheet: ExpenseSheet) -> [String] {
        var ids = sheet.acceptedMemberProfileIDs()
        var seen = Set(ids)
        for sb in selectedBeneficiaries where !sb.isEmpty && seen.insert(sb).inserted {
            ids.append(sb)
        }
        return ids
    }

    /// 永続化用のソート済み CSV (順序非依存で同値判定するため)。
    private var selectedBeneficiaryCSV: String {
        selectedBeneficiaries.sorted().joined(separator: ",")
    }

    /// 実際に保存する受益者 CSV。割り勘オフなら空 (= 支払者単独負担)。
    @MainActor
    private var effectiveBeneficiaryCSV: String {
        guard shouldShowSharingFields, splitEnabled else { return "" }
        return selectedBeneficiaryCSV
    }

    private var canSave: Bool {
        guard amountDecimal != nil,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // 割り勘オンで相手未選択は保存させない。
        if kind == .expense, shouldShowSharingFields, splitEnabled, selectedBeneficiaries.isEmpty {
            return false
        }
        return true
    }

    private var navTitle: String {
        switch mode {
        case .create: String(localized: "定期項目を追加")
        case .edit:   String(localized: "定期項目を編集")
        }
    }

    private var decimalKeypadNeeded: Bool {
        !["JPY", "KRW", "VND", "IDR"].contains(currencyCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("種別", selection: $kind) {
                        ForEach(TransactionKind.allCases) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("内容") {
                    TextField(kind == .expense ? "タイトル (例: Netflix, 家賃)" : "タイトル (例: 給料)", text: $title)
                    HStack(spacing: 6) {
                        Text(CurrencyCatalog.option(for: currencyCode).symbol)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .leading)
                        TextField("0", text: $amountText)
                            .keyboardType(decimalKeypadNeeded ? .decimalPad : .numberPad)
                            .font(.title3.monospacedDigit())
                            .onChange(of: amountText) { _, new in
                                let allowed = decimalKeypadNeeded
                                    ? new.filter { $0.isNumber || $0 == "." }
                                    : new.filter { $0.isNumber }
                                if allowed != new { amountText = allowed }
                            }
                    }
                    Picker("通貨", selection: $currencyCode) {
                        ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                            Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                        }
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #else
                    .pickerStyle(.navigationLink)
                    #endif
                }

                Section {
                    Picker("頻度", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    Stepper(value: $interval, in: 1...60) {
                        HStack {
                            Text("間隔")
                            Spacer()
                            Text(frequency.summary(interval: interval))
                                .foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("開始日", selection: $startDate, displayedComponents: [.date])
                    Toggle("終了日を設定", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("終了日", selection: $endDate, in: startDate..., displayedComponents: [.date])
                    }
                } header: {
                    Text("繰り返し")
                } footer: {
                    Text("開始日から指定の頻度で、過去〜今日までの未生成分を自動でシートに追加します。")
                }

                Section("カテゴリ") {
                    if let sheet = contextSheet {
                        NavigationLink {
                            CategoryPickerView(selected: $selectedCategory, record: sheet, kind: kind)
                        } label: {
                            HStack {
                                Text("カテゴリ")
                                Spacer()
                                if let cat = selectedCategory {
                                    CategoryIconView(category: cat, size: 24)
                                    Text(cat.displayName)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("未選択")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                payerSection

                if kind == .expense, shouldShowSharingFields, !payerEffectivelyUnselected, let sheet = contextSheet {
                    Section {
                        Toggle("割り勘", isOn: Binding(
                            get: { splitEnabled },
                            set: { on in
                                splitEnabled = on
                                // オンにした直後は全員を選択する (空 = 全員にはしない)。
                                if on, selectedBeneficiaries.isEmpty
                                    || selectedBeneficiaries == Set([selectedPayerProfileID ?? ""]) {
                                    selectAllBeneficiaries(sheet: sheet)
                                }
                            }
                        ))
                        if splitEnabled {
                            // 別画面に遷移せず、この場でメンバーを選ぶ (インライン)。
                            ForEach(beneficiaryPickerIDs(sheet: sheet), id: \.self) { id in
                                beneficiaryInlineRow(id, sheet: sheet)
                            }
                            Button {
                                if PurchaseManager.hasPremiumAccess(to: sheet) {
                                    showAddMemberPrompt = true
                                } else {
                                    memberPaywall = true
                                }
                            } label: {
                                Label("メンバーを追加", systemImage: "person.badge.plus")
                            }
                        }
                    } header: {
                        if splitEnabled {
                            HStack {
                                Text("受益者")
                                Spacer()
                                Button("全員") { selectAllBeneficiaries(sheet: sheet) }
                                    .font(.caption)
                                    .textCase(nil)
                                Button("クリア") { selectedBeneficiaries.removeAll() }
                                    .font(.caption)
                                    .textCase(nil)
                                    .disabled(selectedBeneficiaries.isEmpty)
                            }
                        }
                    } footer: {
                        if splitEnabled {
                            Text(selectedBeneficiaries.isEmpty
                                 ? "受益者を 1 人以上選んでください。"
                                 : "チェックした人で均等割りします。")
                                .foregroundStyle(selectedBeneficiaries.isEmpty ? Color.red : Color.secondary)
                        }
                    }
                }

                Section("メモ") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if case .edit(let rule) = mode {
                    Section {
                        Button(role: .destructive) {
                            viewContext.delete(rule)
                            PersistenceController.shared.save()
                            Haptics.warning()
                            dismiss()
                        } label: {
                            Label("削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("削除しても、過去に自動生成された支出/収入は残ります。")
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    #if os(macOS)
                    Button("完了") { save() }
                        .disabled(!canSave)
                    #else
                    Button("保存", systemImage: "checkmark") { save() }
                        .disabled(!canSave)
                    #endif
                }
            }
            .sheet(isPresented: $memberPaywall) { PaywallView() }
            .alert("メンバーを追加", isPresented: $showAddMemberPrompt) {
                TextField("名前", text: $newMemberName)
                Button("追加") {
                    if let sheet = contextSheet, let id = sheet.addVirtualMember(name: newMemberName) {
                        splitEnabled = true
                        selectedBeneficiaries.insert(id)
                    }
                    newMemberName = ""
                }
                Button("キャンセル", role: .cancel) { newMemberName = "" }
            } message: {
                Text("アプリを使っていない相手を割り勘・支払者に追加できます。")
            }
            .onAppear { loadIfNeeded() }
        }
    }

    // MARK: - Payer section

    @ViewBuilder
    private var payerSection: some View {
        Section {
            NavigationLink {
                MemberPickerView(
                    selected: pickerPayerBinding,
                    record: contextSheet,
                    kind: kind,
                    fallbackPaidBy: payerFallbackName,
                    fallbackProfileID: payerFallbackProfileID
                )
            } label: {
                LabeledContent(kind.partyLabel) {
                    payerPreview
                }
            }
        }
    }

    @ViewBuilder
    private var payerPreview: some View {
        HStack(spacing: 6) {
            payerPreviewContent
        }
    }

    @ViewBuilder
    private var payerPreviewContent: some View {
        if let m = selectedPayer {
            if let pp = currentParticipantProfile(for: m) {
                ObservedParticipantProfileAvatar(profile: pp, size: 24)
                Text(pp.displayName?.isEmpty == false ? pp.displayName! : m.displayName)
                    .foregroundStyle(.secondary)
            } else {
                ObservedMemberAvatar(member: m, size: 24)
                Text(m.displayName).foregroundStyle(.secondary)
            }
        } else if payerEffectivelyUnselected {
            unspecifiedPayerPreview
        } else if let name = payerFallbackName {
            AvatarView(name: name, colorHex: "#8E8E93", photoData: nil, size: 24)
            Text(name).foregroundStyle(.secondary)
        } else if let pp = selfParticipantProfileInSheet {
            ObservedParticipantProfileAvatar(profile: pp, size: 24)
            Text(pp.displayName?.isEmpty == false ? pp.displayName! : profile.resolvedDisplayName)
                .foregroundStyle(.secondary)
        } else {
            AvatarView(
                photoData: profile.photoData,
                displayName: profile.resolvedDisplayName,
                colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                size: 24
            )
            Text(profile.resolvedDisplayName).foregroundStyle(.secondary)
        }
    }

    /// payer が真に未指定の時の preview (？マーク dashed circle + 「未選択」)。
    private var unspecifiedPayerPreview: some View {
        Group {
            ZStack {
                Circle()
                    .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 24, height: 24)
                Image(systemName: "person.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text("未選択").foregroundStyle(.secondary)
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        profile.ensureSelfMemberExists(in: viewContext)

        switch mode {
        case .create(let record):
            currencyCode = record.resolvedDefaultCurrencyCode
            if selectedCategory == nil {
                let cats = (record.categories as? Set<ExpenseCategory>) ?? []
                let sorted = cats.sorted { $0.sortOrder < $1.sortOrder }
                selectedCategory = sorted.first(where: { $0.name == "食費" }) ?? sorted.first
            }
            if selectedPayer == nil, let id = profile.selfMemberID {
                let req = NSFetchRequest<Member>(entityName: "Member")
                req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                req.fetchLimit = 1
                selectedPayer = (try? viewContext.fetch(req))?.first
            }
        case .edit(let rule):
            title = rule.displayTitle
            amountText = NSDecimalNumber(decimal: rule.amountDecimal).stringValue
            kind = rule.kind
            currencyCode = rule.resolvedCurrencyCode
            frequency = rule.resolvedFrequency
            interval = rule.resolvedInterval
            startDate = rule.startDate ?? .now
            if let end = rule.endDate {
                hasEndDate = true
                endDate = end
            }
            note = rule.note ?? ""
            if let sheet = rule.sheet,
               let raw = rule.categoryRaw,
               let cats = sheet.categories as? Set<ExpenseCategory> {
                selectedCategory = cats.first(where: { $0.name == raw })
            }
            // 支払者は payerProfileID から解決 (自分 / 他メンバー両対応)。
            selectedPayer = rule.resolvedPayer

            // 割り勘 state 復元。受益者が「空」または「支払者ただ 1 人」なら割り勘オフ。
            selectedBeneficiaries = Set(rule.beneficiaryIDList)
            let loadedPayerID = rule.payerProfileID ?? ""
            let isPayerOnly = selectedBeneficiaries.isEmpty
                || (!loadedPayerID.isEmpty && selectedBeneficiaries == Set([loadedPayerID]))
            splitEnabled = !isPayerOnly
            // 割り勘オフ時は UI 上のチェック対象を「支払者ただ 1 人」に正規化しておく。
            if !splitEnabled, !loadedPayerID.isEmpty {
                selectedBeneficiaries = Set([loadedPayerID])
            }
        }
    }

    private func save() {
        guard let amountDecimal else { return }
        let pc = PersistenceController.shared

        switch mode {
        case .create(let record):
            let rule = RecurringRule(context: viewContext)
            // 親シートと同じストアに割り当て
            if let store = record.objectID.persistentStore {
                viewContext.assign(rule, to: store)
            }
            rule.id = UUID()
            rule.createdAt = .now
            rule.sheet = record
            apply(to: rule, amount: amountDecimal)
        case .edit(let rule):
            apply(to: rule, amount: amountDecimal)
        }
        pc.save()
        // 保存直後にも一回 generate を回して、startDate が今日以前ならすぐに反映
        RecurringExpenseGenerator.generateAll(in: viewContext)
        Haptics.success()
        dismiss()
    }

    private func apply(to rule: RecurringRule, amount: Decimal) {
        rule.title = title.trimmingCharacters(in: .whitespaces)
        rule.amount = NSDecimalNumber(decimal: amount)
        rule.kindRaw = kind.rawValue
        rule.currencyCode = currencyCode
        rule.categoryRaw = selectedCategory?.name
        rule.paidBy = effectivePaidByFallback
        rule.payerProfileID = effectivePayerProfileID
        rule.beneficiaryProfileIDs = effectiveBeneficiaryCSV
        rule.note = note
        rule.frequency = frequency.rawValue
        rule.interval = Int32(interval)
        rule.startDate = Calendar.current.startOfDay(for: startDate)
        rule.endDate = hasEndDate ? Calendar.current.startOfDay(for: endDate) : nil
    }
}

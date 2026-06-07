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
    /// ユーザーが実際に保存 (commit) / 削除した時に呼ばれる。仮想 occurrence を materialize して
    /// 編集する経路 (BudgetyMacSheetView) で、未 commit なら親が未保存行を破棄するために使う。
    var onCommit: (() -> Void)? = nil

    /// 定期項目から生成された支出を編集中に保存した時の適用範囲 (iOS と同じ 2 択)。
    private enum RecurringSaveScope {
        case thisOnly   // この 1 件だけ (定期から切り離して通常支出化)
        case all        // ルールを変更して全 occurrence に反映
    }
    /// 定期由来の支出を編集して保存ボタンを押した時に出す 2 択ダイアログ。
    @State private var showRecurringSaveChoice = false

    @State private var title: String = ""
    @State private var amountText: String = ""
    /// 新規追加時に金額へ初期フォーカスする (金額を先に入力)。
    @FocusState private var amountFocused: Bool
    @State private var currencyCode: String = CurrencyCatalog.defaultCode
    @State private var date: Date = .now
    @State private var kind: TransactionKind = .expense
    @State private var note: String = ""
    @State private var selectedCategory: ExpenseCategory?
    /// カテゴリの新規追加シート表示。
    @State private var showingNewCategory = false
    @State private var payerProfileID: String = ""
    @State private var selectedBeneficiaries: Set<String> = []
    /// 割り勘トグル。オフ = 支払者のみの負担 (受益者 = 支払者)。
    /// オン = `selectedBeneficiaries` で割る相手を選ぶ (空 = 全員均等)。
    @State private var splitEnabled: Bool = false
    /// バーチャルメンバー追加 (Premium 機能)。
    @State private var showAddMemberPrompt = false
    @State private var newMemberName = ""
    @State private var showMemberPaywall = false
    /// 名前変更対象の recordName。nil = 新規追加。
    @State private var editingMemberID: String?
    @State private var didLoad: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var share: CKShare?

    // CRDT 差分書き戻し用スナップショット (= 編集ロード時に保持し、保存時に変更があった
    // フィールドだけ書き戻す)。他端末が別フィールドを編集していた時の同時編集衝突を防ぐ。
    @State private var origTitle: String = ""
    @State private var origAmountText: String = ""
    @State private var origKindRaw: String = ""
    @State private var origCurrencyCode: String = ""
    @State private var origCategoryObjectID: NSManagedObjectID?
    @State private var origPayerProfileID: String = ""
    @State private var origDate: Date = .distantPast
    @State private var origNote: String = ""
    @State private var origBeneficiaryCSV: String = ""

    // カテゴリ提案 (出所は履歴学習 or FoundationModels だが、表示は「AI 提案」で統一)
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
        guard Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) != nil else { return false }
        // 割り勘オンのときは必ず 1 人以上選ぶ。空 (= 全員均等) を許すと、
        // あとで追加したメンバーが過去の支出に遡って含まれてしまうため。
        if hasOtherMembers, splitEnabled, selectedBeneficiaries.isEmpty {
            return false
        }
        return true
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
        // バーチャルメンバー (CKShare に出ない) を候補に追加。
        for rn in sheet.virtualMemberProfiles.compactMap({ $0.recordName }) where !ids.contains(rn) {
            ids.append(rn)
        }
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
                // 金額を先に入力する。
                Section("金額") {
                    HStack {
                        // 注意: Form 内の HStack に置いた TextField は、第1引数のタイトルが
                        // LabeledContent のラベル扱いになって左に表示されてしまう。
                        // .labelsHidden() でラベル列を消し、prompt: で placeholder を出す。
                        TextField("金額", text: $amountText, prompt: Text("0"))
                            .labelsHidden()
                            .focused($amountFocused)
                            .onChange(of: amountText) { _, new in
                                // 全角数字 / 全角ピリオドを半角に正規化してから許可文字でフィルタ
                                let normalized = new
                                    .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? new
                                let allowed = normalized
                                    .filter { $0.isASCII && ($0.isNumber || $0 == ".") }
                                if allowed != new { amountText = allowed }
                            }
                        Picker("通貨", selection: $currencyCode) {
                            ForEach(CurrencyCatalog.all) { opt in
                                Text("\(opt.symbol)  \(opt.code)").tag(opt.code)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        // 内容に合わせて picker をシュリンクし、TextField 右隣に
                        // 自然に並ぶようにする (= 160pt 固定では行内で浮いて見えた)。
                        .fixedSize()
                    }
                }
                // 次にタイトルを入力する。
                Section("タイトル") {
                    TextField("タイトル", text: $title)
                        .labelsHidden()
                }
                Section("日付") {
                    // macOS の DatePicker / Picker / Toggle は親の .tint を継承しないため、
                    // 各コントロールへ直接 sheet.tint を適用する。
                    DatePicker("日付", selection: $date, displayedComponents: .date)
                        .tint(sheet.tint)
                }
                Section("カテゴリ") {
                    Picker("カテゴリ", selection: $selectedCategory) {
                        Text("未選択").tag(ExpenseCategory?.none)
                        ForEach(categories, id: \.objectID) { c in
                            Text(c.displayName).tag(Optional(c))
                        }
                    }
                    .tint(sheet.tint)
                    // iOS の CategoryPickerView と同様、ここからカテゴリを新規追加できる。
                    Button {
                        showingNewCategory = true
                    } label: {
                        Label("新しいカテゴリを追加", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .tint(sheet.tint)
                }
                aiCategorySuggestionSection
                Section(kind == .income ? "受取者" : "支払い者") {
                    payerPicker
                }
                // 共有シート、またはバーチャルメンバー追加可能な Premium なら表示
                // (ソロシートでも Premium はバーチャルメンバーを足して割り勘できる)。
                // 収入には割り勘の概念がないので支出時のみ表示。
                if kind == .expense, !payerProfileID.isEmpty, hasOtherMembers || PurchaseManager.hasPremiumAccess(to: sheet) {
                    Section {
                        Toggle("割り勘", isOn: Binding(
                            get: { splitEnabled },
                            set: { on in
                                splitEnabled = on
                                // オンにした直後は全員を選択する (空 = 全員にはしない)。
                                if on, selectedBeneficiaries.isEmpty
                                    || selectedBeneficiaries == Set([payerProfileID]) {
                                    selectAllBeneficiaries()
                                }
                            }
                        ))
                        .tint(sheet.tint)
                        if splitEnabled {
                            beneficiariesList
                            Button {
                                if PurchaseManager.hasPremiumAccess(to: sheet) {
                                    showAddMemberPrompt = true
                                } else {
                                    showMemberPaywall = true
                                }
                            } label: {
                                Label("メンバーを追加", systemImage: "person.badge.plus")
                            }
                            .buttonStyle(.borderless)
                        }
                    } header: {
                        if splitEnabled {
                            HStack {
                                Text("割る相手")
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
                        }
                    } footer: {
                        if splitEnabled {
                            Text(selectedBeneficiaries.isEmpty
                                 ? "割る相手を 1 人以上選んでください。"
                                 : "選んだ人で均等割りします。")
                                .font(.caption2)
                                .foregroundStyle(selectedBeneficiaries.isEmpty ? Color.red : Color.secondary)
                        }
                    }
                }
                Section("メモ") {
                    TextField("メモ", text: $note, prompt: Text("詳細"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...4)
                }
                if expense != nil {
                    Section {
                        Button {
                            showingDeleteConfirm = true
                        } label: {
                            Label("この支出を削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.never)

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("OK") { trySave() }
                    .keyboardShortcut(.return)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 560, height: 720)
        .tint(sheet.tint)
        .sheet(isPresented: $showMemberPaywall) { PaywallView() }
        .sheet(isPresented: $showingNewCategory) {
            // 支出追加画面からカテゴリを新規作成し、作成後はそれを選択する。
            MacEditCategoryView(mode: .create(record: sheet, defaultKind: kind)) { newCat in
                selectedCategory = newCat
            }
        }
        .alert(editingMemberID == nil ? "メンバーを追加" : "名前を変更",
               isPresented: $showAddMemberPrompt) {
            TextField("名前", text: $newMemberName)
            Button("保存") {
                let trimmed = newMemberName.trimmingCharacters(in: .whitespaces)
                if let rn = editingMemberID {
                    if !trimmed.isEmpty,
                       let pp = sheet.virtualMemberProfiles.first(where: { $0.recordName == rn }) {
                        pp.displayName = trimmed
                        pp.updatedAt = .now
                        PersistenceController.shared.save()
                    }
                } else if let id = sheet.addVirtualMember(name: trimmed) {
                    splitEnabled = true
                    selectedBeneficiaries.insert(id)
                }
                newMemberName = ""
                editingMemberID = nil
            }
            Button("キャンセル", role: .cancel) { newMemberName = ""; editingMemberID = nil }
        } message: {
            Text("アプリを使っていない相手を割り勘・支払者に追加できます。")
        }
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
        .confirmationDialog(
            "変更の適用範囲",
            isPresented: $showRecurringSaveChoice,
            titleVisibility: .visible
        ) {
            Button("この項目のみ保存") { performRecurringSave(scope: .thisOnly) }
            Button("全ての定期項目で変更") { performRecurringSave(scope: .all) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この支出は定期項目から生成されています。この項目だけ変更するか、定期項目全体を変更するか選んでください。")
        }
        .task { await loadShareAndDefaults() }
        .onAppear {
            // 新規追加時のみ、金額へ自動フォーカス。
            if expense == nil {
                DispatchQueue.main.async { amountFocused = true }
            }
        }
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
                                .background(Capsule().fill(sheet.tint.opacity(0.18)))
                                .foregroundStyle(sheet.tint)
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
        // 1) 過去の自分の分類履歴を最優先で提案 (例: クスリのアオキ→食費)。即時・同期。
        // (出所は履歴だが、表示は AI 提案として統一する。)
        if let hist = CategoryHistorySuggestor.suggest(title: trimmed, kind: kind, in: sheet),
           selectedCategory?.objectID != hist.objectID {
            aiCategorySuggestion = hist
            return
        }
        // 2) 履歴が無ければ AI (FoundationModels) で推測。
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
        // 「未選択」オプション。payerProfileID = "" で保存される。
        // 割り勘セクションは未選択時に非表示になる (= 未選択 + 割り勘の整合性破壊を防ぐ)。
        unselectedPayerRow
        ForEach(allMemberIDs, id: \.self) { id in
            payerRow(id)
        }
    }

    private var unselectedPayerRow: some View {
        let isOn = payerProfileID.isEmpty
        return Button {
            payerProfileID = ""
            // 未選択にしたら割り勘設定もリセット
            splitEnabled = false
            selectedBeneficiaries.removeAll()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 28, height: 28)
                    Image(systemName: "person.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text("未選択").foregroundStyle(.primary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(sheet.tint)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        .foregroundStyle(sheet.tint)
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
        ForEach(beneficiaryPickerIDs, id: \.self) { id in
            beneficiaryRow(id)
        }
    }

    /// 現メンバー + 受益者として保存済みだが現メンバーに居ない人 (退室済み等) を末尾に。
    /// 編集中の支出を開いた時に「居ないメンバー」もチェック状態のまま表示するため。
    private var beneficiaryPickerIDs: [String] {
        var ids = allMemberIDs
        var seen = Set(ids)
        for sb in selectedBeneficiaries where !sb.isEmpty && seen.insert(sb).inserted {
            ids.append(sb)
        }
        return ids
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
                    .foregroundStyle(isOn ? sheet.tint : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if UserProfileStore.isVirtualRecordName(id) {
                Button("名前を変更") {
                    editingMemberID = id
                    newMemberName = info.name
                    showAddMemberPrompt = true
                }
                Button("削除", role: .destructive) {
                    selectedBeneficiaries.remove(id)
                    sheet.deleteVirtualMember(profileID: id)
                }
            }
        }
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
            currencyCode = e.resolvedCurrencyCode
            date = e.date ?? .now
            kind = e.kind
            note = e.note ?? ""
            selectedCategory = e.category
            // iOS 側で「未選択」(payerProfileID nil) で保存された支出は、その状態を保つ。
            // ここで selfProfileID にフォールバックすると編集 → 保存で勝手に自分に書き換わる。
            payerProfileID = e.payerProfileID ?? ""
            selectedBeneficiaries = Set(e.beneficiaryIDList)
            // 受益者が「空」または「支払者ただ 1 人」なら割り勘オフ。複数ならオン。
            // ※ 空はそのまま「割り勘オフ (支払者単独負担)」として扱い、全メンバーへの
            //   展開は行わない (= 後から追加されたメンバーを巻き込まない)。
            let loadedPayerID = e.payerProfileID ?? ""
            let isPayerOnly = selectedBeneficiaries.isEmpty
                || (!loadedPayerID.isEmpty && selectedBeneficiaries == Set([loadedPayerID]))
            splitEnabled = !isPayerOnly
            // 割り勘オフ時は UI 上のチェック対象を「支払者ただ 1 人」に正規化。
            if !splitEnabled, !loadedPayerID.isEmpty {
                selectedBeneficiaries = Set([loadedPayerID])
            }

            // CRDT 差分書き戻し用にスナップショット保存
            origTitle = title
            origAmountText = amountText
            origKindRaw = e.kindRaw ?? ""
            origCurrencyCode = currencyCode
            origCategoryObjectID = e.category?.objectID
            origPayerProfileID = e.payerProfileID ?? ""
            origDate = date
            origNote = note
            // 「[支払者]」 と 「空」 は同じ意味 (= 割り勘オフ) なので、空に正規化して
            // 編集なしの再保存で誤って dirty 扱いにならないようにする。
            let storedCSV = e.beneficiaryProfileIDs ?? ""
            origBeneficiaryCSV = (!loadedPayerID.isEmpty
                                  && Set(e.beneficiaryIDList) == Set([loadedPayerID]))
                ? ""
                : storedCSV
        } else {
            selectedCategory = nil
            payerProfileID = selfProfileID
            selectedBeneficiaries = []
            currencyCode = sheet.resolvedDefaultCurrencyCode
        }
    }

    /// 自分以外のメンバーがいる (= 共有シート) か。割り勘トグルの表示判定に使う。
    private var hasOtherMembers: Bool { allMemberIDs.count > 1 }

    /// 実際に保存する受益者 ID 配列。
    /// - 割り勘オン: 選択中の相手。
    /// - 割り勘オフ: 空 (= 受益者未設定。SettlementCalculator では支払者単独負担として
    ///   残高変動なし、カテゴリ集計のみ計上)。
    private var effectiveBeneficiaryIDs: [String] {
        splitEnabled ? Array(selectedBeneficiaries) : []
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) else { return }

        let profile = UserProfileStore.shared

        if let existing = expense {
            // 編集モード: CRDT 差分書き戻し (変更があったフィールドだけ touch)
            // → 他端末が別フィールドを同時編集していてもその変更を消さない。
            applyChanges(toExpense: existing, trimmedTitle: trimmed, amount: amount, profile: profile)
        } else {
            // 新規作成: 全フィールド書き込み
            let target = Expense(context: viewContext)
            if let store = sheet.objectID.persistentStore {
                viewContext.assign(target, to: store)
            }
            target.sheet = sheet
            target.createdAt = .now
            target.title = trimmed
            target.amount = NSDecimalNumber(decimal: amount)
            target.kindRaw = kind.rawValue
            target.currencyCode = currencyCode.isEmpty
                ? sheet.resolvedDefaultCurrencyCode
                : currencyCode
            target.date = date
            target.note = note
            target.categoryRaw = selectedCategory?.name
            if let cat = selectedCategory,
               cat.objectID.persistentStore == sheet.objectID.persistentStore {
                target.category = cat
            } else {
                target.category = nil
            }
            target.payerProfileID = payerProfileID
            if selfIDSet.contains(payerProfileID), let mid = profile.selfMemberID {
                target.payerMemberID = mid
            } else {
                target.payerMemberID = nil
            }
            target.beneficiaryIDList = effectiveBeneficiaryIDs
            // FX スナップショット (amount / currencyCode / sheet 設定後に呼ぶ)
            target.captureFXSnapshot()
        }

        PersistenceController.shared.save()
        onCommit?()
        dismiss()
    }

    /// 保存ボタンのディスパッチ。定期由来の支出に変更があれば 2 択ダイアログ、それ以外は通常 save。
    private func trySave() {
        // 機能オフ時は既存の生成由来支出も通常編集として保存する (2 択ダイアログを出さない)。
        if RecurringOccurrenceService.featureEnabled, let expense,
           expense.generatedFromRuleID != nil,
           expense.relatedRule != nil, hasAnyEditChanges {
            showRecurringSaveChoice = true
        } else {
            save()
        }
    }

    /// 編集モードで何かフィールドを変更したか。
    private var hasAnyEditChanges: Bool {
        guard expense != nil else { return false }
        if title.trimmingCharacters(in: .whitespaces) != origTitle { return true }
        if amountText != origAmountText { return true }
        if kind.rawValue != origKindRaw { return true }
        if currencyCode != origCurrencyCode { return true }
        if note != origNote { return true }
        if !Calendar.current.isDate(date, inSameDayAs: origDate) { return true }
        if payerProfileID != origPayerProfileID { return true }
        if selectedCategory?.objectID != origCategoryObjectID { return true }
        let newCSV = effectiveBeneficiaryIDs.sorted().joined(separator: ",")
        let oldCSV = origBeneficiaryCSV
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .sorted().joined(separator: ",")
        if newCSV != oldCSV { return true }
        return false
    }

    /// RecurringRule に同じ差分を適用する (date / sheet / 頻度等は触らない。iOS と同じフィールド)。
    private func applyChanges(toRule rule: RecurringRule) {
        let newTitle = title.trimmingCharacters(in: .whitespaces)
        if newTitle != origTitle { rule.title = newTitle }
        if amountText != origAmountText,
           let d = Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) {
            rule.amount = NSDecimalNumber(decimal: d)
        }
        if kind.rawValue != origKindRaw { rule.kindRaw = kind.rawValue }
        if currencyCode != origCurrencyCode { rule.currencyCode = currencyCode }
        if note != origNote { rule.note = note }
        if payerProfileID != origPayerProfileID {
            rule.payerProfileID = payerProfileID.isEmpty ? nil : payerProfileID
            rule.paidBy = nil
        }
        if selectedCategory?.objectID != origCategoryObjectID {
            rule.categoryRaw = selectedCategory?.name
        }
    }

    /// 「変更の適用範囲」ダイアログから呼ばれる (iOS の performRecurringSave と同じ挙動)。
    @MainActor
    private func performRecurringSave(scope: RecurringSaveScope) {
        guard let expense else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) else { return }
        let profile = UserProfileStore.shared
        viewContext.refresh(expense, mergeChanges: true)

        // 1) 編集中の Expense には常に反映 (この項目のみ / 全て 共通)
        applyChanges(toExpense: expense, trimmedTitle: trimmed, amount: amount, profile: profile)

        // この項目のみ = 定期から切り離して通常支出化 (もう定期項目ではない)。
        if scope == .thisOnly, RecurringOccurrenceService.virtualizationEnabled,
           let rule = expense.relatedRule, let day = expense.scheduledDate ?? expense.date {
            rule.addSkippedDay(day)
            expense.generatedFromRuleID = nil
            expense.scheduledDate = nil
            expense.captureFXSnapshot()   // 通常支出になったので FX 凍結
        }

        // 全て = ルールを変更して全 occurrence に反映 (他の materialized にも反映)。
        if scope == .all, let rule = expense.relatedRule {
            applyChanges(toRule: rule)
            if let ruleID = rule.id {
                let req = NSFetchRequest<Expense>(entityName: "Expense")
                req.predicate = NSPredicate(format: "generatedFromRuleID == %@", ruleID as CVarArg)
                let others = (try? viewContext.fetch(req)) ?? []
                for other in others where other.objectID != expense.objectID {
                    applyChanges(toExpense: other, trimmedTitle: trimmed, amount: amount, profile: profile, includeDate: false)
                }
            }
        }

        // 全て: 編集内容はルールに反映済みなので、materialize した実 Expense は残さず削除し仮想のまま。
        if scope == .all, RecurringOccurrenceService.virtualizationEnabled {
            viewContext.delete(expense)
        }

        PersistenceController.shared.save()
        RecurringExpenseGenerator.generateAll(in: viewContext)
        onCommit?()
        dismiss()
    }

    /// 編集中の差分を Expense に書き戻す。
    /// `origXxx` スナップショットと現在値を比較し、**変わったフィールドだけ** 上書きする。
    /// これにより他端末が同時に別フィールドを編集していても、こちらの save でそれを
    /// 上書きしてしまわないようにする。
    @MainActor
    private func applyChanges(
        toExpense expense: Expense,
        trimmedTitle: String,
        amount: Decimal,
        profile: UserProfileStore,
        includeDate: Bool = true
    ) {
        if trimmedTitle != origTitle { expense.title = trimmedTitle }
        let amountChanged = amountText != origAmountText
        if amountChanged {
            expense.amount = NSDecimalNumber(decimal: amount)
        }
        if kind.rawValue != origKindRaw { expense.kindRaw = kind.rawValue }
        let currencyChanged = currencyCode != origCurrencyCode
        if currencyChanged { expense.currencyCode = currencyCode }
        // amount / currency が変わったら FX スナップショットを取り直す
        if amountChanged || currencyChanged {
            expense.captureFXSnapshot()
        }
        if includeDate, !Calendar.current.isDate(date, inSameDayAs: origDate) {
            expense.date = date
        }
        if note != origNote { expense.note = note }
        if selectedCategory?.objectID != origCategoryObjectID {
            expense.categoryRaw = selectedCategory?.name
            if let cat = selectedCategory,
               cat.objectID.persistentStore == sheet.objectID.persistentStore {
                expense.category = cat
            } else {
                expense.category = nil
            }
        }
        if payerProfileID != origPayerProfileID {
            expense.payerProfileID = payerProfileID
            // paidBy は denormalized キャッシュなので空にして、表示は payerProfileID 経由で解決
            expense.paidBy = nil
            if selfIDSet.contains(payerProfileID), let mid = profile.selfMemberID {
                expense.payerMemberID = mid
            } else {
                expense.payerMemberID = nil
            }
        }
        // beneficiaryIDList は内部で重複・空除去するので、CSV 比較で diff を取る
        let newCSV = effectiveBeneficiaryIDs
            .sorted()
            .joined(separator: ",")
        let oldCSV = origBeneficiaryCSV
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .sorted()
            .joined(separator: ",")
        if newCSV != oldCSV {
            expense.beneficiaryIDList = effectiveBeneficiaryIDs
        }
    }

    private func deleteExpense() {
        guard let e = expense else { return }
        // 定期由来 (occurrence) の削除は、完全仮想化では行を消すだけだと仮想で復活するので、
        // ルールにこの日付を skip 記録してから削除する (iOS SheetDetailView.deleteExpense と同じ)。
        if RecurringOccurrenceService.virtualizationEnabled,
           let rule = e.relatedRule, let day = e.scheduledDate ?? e.date {
            rule.addSkippedDay(day)
        }
        viewContext.delete(e)
        PersistenceController.shared.save()
        onCommit?()
        dismiss()
    }
}

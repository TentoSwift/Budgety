//
//  AddExpenseView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct AddExpenseView: View {
    enum Mode {
        case create(record: ExpenseSheet)
        case edit(expense: Expense)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let mode: Mode

    private var contextSheet: ExpenseSheet? {
        switch mode {
        case .create(let g): return g
        case .edit(let e): return e.sheet
        }
    }


    @StateObject private var profile = UserProfileStore.shared

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var kind: TransactionKind = .expense
    @State private var currencyCode: String = "JPY"
    @State private var selectedCategory: ExpenseCategory?
    @State private var selectedPayer: Member?
    @State private var date: Date = .now
    @State private var note: String = ""
    @State private var didLoad: Bool = false
    @State private var showCameraScanner: Bool = false
    @State private var showPhotoScanner: Bool = false

    // 編集モードの「ロード時スナップショット」。save 時に現在値と比較し、
    // 差分のあるフィールドだけを Expense に書き戻す (= ユーザーが触らなかった
    // フィールドは他デバイスの更新を上書きしない = field-level CRDT 動作)
    @State private var origTitle: String = ""
    @State private var origAmountText: String = ""
    @State private var origKindRaw: String = ""
    @State private var origCurrencyCode: String = ""
    @State private var origCategoryObjectID: NSManagedObjectID?
    @State private var origPayerProfileID: String = ""
    @State private var origDate: Date = .distantPast
    @State private var origNote: String = ""
    @State private var origBeneficiaryCSV: String = ""

    /// 受益者 (誰の負担として扱うか) の profileID 集合。
    /// 空 = 「シートの全員で均等割り」(精算計算側で展開される)。
    /// 収入では使わない (精算対象外)。
    @State private var selectedBeneficiaries: Set<String> = []

    /// 定期項目から生成された支出を編集中、保存ボタンを押した時に出る 3 択ダイアログ。
    @State private var showRecurringSaveChoice: Bool = false

    /// 「定期項目に反映する」処理範囲
    private enum RecurringSaveScope {
        case thisOnly   // この 1 件だけ
        case future     // ルールも更新 (今後)
        case all        // ルール + 過去に生成済みの全支出も更新
    }

    init(record: ExpenseSheet) { self.mode = .create(record: record) }
    init(expense: Expense) { self.mode = .edit(expense: expense) }

    private var amountDecimal: Decimal? {
        guard !amountText.isEmpty else { return nil }
        return Decimal(string: amountText)
    }

    /// JPY/KRW など最小単位のない通貨は decimalPad 不要
    private var decimalKeypadNeeded: Bool {
        !["JPY", "KRW", "VND", "IDR"].contains(currencyCode)
    }

    private var navTitle: String {
        switch mode {
        case .create: "支出を追加"
        case .edit: "支出を編集"
        }
    }

    private var canSave: Bool {
        amountDecimal != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 編集モードで Member 解決ができなかった場合に表示する名前 (保存済みの paidBy)。
    /// 新規作成時は nil で fallback としてプロフィール表示にする。
    private var payerFallbackName: String? {
        if case .edit(let expense) = mode {
            let n = expense.paidBy ?? ""
            return n.isEmpty ? nil : n
        }
        return nil
    }

    private var payerFallbackProfileID: String? {
        if case .edit(let expense) = mode {
            let p = expense.payerProfileID ?? ""
            return p.isEmpty ? nil : p
        }
        return nil
    }

    /// 受益者ピッカーのプレビュー文字列。空 = 全員均等、それ以外 = 「N 人選択中: 名前1, 名前2...」。
    @MainActor
    private func beneficiarySummary(in sheet: ExpenseSheet) -> String {
        if selectedBeneficiaries.isEmpty {
            return "全員均等"
        }
        let names = selectedBeneficiaries.map { sheet.memberDisplayInfo(for: $0).name }
        return "\(selectedBeneficiaries.count) 人: \(names.joined(separator: ", "))"
    }

    /// 永続化用のソート済み CSV (順序非依存で同値判定するため)。
    private var selectedBeneficiaryCSV: String {
        selectedBeneficiaries.sorted().joined(separator: ",")
    }

    /// `selectedPayer` (Member) に対応する ParticipantProfile を同シートから引く。
    /// あればそれが「最新のプロフィール」(共有同期される) なので、Member の denormalized キャッシュより優先する。
    private func currentParticipantProfile(for member: Member) -> ParticipantProfile? {
        guard let rn = member.recordName, !rn.isEmpty,
              rn != "_defaultOwner_", rn != "__defaultOwner__",
              let sheet = contextSheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == rn })
    }

    @ViewBuilder
    private var payerPreview: some View {
        if let m = selectedPayer {
            if let pp = currentParticipantProfile(for: m) {
                // ParticipantProfile があれば最新値を表示
                ObservedParticipantProfileAvatar(profile: pp, size: 24)
                Text(pp.displayName?.isEmpty == false ? pp.displayName! : m.displayName)
                    .foregroundStyle(.secondary)
            } else {
                ObservedMemberAvatar(member: m, size: 24)
                Text(m.displayName).foregroundStyle(.secondary)
            }
        } else if let name = payerFallbackName {
            // 編集モードで Member 解決できなかった時: 保存済みの paidBy + ParticipantProfile
            // (= 共有相手が支払者になっている支出をローカル Member 無しで正しく表示)
            if case .edit(let expense) = mode {
                PayerAvatar(
                    member: nil,
                    participantProfile: expense.resolvedParticipantProfile,
                    fallbackName: name,
                    fallbackColorHex: "#8E8E93",
                    fallbackPhoto: nil,
                    size: 24
                )
            } else {
                AvatarView(name: name, colorHex: "#8E8E93", photoData: nil, size: 24)
            }
            Text(name).foregroundStyle(.secondary)
        } else {
            // 新規作成 + 未選択: 自分のプロフィールをデフォルト候補として表示
            AvatarView(
                photoData: profile.photoData,
                displayName: profile.resolvedDisplayName,
                colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                size: 24
            )
            Text(profile.resolvedDisplayName).foregroundStyle(.secondary)
        }
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
                    .onChange(of: kind) { _, newKind in
                        // 種別が変わったらカテゴリは新しい種別の最初のものに自動リセット
                        if let sheet = contextSheet {
                            let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
                            let filtered = cats.filter { c in
                                let raw = c.kindRaw ?? ""
                                return raw == newKind.rawValue ||
                                       (newKind == .expense && raw.isEmpty)
                            }
                            let sorted = filtered.sorted { $0.sortOrder < $1.sortOrder }
                            selectedCategory = sorted.first
                        }
                    }
                }

                if case .create = mode {
                    Section {
                        HStack(spacing: 10) {
                            if ReceiptCameraScanner.isAvailable {
                                Button {
                                    showCameraScanner = true
                                } label: {
                                    Label("カメラでレシートをスキャン", systemImage: "camera.viewfinder")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                            }
                            Button {
                                showPhotoScanner = true
                            } label: {
                                Label("写真から", systemImage: "photo.on.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    } footer: {
                        Text("レシートを撮影すると、店名・金額・日付を自動で入力します。読み取り後に内容を確認・修正してください。")
                            .font(.caption2)
                    }
                }

                Section("内容") {
                    TextField(kind == .expense ? "タイトル (例: スーパー)" : "タイトル (例: 給料)", text: $title)
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
                        ForEach(CurrencyCatalog.all) { opt in
                            Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
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
                                    Image(systemName: cat.displaySymbol)
                                        .foregroundStyle(cat.tint)
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

                Section("日時") {
                    DatePicker("日付", selection: $date, displayedComponents: [.date])
                    HStack(spacing: 8) {
                        datePresetButton("今日", offset: 0)
                        datePresetButton("昨日", offset: -1)
                        datePresetButton("一昨日", offset: -2)
                        Spacer()
                    }
                }

                Section(kind.partyLabel) {
                    NavigationLink {
                        MemberPickerView(
                            selected: $selectedPayer,
                            record: contextSheet,
                            kind: kind,
                            fallbackPaidBy: payerFallbackName,
                            fallbackProfileID: payerFallbackProfileID
                        )
                    } label: {
                        HStack {
                            Text(kind.partyLabel)
                            Spacer()
                            payerPreview
                        }
                    }
                }

                if kind == .expense, let sheet = contextSheet {
                    Section {
                        NavigationLink {
                            BeneficiaryPickerView(selected: $selectedBeneficiaries, record: sheet)
                        } label: {
                            HStack {
                                Text("受益者")
                                Spacer()
                                Text(beneficiarySummary(in: sheet))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    } footer: {
                        Text("精算する際にこの支出を誰の負担として割るかを指定します。未指定の場合はシート全員で均等割り。")
                            .font(.caption2)
                    }
                }

                Section("メモ (任意)") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if case .edit(let expense) = mode {
                    Section {
                        Button(role: .destructive) {
                            viewContext.delete(expense)
                            PersistenceController.shared.save()
                            dismiss()
                        } label: {
                            Label("削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { trySave() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "変更の適用範囲",
                isPresented: $showRecurringSaveChoice,
                titleVisibility: .visible
            ) {
                Button("この項目のみ保存") { performRecurringSave(scope: .thisOnly) }
                Button("今後の定期項目で保存") { performRecurringSave(scope: .future) }
                Button("全ての定期項目で変更") { performRecurringSave(scope: .all) }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この支出は定期項目から生成されています。変更をどこまで反映するか選んでください。")
            }
            .onAppear { loadIfNeeded() }
            .fullScreenCover(isPresented: $showCameraScanner) {
                ReceiptCameraScannerSheet(
                    onComplete: { result in
                        showCameraScanner = false
                        applyScanResult(result)
                    },
                    onCancel: { showCameraScanner = false }
                )
            }
            .sheet(isPresented: $showPhotoScanner) {
                ReceiptPhotoScanner(
                    onComplete: { result in
                        showPhotoScanner = false
                        applyScanResult(result)
                    },
                    onCancel: { showPhotoScanner = false }
                )
            }
        }
    }

    /// OCR で取れた候補を、ユーザーがまだ手で入れていないフィールドだけに適用する。
    /// 既に入力済みのフィールドは上書きしない (誤検出による消失を防ぐ)。
    private func applyScanResult(_ result: ReceiptParseResult) {
        if title.trimmingCharacters(in: .whitespaces).isEmpty, let t = result.title {
            title = t
        }
        if amountText.isEmpty, let a = result.amount {
            // JPY/KRW など整数通貨は端数切捨て表示
            if ["JPY", "KRW", "VND", "IDR"].contains(result.currencyCode ?? currencyCode) {
                amountText = NSDecimalNumber(decimal: a).rounding(accordingToBehavior: nil).stringValue
            } else {
                amountText = NSDecimalNumber(decimal: a).stringValue
            }
        }
        if let code = result.currencyCode {
            currencyCode = code
        }
        if let d = result.date {
            date = d
        }
        Haptics.success()
    }

    /// 保存ボタンタップ時のディスパッチ。定期由来の支出に変更があれば 3 択ダイアログ、
    /// それ以外は通常 save。
    private func trySave() {
        if case .edit(let expense) = mode,
           expense.generatedFromRuleID != nil,
           expense.relatedRule != nil,
           hasAnyEditChanges {
            showRecurringSaveChoice = true
        } else {
            save()  // save() 内で dismiss() まで行う
        }
    }

    /// 編集モードで何かしらフィールドを変更したかを判定する。
    private var hasAnyEditChanges: Bool {
        guard case .edit = mode else { return false }
        if title.trimmingCharacters(in: .whitespaces) != origTitle { return true }
        if amountText != origAmountText { return true }
        if kind.rawValue != origKindRaw { return true }
        if currencyCode != origCurrencyCode { return true }
        if note != origNote { return true }
        if !Calendar.current.isDate(date, inSameDayAs: origDate) { return true }
        if (selectedPayer?.profileID ?? "") != origPayerProfileID { return true }
        if selectedCategory?.objectID != origCategoryObjectID { return true }
        if selectedBeneficiaryCSV != origBeneficiaryCSV { return true }
        return false
    }

    /// 編集中の差分を、対象の Expense / RecurringRule に適用する。
    /// `includeDate = true` のときだけ date を反映 (= 過去の生成支出 / Rule には date は触らない)。
    private func applyChanges(toExpense expense: Expense, includeDate: Bool) {
        let newTitle = title.trimmingCharacters(in: .whitespaces)
        if newTitle != origTitle { expense.title = newTitle }
        if amountText != origAmountText, let d = Decimal(string: amountText) {
            expense.amount = NSDecimalNumber(decimal: d)
        }
        if kind.rawValue != origKindRaw { expense.kindRaw = kind.rawValue }
        if currencyCode != origCurrencyCode { expense.currencyCode = currencyCode }
        if note != origNote { expense.note = note }
        if includeDate, !Calendar.current.isDate(date, inSameDayAs: origDate) {
            expense.date = date
        }
        let newPayerProfileID = selectedPayer?.profileID ?? ""
        if newPayerProfileID != origPayerProfileID {
            expense.payerProfileID = selectedPayer?.profileID
            expense.paidBy = selectedPayer?.name
            expense.payerMemberID = selectedPayer?.id
        }
        if selectedCategory?.objectID != origCategoryObjectID {
            expense.categoryRaw = selectedCategory?.name
            let store = expense.objectID.persistentStore
            if let cat = selectedCategory, cat.objectID.persistentStore == store {
                expense.category = cat
            } else {
                expense.category = nil
            }
        }
        if selectedBeneficiaryCSV != origBeneficiaryCSV {
            expense.beneficiaryProfileIDs = selectedBeneficiaryCSV
        }
    }

    /// RecurringRule に同じ差分を適用する (date / sheet は触らない)。
    private func applyChanges(toRule rule: RecurringRule) {
        let newTitle = title.trimmingCharacters(in: .whitespaces)
        if newTitle != origTitle { rule.title = newTitle }
        if amountText != origAmountText, let d = Decimal(string: amountText) {
            rule.amount = NSDecimalNumber(decimal: d)
        }
        if kind.rawValue != origKindRaw { rule.kindRaw = kind.rawValue }
        if currencyCode != origCurrencyCode { rule.currencyCode = currencyCode }
        if note != origNote { rule.note = note }
        let newPayerProfileID = selectedPayer?.profileID ?? ""
        if newPayerProfileID != origPayerProfileID {
            rule.payerProfileID = selectedPayer?.profileID
            rule.paidBy = selectedPayer?.name
        }
        if selectedCategory?.objectID != origCategoryObjectID {
            rule.categoryRaw = selectedCategory?.name
        }
    }

    /// 「変更の適用範囲」ダイアログから呼ばれる。
    private func performRecurringSave(scope: RecurringSaveScope) {
        guard case .edit(let expense) = mode else { return }
        viewContext.refresh(expense, mergeChanges: true)

        // 1) 編集中の Expense には常に反映 (= 「この項目のみ」と「今後」「全て」共通)
        applyChanges(toExpense: expense, includeDate: true)

        // 2) ルールへ反映 (今後 / 全て)
        if scope != .thisOnly, let rule = expense.relatedRule {
            applyChanges(toRule: rule)

            // 3) 過去に生成された他の支出にも反映 (全て)
            if scope == .all, let ruleID = rule.id {
                let req = NSFetchRequest<Expense>(entityName: "Expense")
                req.predicate = NSPredicate(format: "generatedFromRuleID == %@", ruleID as CVarArg)
                let others = (try? viewContext.fetch(req)) ?? []
                for other in others where other.objectID != expense.objectID {
                    applyChanges(toExpense: other, includeDate: false)
                }
            }
        }

        PersistenceController.shared.save()
        Haptics.success()
        dismiss()
    }

    private func datePresetButton(_ label: String, offset: Int) -> some View {
        let target = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let isSelected = Calendar.current.isDate(date, inSameDayAs: target)
        return Button {
            date = target
        } label: {
            Text(label)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemBackground))
                )
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        // 自分の Member が無ければここで作る (プロフィール未登録でも"自分"が選べるように)
        profile.ensureSelfMemberExists(in: viewContext)
        switch mode {
        case .create(let record):
            currencyCode = record.resolvedDefaultCurrencyCode
            if selectedCategory == nil {
                let cats = (record.categories as? Set<ExpenseCategory>) ?? []
                let sorted = cats.sorted { $0.sortOrder < $1.sortOrder }
                selectedCategory = sorted.first(where: { $0.name == "食費" }) ?? sorted.first
            }
            if selectedPayer == nil {
                let req = NSFetchRequest<Member>(entityName: "Member")
                req.sortDescriptors = [NSSortDescriptor(keyPath: \Member.sortOrder, ascending: true)]
                let members = (try? viewContext.fetch(req)) ?? []
                if let selfID = profile.selfMemberID {
                    selectedPayer = members.first(where: { $0.id == selfID })
                }
                if selectedPayer == nil, !profile.displayName.isEmpty {
                    selectedPayer = members.first(where: { $0.name == profile.displayName })
                }
                selectedPayer = selectedPayer ?? members.first
            }
        case .edit(let expense):
            title = expense.displayTitle
            amountText = NSDecimalNumber(decimal: expense.amountDecimal).stringValue
            kind = expense.kind
            currencyCode = expense.resolvedCurrencyCode
            selectedCategory = expense.category
            selectedPayer = expense.resolvedPayer
            date = expense.date ?? .now
            note = expense.note ?? ""
            selectedBeneficiaries = Set(expense.beneficiaryIDList)

            // CRDT 用スナップショット
            origTitle = title
            origAmountText = amountText
            origKindRaw = expense.kindRaw ?? ""
            origCurrencyCode = expense.currencyCode ?? ""
            origCategoryObjectID = expense.category?.objectID
            origPayerProfileID = expense.payerProfileID ?? ""
            origDate = expense.date ?? .distantPast
            origNote = expense.note ?? ""
            origBeneficiaryCSV = selectedBeneficiaryCSV
        }
    }

    private func save() {
        guard let amountDecimal else { return }
        let pc = PersistenceController.shared
        switch mode {
        case .create(let record):
            let expense = Expense(context: viewContext)

            // 親シートと同じストアに先に割り当ててから関係を設定する。順序が逆だと
            // クロスストア関係エラーで save が失敗する。
            let sheetStore = record.objectID.persistentStore
            if let store = sheetStore {
                viewContext.assign(expense, to: store)
            }

            expense.title = title.trimmingCharacters(in: .whitespaces)
            expense.amount = NSDecimalNumber(decimal: amountDecimal)
            expense.kindRaw = kind.rawValue
            expense.currencyCode = currencyCode
            expense.categoryRaw = selectedCategory?.name
            expense.paidBy = selectedPayer?.name
            expense.payerProfileID = selectedPayer?.profileID
            expense.payerMemberID = selectedPayer?.id
            expense.date = date
            expense.note = note
            expense.createdAt = .now
            expense.beneficiaryProfileIDs = selectedBeneficiaryCSV

            expense.sheet = record
            // category は Expense と同じストア (= sheet と同じストア) に居る前提でのみ紐付ける
            if let cat = selectedCategory,
               cat.objectID.persistentStore == sheetStore {
                expense.category = cat
            }
            // 自分の ParticipantProfile を同シートに ensure (まだ無ければ作成、あれば更新)
            profile.ensureProfile(in: record, ctx: viewContext)
        case .edit(let expense):
            // 通常編集 (定期項目以外、または「この項目のみ」)。差分のみ書き戻し。
            viewContext.refresh(expense, mergeChanges: true)
            applyChanges(toExpense: expense, includeDate: true)
        }
        PersistenceController.shared.save()
        Haptics.success()
        dismiss()
    }
}

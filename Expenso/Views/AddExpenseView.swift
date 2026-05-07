//
//  AddExpenseView.swift
//  Expenso
//

import SwiftUI
import CoreData
import PhotosUI

struct AddExpenseView: View {
    enum Mode {
        case create(record: ExpenseSheet)
        case edit(expense: Expense)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    /// 添付写真 (任意)。JPEG 圧縮済みの Data を Core Data に保存する。
    @State private var photoData: Data?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var didLoad: Bool = false
    /// loadIfNeeded の State 代入が落ち着いた直後にキャプチャするスナップショット。
    /// 現在値と比較して `hasUnsavedChanges` を判定する。
    @State private var loadedSnapshot: FieldSnapshot?
    @State private var showDiscardConfirm: Bool = false
    /// 「変更を破棄」を選んだ時に、単に閉じるだけでなく Rule 編集ハンドオフも
    /// 走らせるためのキャリア。nil の時は通常の閉じる、Rule が入っている時は
    /// onEditRule(rule) 経由で SheetDetailView に渡す。
    @State private var pendingEditRuleAction: RecurringRule?
    @State private var showCameraScanner: Bool = false
    @State private var showPhotoScanner: Bool = false
    @State private var showingTemplatePicker: Bool = false
    @State private var showingSaveTemplateConfirm: Bool = false

    /// 過去の同タイトル支出からの候補。タイトル入力で自動更新。
    @State private var titleSuggestion: TitleSuggestion?

    /// FoundationModels が推測したカテゴリ。過去候補にカテゴリが無い時だけセットされる。
    @State private var aiCategorySuggestion: ExpenseCategory?
    @State private var isComputingAICategory: Bool = false
    /// 現在進行中の AI 推測 Task。新しいキーストロークでキャンセルする。
    @State private var aiSuggestTask: Task<Void, Never>?

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
    /// 写真の差分検出用ベースライン (= ロード時のバイト数)。
    /// 内容比較は重いので長さで近似 (差し替え/削除では必ず長さも変わる)。
    @State private var origPhotoByteCount: Int = 0
    @State private var origBeneficiaryCSV: String = ""

    /// 受益者 (誰の負担として扱うか) の profileID 集合。
    /// 空 = 「シートの全員で均等割り」(精算計算側で展開される)。
    /// 収入では使わない (精算対象外)。
    @State private var selectedBeneficiaries: Set<String> = []

    // MARK: - Recurring (繰り返し)

    @State private var isRecurring: Bool = false
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var recurringInterval: Int = 1
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = .now

    /// 編集モードでの CRDT スナップショット。Rule の更新は差分のみ書き戻す。
    @State private var origIsRecurring: Bool = false
    @State private var origFrequencyRaw: String = ""
    @State private var origRecurringInterval: Int32 = 1
    @State private var origEndDate: Date? = nil

    /// 編集中の Expense が既に Rule から生成されている場合、Toggle をロックする。
    /// (定期項目から外したい時は「定期項目」一覧から rule を直接削除する運用)
    private var isRecurringLocked: Bool {
        if case .edit(let expense) = mode, expense.generatedFromRuleID != nil { return true }
        return false
    }

    /// 定期項目から生成された支出を編集中、保存ボタンを押した時に出る 3 択ダイアログ。
    @State private var showRecurringSaveChoice: Bool = false

    /// 「定期項目に反映する」処理範囲
    private enum RecurringSaveScope {
        case thisOnly   // この 1 件だけ
        case future     // ルールも更新 (今後)
        case all        // ルール + 過去に生成済みの全支出も更新
    }

    /// 「定期項目を編集」を押した時に呼ばれるコールバック。
    /// シートを閉じて、親 (= SheetDetailView) 側で定期項目 view へ遷移する経路を提供する。
    let onEditRule: ((RecurringRule) -> Void)?

    init(record: ExpenseSheet) {
        self.mode = .create(record: record)
        self.onEditRule = nil
    }

    init(expense: Expense, onEditRule: ((RecurringRule) -> Void)? = nil) {
        self.mode = .edit(expense: expense)
        self.onEditRule = onEditRule
    }

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

    // MARK: - Title-based suggestion (= 過去の入力から学習)

    fileprivate struct TitleSuggestion {
        let category: ExpenseCategory?
        let amount: Decimal?
        let kind: TransactionKind
        let payerName: String?
        let payerProfileID: String?
        let payerMemberID: UUID?
        let sampleCount: Int

        /// 1 行プレビュー: "食費 · ¥320 (5 件)"
        func summary(currency: String) -> String {
            var parts: [String] = []
            if let cat = category { parts.append(cat.displayName) }
            if let amt = amount {
                parts.append(CurrencyCatalog.format(amt, code: currency))
            }
            if let p = payerName, !p.isEmpty { parts.append(p) }
            return parts.joined(separator: " · ") + "  (\(sampleCount) 件)"
        }
    }

    @ViewBuilder
    private var aiCategorySuggestionSection: some View {
        if case .create = mode {
            if isComputingAICategory {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(Color.purple)
                        (Text(Image(systemName: "apple.intelligence")) + Text(" でカテゴリを推測中…"))
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
                        Haptics.success()
                    } label: {
                        aiCategorySuggestionLabel(for: cat)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 過去履歴サジェストバナーの中身。AX では適用 pill を下段に。
    @ViewBuilder
    private func historySuggestionLabel(for s: TitleSuggestion) -> some View {
        let header = Text("過去の入力から候補")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        let summary = Text(s.summary(currency: currencyCode))
            .font(.subheadline)
            .foregroundStyle(.primary)
            // AX では full-width で wrap させたいので、line limit を外す。
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
        let applyPill = Text("適用")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    header
                    Spacer()
                }
                summary
                HStack { Spacer(); applyPill }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    header
                    summary
                }
                Spacer()
                applyPill
            }
        }
    }

    /// AI 提案バナーの中身。AX サイズでは「適用」pill を下段にまわして
    /// テキストが詰まらないようにする。
    @ViewBuilder
    private func aiCategorySuggestionLabel(for cat: ExpenseCategory) -> some View {
        let header = (Text(Image(systemName: "apple.intelligence")) + Text(" 提案"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        let nameRow = HStack(spacing: 6) {
            CategoryIconView(category: cat, size: 22)
            Text(cat.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        let applyPill = Text("適用")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "apple.intelligence")
                        .foregroundStyle(Color.purple)
                    header
                    Spacer()
                }
                nameRow
                HStack {
                    Spacer()
                    applyPill
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "apple.intelligence")
                    .foregroundStyle(Color.purple)
                VStack(alignment: .leading, spacing: 2) {
                    header
                    nameRow
                }
                Spacer()
                applyPill
            }
        }
    }

    @ViewBuilder
    private var suggestionSection: some View {
        if case .create = mode, let s = titleSuggestion {
            Section {
                Button {
                    applySuggestion(s)
                } label: {
                    historySuggestionLabel(for: s)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 現在の title 入力に基づいて、同シート内の過去 Expense を引いて候補を組み立てる。
    /// 現在の kind に一致する Expense だけを対象にすることで、ユーザーが既に選んだ
    /// 種別 (支出 / 収入) を尊重する。1 文字以下では何もしない (= ノイズ抑制)。
    @MainActor
    private func recomputeTitleSuggestion() {
        // 進行中の AI suggest Task を必ずキャンセル
        aiSuggestTask?.cancel()
        aiSuggestTask = nil
        aiCategorySuggestion = nil
        isComputingAICategory = false

        guard case .create(let sheet) = mode else {
            titleSuggestion = nil
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            titleSuggestion = nil
            return
        }
        let req = NSFetchRequest<Expense>(entityName: "Expense")
        req.predicate = NSPredicate(
            format: "sheet == %@ AND title CONTAINS[c] %@ AND kindRaw == %@",
            sheet, trimmed, kind.rawValue
        )
        req.sortDescriptors = [NSSortDescriptor(keyPath: \Expense.date, ascending: false)]
        req.fetchLimit = 30
        let results = (try? viewContext.fetch(req)) ?? []
        // 過去マッチが 0 件 → 履歴サジェストはなしだが、AI 提案は試す価値あり
        guard !results.isEmpty else {
            titleSuggestion = nil
            kickAICategorySuggest(title: trimmed, in: sheet)
            return
        }

        // 最頻カテゴリ (objectID で集計)
        let categoryCounts = Dictionary(grouping: results, by: { $0.category?.objectID })
        let topCategoryID = categoryCounts
            .filter { $0.key != nil }
            .max(by: { $0.value.count < $1.value.count })?.key
        let topCategory: ExpenseCategory? = results
            .first(where: { $0.category?.objectID == topCategoryID })?.category

        // 中央値 (0 以外)
        let amounts = results.map { $0.amountDecimal }.filter { $0 > 0 }.sorted()
        let medianAmount: Decimal? = amounts.isEmpty ? nil : amounts[amounts.count / 2]

        // 最頻 payer
        let payerCounts = Dictionary(grouping: results, by: { $0.payerProfileID ?? "" })
        let topPayerKey = payerCounts
            .filter { !$0.key.isEmpty }
            .max(by: { $0.value.count < $1.value.count })?.key
        let topPayerExpense = results
            .first(where: { ($0.payerProfileID ?? "") == (topPayerKey ?? "") })

        titleSuggestion = TitleSuggestion(
            category: topCategory,
            amount: medianAmount,
            kind: kind,
            payerName: topPayerExpense?.paidBy,
            payerProfileID: topPayerKey,
            payerMemberID: topPayerExpense?.payerMemberID,
            sampleCount: results.count
        )

        // 過去マッチからカテゴリが拾えない時だけ FoundationModels で推測する。
        // selectedCategory が既に何か入っていても (= ロード時の自動デフォルト) 提案を出して
        // 上書きしたいケースに対応する。
        if topCategory == nil {
            kickAICategorySuggest(title: trimmed, in: sheet)
        }
    }

    /// FoundationModels で「タイトルからカテゴリを推測」を非同期で行う。
    /// 連続入力中はデバウンスしつつ前の Task をキャンセル。利用不可ならスキップ。
    @MainActor
    private func kickAICategorySuggest(title: String, in sheet: ExpenseSheet) {
        guard CategoryAISuggestor.isAvailable else { return }
        let cats = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let kindCats = cats.filter { c in
            let raw = c.kindRaw ?? ""
            return raw == kind.rawValue || (kind == .expense && raw.isEmpty)
        }
        let names = kindCats.map { $0.displayName }
        guard !names.isEmpty else { return }

        let snapshotKind = kind
        let snapshotTitle = title

        isComputingAICategory = true
        aiSuggestTask = Task { @MainActor in
            // デバウンス。typing が落ち着くまで待つ
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            let suggested = await CategoryAISuggestor.suggest(
                title: snapshotTitle,
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

    /// サジェストを適用。フィールドが空 / 自動初期値のままなら上書きし、ユーザーが
    /// 手で変更したと推測できる場合は上書きしない。kind は現在の値で絞り込まれているため触らない。
    @MainActor
    private func applySuggestion(_ s: TitleSuggestion) {
        if amountText.isEmpty, let amt = s.amount {
            amountText = NSDecimalNumber(decimal: amt).stringValue
        }
        if selectedCategory == nil, let cat = s.category {
            selectedCategory = cat
        }
        // selectedPayer は loadIfNeeded で自分にデフォルト初期化される。
        // 自分のままなら "ユーザーが意図して選んだ" わけではないので、サジェストの payer で上書きする。
        let isDefaultPayer: Bool = {
            guard let payer = selectedPayer, let myID = profile.selfMemberID else { return false }
            return payer.id == myID
        }()
        if (selectedPayer == nil || isDefaultPayer),
           let mid = s.payerMemberID,
           mid != profile.selfMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", mid as CVarArg)
            req.fetchLimit = 1
            if let m = (try? viewContext.fetch(req))?.first {
                selectedPayer = m
            }
        }
        Haptics.success()
    }

    @ViewBuilder
    private var photoSection: some View {
        Section("写真 (任意)") {
            if let data = photoData, let img = UIImage(data: data) {
                photoRow(image: img)
            } else {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("写真を追加", systemImage: "photo.on.rectangle.angled")
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let raw = try? await item.loadTransferable(type: Data.self) {
                    // 大きすぎる写真は CloudKit 同期と Core Data 容量の負担が
                    // 大きいので JPEG で軽く圧縮 + 長辺リサイズしてから保存する。
                    photoData = Self.compressForStorage(raw)
                }
            }
        }
    }

    /// 写真本体 + 差し替え/削除ボタンの行。Dynamic Type が AX サイズの時は
    /// 2 行レイアウト (サムネが上、ボタン群が下) に折り返して、
    /// 1 行に詰まって崩れるのを防ぐ。
    @ViewBuilder
    private func photoRow(image: UIImage) -> some View {
        let thumb = Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        let replaceButton = PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("差し替え", systemImage: "arrow.triangle.2.circlepath")
        }
        let deleteButton = Button(role: .destructive) {
            photoData = nil
            selectedPhotoItem = nil
        } label: {
            Label("削除", systemImage: "trash")
        }

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                thumb
                HStack(spacing: 16) {
                    replaceButton
                    Spacer()
                    deleteButton
                }
            }
        } else {
            HStack(spacing: 12) {
                thumb
                replaceButton
                Spacer()
                deleteButton
                    .labelStyle(.iconOnly)
            }
        }
    }

    /// 受け取った Data を JPEG 圧縮 + 長辺 1600px に縮小して Data に戻す。
    /// 失敗時は元の Data をそのまま返す (= ベクター画像など UIImage 化できないケース)。
    private static func compressForStorage(_ raw: Data) -> Data {
        guard let img = UIImage(data: raw) else { return raw }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.7) ?? raw
    }

    @ViewBuilder
    private var recurringSection: some View {
        if case .edit(let expense) = mode, let rule = expense.relatedRule {
            // 既に Rule から生成された支出は、ここで Toggle / Stepper を編集させると
            // 「この項目だけ」と「Rule 全体」が混ざって混乱しやすい。
            // → 編集シートを閉じて、SheetDetailView 側で「定期項目」一覧 →
            //   その Rule の編集 view を直接開く動線にする。
            Section {
                Button {
                    if hasUnsavedChanges {
                        // 未保存の変更があれば、いったんダイアログで確認。
                        // 破棄を選ばれたらそのまま onEditRule にハンドオフ。
                        pendingEditRuleAction = rule
                        showDiscardConfirm = true
                    } else {
                        onEditRule?(rule)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "repeat")
                            .frame(width: 22)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("定期項目を編集")
                                .foregroundStyle(.primary)
                            Text(rule.resolvedFrequency.summary(interval: Int(rule.resolvedInterval)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } header: {
                Text("繰り返し")
            } footer: {
                Text("この項目は定期項目から自動生成されています。頻度・間隔・終了日は定期項目の編集画面で変更できます。")
                    .font(.caption2)
            }
        } else {
            Section {
                Toggle("繰り返し", isOn: $isRecurring)
                    .disabled(isRecurringLocked)
                if isRecurring {
                    Picker("頻度", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    Stepper(value: $recurringInterval, in: 1...60) {
                        HStack {
                            Text("間隔")
                            Spacer()
                            Text(frequency.summary(interval: recurringInterval))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("終了日を設定", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("終了日", selection: $endDate, in: date..., displayedComponents: [.date])
                    }
                }
            } header: {
                Text("繰り返し")
            } footer: {
                if isRecurring {
                    Text("この日付を開始日として、未生成分を自動的にシートに追加します。")
                        .font(.caption2)
                }
            }
        }
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

    private var sheetTint: Color {
        contextSheet?.tint ?? .accentColor
    }

    /// 現在値 (= ユーザーが触っている状態) を 1 つの値にまとめたもの。
    private var currentSnapshot: FieldSnapshot {
        FieldSnapshot(
            title: title,
            amountText: amountText,
            kind: kind,
            currencyCode: currencyCode,
            categoryID: selectedCategory?.objectID,
            payerID: selectedPayer?.objectID,
            date: date,
            note: note,
            photoByteCount: photoData?.count ?? 0
        )
    }

    /// 「ロード直後のスナップショット」と「現在値」が違うか。
    /// 1) load 中は `loadedSnapshot == nil` → false (= ダイアログ出ない)
    /// 2) ロード完了後にユーザーが何か変えた → スナップショットと差分 → true
    private var hasUnsavedChanges: Bool {
        guard let snap = loadedSnapshot else { return false }
        return snap != currentSnapshot
    }

    private func attemptDismiss() {
        if hasUnsavedChanges {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // segmented は AX サイズで label が切れて崩れるので、AX では
                    // 通常の (Label 付きの) menu スタイルに切り替える。
                    kindPicker
                        .onChange(of: kind) { _, newKind in
                            // 既存の selectedCategory が新 kind に合っていればそのまま保つ。
                            if let cur = selectedCategory, cur.kind == newKind {
                                recomputeTitleSuggestion()
                                return
                            }
                            // 種別が変わって既存カテゴリが合わない時は未分類に戻す
                            selectedCategory = nil
                            recomputeTitleSuggestion()
                        }
                        .listRowBackground(dynamicTypeSize.isAccessibilitySize ? nil : Color.clear)
                }


                Section("内容") {
                    TextField(kind == .expense ? "タイトル (例: スーパー)" : "タイトル (例: 給料)", text: $title)
                        .onChange(of: title) { _, _ in
                            recomputeTitleSuggestion()
                        }
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

                suggestionSection
                aiCategorySuggestionSection

                categorySection

                Section("日時") {
                    DatePicker("日付", selection: $date, displayedComponents: [.date])
                    // WWDC24 「ダイナミックタイプの導入」で紹介された AnyLayout を
                    // 使い、AX では VStack (縦)、それ以外は HStack (横) に。
                    datePresetLayout {
                        datePresetButton("今日", offset: 0)
                        datePresetButton("昨日", offset: -1)
                        datePresetButton("一昨日", offset: -2)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer()
                        }
                    }
                }

                payerSection

                if kind == .expense, let sheet = contextSheet {
                    Section {
                        NavigationLink {
                            DiscardGuardedBack(modifier: discardDialogModifier) {
                                BeneficiaryPickerView(selected: $selectedBeneficiaries, record: sheet)
                            }
                        } label: {
                            beneficiaryLabel(sheet: sheet)
                        }
                    } footer: {
                        Text("精算する際にこの支出を誰の負担として割るかを指定します。未指定の場合はシート全員で均等割り。")
                            .font(.caption2)
                    }
                }

                recurringSection

                Section("メモ (任意)") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                photoSection

                if case .create = mode, canSave {
                    Section {
                        Button {
                            showingSaveTemplateConfirm = true
                        } label: {
                            Label("現在の内容をテンプレに保存", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
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
            .tint(sheetTint)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        attemptDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.primary)
                    .modifier(discardDialogModifier)
                    // 長押しで Large Content Viewer (= 拡大ラベル) を表示
                    .accessibilityShowsLargeContentViewer {
                        Label("キャンセル", systemImage: "xmark")
                    }
                }
                if case .create = mode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if ReceiptCameraScanner.isAvailable {
                                Button {
                                    showCameraScanner = true
                                } label: {
                                    Label("カメラで撮影", systemImage: "camera.viewfinder")
                                }
                            }
                            Button {
                                showPhotoScanner = true
                            } label: {
                                Label("写真ライブラリから", systemImage: "photo.on.rectangle")
                            }
                        } label: {
                            Image(systemName: "text.viewfinder")
                        }
                        .tint(.primary)
                        .accessibilityShowsLargeContentViewer {
                            Label("レシートから読み込み", systemImage: "text.viewfinder")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingTemplatePicker = true
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .tint(.primary)
                        .accessibilityShowsLargeContentViewer {
                            Label("テンプレから入力", systemImage: "doc.on.doc")
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm) {
                        trySave()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(!canSave)
                    .tint(sheetTint)
                    .accessibilityShowsLargeContentViewer {
                        Label("保存", systemImage: "checkmark")
                    }
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
            .confirmationDialog(
                "「\(title.trimmingCharacters(in: .whitespaces))」をテンプレに保存しますか?",
                isPresented: $showingSaveTemplateConfirm,
                titleVisibility: .visible
            ) {
                Button("保存") { saveCurrentAsTemplate() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("テンプレは「定期項目」メニューから管理できます。日付以外の入力内容が保存されます。")
            }
            .sheet(isPresented: $showingTemplatePicker) {
                if let sheet = contextSheet {
                    TemplatePickerView(record: sheet) { tpl in
                        applyTemplate(tpl)
                    }
                }
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
        // NavigationStack の外側 = シートのルートビューに適用すると、
        // `DismissAwareHostingController` がシートのホスト VC そのものに
        // なって delegate が確実に届く。
        // (内側に置くと UINavigationController の子 VC になってしまう)
        .onAttemptToDismiss(
            shouldAllowDismiss: { !hasUnsavedChanges },
            onAttempt: { showDiscardConfirm = true }
        )
    }

    /// AX で縦 (VStack)、通常で横 (HStack) に切り替える `AnyLayout`。
    /// (WWDC 24 「ダイナミックタイプの導入」推奨パターン)
    private var datePresetLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    /// 種別 Picker。AX サイズでは segmented が切れて崩れるので menu に切り替える。
    @ViewBuilder
    private var kindPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("種別", selection: $kind) {
                ForEach(TransactionKind.allCases) { k in
                    Label(k.label, systemImage: k.symbol).tag(k)
                }
            }
            .pickerStyle(.menu)
        } else {
            Picker("種別", selection: $kind) {
                ForEach(TransactionKind.allCases) { k in
                    Label(k.label, systemImage: k.symbol).tag(k)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var categorySection: some View {
        Section("カテゴリ") {
            if let sheet = contextSheet {
                NavigationLink {
                    DiscardGuardedBack(modifier: discardDialogModifier) {
                        CategoryPickerView(selected: $selectedCategory, record: sheet, kind: kind)
                    }
                } label: {
                    LabeledContent("カテゴリ") {
                        if let cat = selectedCategory {
                            HStack(spacing: 6) {
                                CategoryIconView(category: cat, size: 24)
                                Text(cat.displayName)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("未選択")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var payerSection: some View {
        Section(kind.partyLabel) {
            NavigationLink {
                DiscardGuardedBack(modifier: discardDialogModifier) {
                    MemberPickerView(
                        selected: $selectedPayer,
                        record: contextSheet,
                        kind: kind,
                        fallbackPaidBy: payerFallbackName,
                        fallbackProfileID: payerFallbackProfileID
                    )
                }
            } label: {
                LabeledContent(kind.partyLabel) {
                    payerPreview
                }
            }
        }
    }

    @ViewBuilder
    private func beneficiaryLabel(sheet: ExpenseSheet) -> some View {
        LabeledContent("受益者") {
            Text(beneficiarySummary(in: sheet))
                .foregroundStyle(.secondary)
                // AX サイズでは LabeledContent が縦積みになるので、
                // 切り詰めを許して横で済ませるのは normal サイズだけにする。
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
        }
    }

    /// xmark / 各サブ view に共通で当てる「変更を破棄しますか?」ダイアログ。
    /// 同じ `$showDiscardConfirm` バインディングなので、その時点で
    /// 表示中の view (= xmark を含む AddExpenseView 本体 or push 済みサブ view)
    /// に dialog アンカーがあれば、そこからシートが開く。
    private var discardDialogModifier: DiscardConfirmModifier {
        DiscardConfirmModifier(
            isPresented: $showDiscardConfirm,
            onDiscard: {
                if let rule = pendingEditRuleAction {
                    onEditRule?(rule)
                    pendingEditRuleAction = nil
                }
                dismiss()
            },
            onContinue: {
                pendingEditRuleAction = nil
            }
        )
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
        if (photoData?.count ?? 0) != origPhotoByteCount { return true }
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
        if (photoData?.count ?? 0) != origPhotoByteCount { expense.photoData = photoData }
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

        // 繰り返しの頻度・間隔・終了日の変更は scope に関わらず常に Rule に反映
        applyRecurringChanges(for: expense)

        PersistenceController.shared.save()
        RecurringExpenseGenerator.generateAll(in: viewContext)
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
            // カテゴリは未分類 (nil) スタート。AI / 過去履歴 / 手動の提案で埋める。
            selectedCategory = nil
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
            photoData = expense.photoData
            selectedBeneficiaries = Set(expense.beneficiaryIDList)

            // 繰り返し state 復元 (関連 Rule があればその値、無ければ既定値で OFF)
            if let rule = expense.relatedRule {
                isRecurring = true
                frequency = rule.resolvedFrequency
                recurringInterval = Int(rule.resolvedInterval)
                if let end = rule.endDate {
                    hasEndDate = true
                    endDate = end
                }
            } else {
                isRecurring = false
            }

            // CRDT 用スナップショット
            origTitle = title
            origAmountText = amountText
            origKindRaw = expense.kindRaw ?? ""
            origCurrencyCode = expense.currencyCode ?? ""
            origCategoryObjectID = expense.category?.objectID
            origPayerProfileID = expense.payerProfileID ?? ""
            origDate = expense.date ?? .distantPast
            origNote = expense.note ?? ""
            origPhotoByteCount = expense.photoData?.count ?? 0
            origBeneficiaryCSV = selectedBeneficiaryCSV
            origIsRecurring = isRecurring
            origFrequencyRaw = frequency.rawValue
            origRecurringInterval = Int32(recurringInterval)
            origEndDate = hasEndDate ? endDate : nil
        }
        // ロード時の State 代入が反映されたあと (= 次の runloop) に
        // スナップショットを撮ることで、「ロード直後 = まだ汚れていない」
        // 状態を基準値にできる。今 runloop で撮ると、SwiftUI が State の
        // 反映前なので古い値で確定してしまうことがある。
        DispatchQueue.main.async {
            loadedSnapshot = currentSnapshot
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
            expense.photoData = photoData
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

            // 繰り返し ON: Rule を作成して、この Expense を「最初の occurrence」として連結する。
            if isRecurring {
                let rule = makeRule(in: record, startDate: date, amount: amountDecimal)
                rule.lastGeneratedDate = Calendar.current.startOfDay(for: date)
                expense.generatedFromRuleID = rule.id
            }
        case .edit(let expense):
            // 通常編集 (定期項目以外、または「この項目のみ」)。差分のみ書き戻し。
            viewContext.refresh(expense, mergeChanges: true)
            applyChanges(toExpense: expense, includeDate: true)

            // 繰り返し関連の差分を反映 (Rule の作成 / 更新)
            applyRecurringChanges(for: expense)
        }
        pc.save()
        // 繰り返しが付いた可能性があるので generator を回して未生成分を作る
        RecurringExpenseGenerator.generateAll(in: viewContext)
        Haptics.success()
        dismiss()
    }

    /// 繰り返し関連のフィールドを Rule に反映する。
    /// - 編集前は Rule 無しで、ON にした → Rule を新規作成して expense を最初の occurrence として連結
    /// - 既に Rule あり → 頻度・間隔・終了日の差分を Rule に書き戻し
    /// (Toggle が OFF にされるケースは isRecurringLocked で UI 側でブロック)
    private func applyRecurringChanges(for expense: Expense) {
        guard let sheet = expense.sheet else { return }
        if let rule = expense.relatedRule {
            // 既存 Rule の頻度・間隔・終了日を CRDT 差分で更新
            if frequency.rawValue != origFrequencyRaw {
                rule.frequency = frequency.rawValue
            }
            if Int32(recurringInterval) != origRecurringInterval {
                rule.interval = Int32(recurringInterval)
            }
            let newEnd: Date? = hasEndDate ? Calendar.current.startOfDay(for: endDate) : nil
            if newEnd != origEndDate {
                rule.endDate = newEnd
            }
        } else if isRecurring, !origIsRecurring,
                  let amount = amountDecimal {
            // 単発 Expense を繰り返しに変換 (option 2-i)
            let rule = makeRule(in: sheet, startDate: date, amount: amount)
            rule.lastGeneratedDate = Calendar.current.startOfDay(for: date)
            expense.generatedFromRuleID = rule.id
        }
    }

    // MARK: - Templates

    /// テンプレを選んだ時にフォーム値を上書きする (= ユーザーは保存ボタンを押すまで反映されない)。
    @MainActor
    private func applyTemplate(_ tpl: ExpenseTemplate) {
        title = tpl.displayTitle == "(無題)" ? "" : tpl.displayTitle
        if tpl.amountDecimal > 0 {
            amountText = NSDecimalNumber(decimal: tpl.amountDecimal).stringValue
        }
        kind = tpl.kind
        currencyCode = tpl.resolvedCurrencyCode
        note = tpl.note ?? ""
        if let cat = tpl.resolvedCategory { selectedCategory = cat }
        if let mid = tpl.payerMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", mid as CVarArg)
            req.fetchLimit = 1
            if let m = (try? viewContext.fetch(req))?.first {
                selectedPayer = m
            }
        }
        let csv = (tpl.beneficiaryProfileIDs ?? "")
        if !csv.isEmpty {
            selectedBeneficiaries = Set(tpl.beneficiaryIDList)
        }
    }

    /// 現在の入力内容をテンプレとして保存する。
    /// (日付・受益者の自動均等割りは含めず、それ以外を保存)
    @MainActor
    private func saveCurrentAsTemplate() {
        guard case .create(let sheet) = mode else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        let tpl = ExpenseTemplate(context: viewContext)
        if let store = sheet.objectID.persistentStore {
            viewContext.assign(tpl, to: store)
        }
        tpl.id = UUID()
        tpl.createdAt = .now
        tpl.sheet = sheet
        tpl.title = trimmedTitle
        if let amt = amountDecimal {
            tpl.amount = NSDecimalNumber(decimal: amt)
        }
        tpl.kindRaw = kind.rawValue
        tpl.currencyCode = currencyCode
        tpl.categoryRaw = selectedCategory?.name
        tpl.paidBy = selectedPayer?.name
        tpl.payerProfileID = selectedPayer?.profileID
        tpl.payerMemberID = selectedPayer?.id
        tpl.note = note
        tpl.beneficiaryProfileIDs = selectedBeneficiaryCSV
        // sortOrder は最大 + 1
        let req = NSFetchRequest<ExpenseTemplate>(entityName: "ExpenseTemplate")
        req.predicate = NSPredicate(format: "sheet == %@", sheet)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseTemplate.sortOrder, ascending: false)]
        req.fetchLimit = 1
        let nextOrder = ((try? viewContext.fetch(req))?.first?.sortOrder ?? -1) + 1
        tpl.sortOrder = nextOrder

        PersistenceController.shared.save()
        Haptics.success()
    }

    /// 現在のフォーム値から RecurringRule を作成する (シートと同じストアに割り当て)。
    private func makeRule(in sheet: ExpenseSheet, startDate: Date, amount: Decimal) -> RecurringRule {
        let rule = RecurringRule(context: viewContext)
        if let store = sheet.objectID.persistentStore {
            viewContext.assign(rule, to: store)
        }
        rule.id = UUID()
        rule.createdAt = .now
        rule.sheet = sheet
        rule.title = title.trimmingCharacters(in: .whitespaces)
        rule.amount = NSDecimalNumber(decimal: amount)
        rule.kindRaw = kind.rawValue
        rule.currencyCode = currencyCode
        rule.categoryRaw = selectedCategory?.name
        rule.paidBy = selectedPayer?.name
        rule.payerProfileID = selectedPayer?.profileID
        rule.note = note
        rule.frequency = frequency.rawValue
        rule.interval = Int32(recurringInterval)
        rule.startDate = Calendar.current.startOfDay(for: startDate)
        rule.endDate = hasEndDate ? Calendar.current.startOfDay(for: endDate) : nil
        return rule
    }
}

/// 各サブ view (CategoryPickerView 等) を NavigationLink で push する時に
/// この wrapper でくるんで、`.cancellationAction` 位置に **透明な 0pt の
/// プレースホルダ** を置き、それに `DiscardConfirmModifier` を当てる。
/// 自動の back chevron は触らない。
/// これで `showDiscardConfirm` が立った時、push 中のサブ view でも、
/// 透明アンカーから confirmation dialog が確実に出せる。
private struct DiscardGuardedBack<Content: View>: View {
    let modifier: DiscardConfirmModifier
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 0pt × 0pt の透明 view。タップ判定もアクセシビリティも
                    // なく、toolbar の見た目には影響しないが、SwiftUI の
                    // confirmationDialog がアンカーする実体として存在する。
                    // iOS 26 の `.sharedBackgroundVisibility(.hidden)` で、
                    // Liquid Glass の共有 bar 背景にもこの item が乗らないようにする
                    // (= バー上に幻のグラス枠が見えるのを防ぐ)
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .modifier(modifier)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

/// 「変更を破棄しますか?」ダイアログを複数の anchor (xmark / サブ view の戻るボタン)
/// に同じバインディングで適用するための共有 ViewModifier。
/// SwiftUI の `.confirmationDialog` はアンカー view が画面に存在しないと表示できない
/// ので、push 階層をまたいでも確実に出せるよう、各サブ view にも当てる。
private struct DiscardConfirmModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onDiscard: () -> Void
    let onContinue: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "変更を破棄しますか?",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("変更を破棄", role: .destructive, action: onDiscard)
            Button("編集を続ける", role: .cancel, action: onContinue)
        } message: {
            Text("入力中の内容は保存されません。")
        }
    }
}

/// 「閉じる前に確認すべき入力差分」を判定するためのフィールド一覧スナップショット。
/// `loadIfNeeded` 直後の値と `body` の現在値を `==` 比較して dirty 検知に使う。
struct FieldSnapshot: Equatable {
    let title: String
    let amountText: String
    let kind: TransactionKind
    let currencyCode: String
    let categoryID: NSManagedObjectID?
    let payerID: NSManagedObjectID?
    let date: Date
    let note: String
    /// 写真は Data を直接比較すると重いので、長さで軽量に近似する。
    /// (差し替えは長さも変わるのでこれで十分; 同じ長さで内容違いの誤判定は実用上無視できる)
    let photoByteCount: Int
}


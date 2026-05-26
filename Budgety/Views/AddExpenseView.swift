//
//  AddExpenseView.swift
//  Expenso
//

import SwiftUI
import CoreData
import PhotosUI
import CloudKit
import UIKit

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

    /// 現在のシートに対する CKShare (= 支払者の canonical ID 解決に使う)。
    /// 非共有シートなら nil。
    @MainActor
    private var contextShare: CKShare? {
        contextSheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
    }

    /// 選択中の支払者の payerProfileID。シート文脈に応じた canonical を返す。
    /// 自分なら canonical self ID (オーナーなら userRecordName、参加者なら "email:...")、
    /// それ以外なら Member.recordName。
    @MainActor
    private var selectedPayerProfileID: String? {
        selectedPayer?.resolvedProfileID(forShare: contextShare)
    }


    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pub = PublicProfileSync.shared

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var showingDeleteConfirm: Bool = false
    /// 金額・タイトルとも UIKit (UITextView) ベースの DynamicTextField を使う。
    /// SwiftUI の @FocusState を onAppear でトグルするとキーボードが画面ロード後に
    /// 遅れて出るため、UIKit の becomeFirstResponder() で即座に開く。
    @State private var amountFocused: Bool = false
    @State private var titleFocused: Bool = false
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
    /// 割り勘トグル。オフ = この支出は支払者のみの負担 (受益者 = 支払者)。
    /// オン = `selectedBeneficiaries` で割る相手を選ぶ (空 = 全員均等)。
    @State private var splitEnabled: Bool = false
    /// バーチャルメンバー追加 (Premium 機能)。
    @State private var showAddMemberPrompt = false
    @State private var newMemberName = ""
    @State private var memberPaywall = false

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
        guard amountDecimal != nil else { return false }
        // 割り勘オンのときは必ず 1 人以上選ぶ。空 (= 全員均等) を許すと、
        // あとで追加したメンバーが過去の支出に遡って含まれてしまうため。
        if kind == .expense, shouldShowSharingFields, splitEnabled, selectedBeneficiaries.isEmpty {
            return false
        }
        return true
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
                            .foregroundStyle(aiSymbolGradient)
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
                        Haptics.success()
                    } label: {
                        aiCategorySuggestionLabel(for: cat)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Apple Intelligence ブランド風グラデーション (紫→ピンク→オレンジ)。
    private var aiSymbolGradient: LinearGradient {
        LinearGradient(
            colors: [.purple, .pink, .orange],
            startPoint: .leading,
            endPoint: .trailing
        )
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
                        .foregroundStyle(aiSymbolGradient)
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
        Section {
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
                NavigationLink {
                    RecurringSettingsView(
                        isRecurring: $isRecurring,
                        frequency: $frequency,
                        interval: $recurringInterval,
                        hasEndDate: $hasEndDate,
                        endDate: $endDate,
                        startDate: date,
                        isLocked: isRecurringLocked
                    )
                } label: {
                    LabeledContent("繰り返し") {
                        Text(isRecurring
                             ? frequency.summary(interval: recurringInterval)
                             : "OFF")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

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

    /// 割り勘の「全員」ボタン: シートの全メンバーを受益者に追加。
    @MainActor
    private func selectAllBeneficiaries(sheet: ExpenseSheet) {
        for id in sheet.acceptedMemberProfileIDs() { selectedBeneficiaries.insert(id) }
    }

    /// 永続化用のソート済み CSV (順序非依存で同値判定するため)。
    private var selectedBeneficiaryCSV: String {
        selectedBeneficiaries.sorted().joined(separator: ",")
    }

    /// 実際に保存する受益者 CSV。
    /// - 共有していない (ソロ) シートでは従来どおり全員均等 (= 選択中、既定は空)。
    /// - 割り勘オン: 選択中の相手 (空 = 全員均等)。
    /// - 割り勘オフ: 支払者のみ (= 支払者の負担、精算で他者に割らない)。
    private var effectiveBeneficiaryCSV: String {
        guard shouldShowSharingFields else { return selectedBeneficiaryCSV }
        return splitEnabled ? selectedBeneficiaryCSV : (selectedPayerProfileID ?? "")
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

    /// 自分の per-sheet ParticipantProfile (= シート単位 override 含む)。
    /// 「未選択」状態のデフォルト候補表示でグローバルではなく per-sheet 値を出すため。
    /// canonical (このシート用) と旧 userRecordName 両方にマッチさせる。
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

    /// 編集中の支出に既に支払者 / 受益者の情報が入っているか
    /// (= 過去に共有中だった時に作成された支出。共有解除後も情報を保つために表示する)。
    private var existingSharingInfo: Bool {
        guard case .edit(let expense) = mode else { return false }
        if let pid = expense.payerProfileID, !pid.isEmpty { return true }
        if expense.payerMemberID != nil { return true }
        if let n = expense.paidBy, !n.isEmpty { return true }
        if let bs = expense.beneficiaryProfileIDs, !bs.isEmpty { return true }
        return false
    }

    /// 支払者 / 受益者セクションを表示するか。
    private var shouldShowSharingFields: Bool {
        hasOtherParticipants || existingSharingInfo
    }

    /// 編集中の支出を削除する。確認ダイアログ経由でのみ呼ばれる。
    @MainActor
    private func deleteExpense() {
        guard case .edit(let expense) = mode else { return }
        viewContext.delete(expense)
        PersistenceController.shared.save()
        Haptics.success()
        dismiss()
    }

    @ViewBuilder
    private var payerPreview: some View {
        // アイコンと名前は HStack で横並び固定 (ListRow / LabeledContent 内では
        // 改行されることがあるので明示的に並べる)。
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
        } else if case .edit(let expense) = mode,
                  let pid = expense.payerProfileID, !pid.isEmpty {
            // selectedPayer が解決失敗。編集対象 Expense の payerProfileID を canonical として
            // 動的に名前/写真を引く (= PP / CKShare 参加者 / paidBy fallback)。
            // 「未指定 = 自分」という思い込みで誤って自分を表示しない。
            let name = expense.displayPaidBy.isEmpty ? "メンバー" : expense.displayPaidBy
            AvatarView(
                photoData: expense.payerPhotoData,
                displayName: name,
                colorHex: hexString(from: expense.payerTint) ?? "#8E8E93",
                size: 24
            )
            Text(name).foregroundStyle(.secondary)
        } else if case .edit = mode {
            // 編集モードで真に未指定 (payerProfileID / paidBy / payerMemberID 全部空)
            // の場合は「未選択」と表示する。自分にフォールバックしない。
            unspecifiedPayerPreview
        } else if let name = payerFallbackName {
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
        } else if let pp = selfParticipantProfileInSheet {
            ObservedParticipantProfileAvatar(profile: pp, size: 24)
            Text((pp.displayName?.isEmpty == false ? pp.displayName! : profile.resolvedDisplayName))
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

    /// 編集モードで payer が真に未指定の時の preview。
    /// 「？マーク dashed circle」+ 「未選択」テキストを薄色で出す。
    private var unspecifiedPayerPreview: some View {
        Group {
            ZStack {
                Circle()
                    .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 24, height: 24)
                Image(systemName: "questionmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text("未選択").foregroundStyle(.secondary)
        }
    }

    /// Color → "#RRGGBB" を簡易に取り出すヘルパー (取得できないなら nil)
    private func hexString(from color: Color) -> String? {
        #if canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
        return nil
        #endif
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
            List {
                // 種別 (支出 / 収入) は新規作成時のみ切り替え可能。
                if case .create = mode {
                    Section {
                        kindPicker
                            .listRowBackground(dynamicTypeSize.isAccessibilitySize ? nil : Color.clear)
                            .ignoresSafeArea()
                    }
                    .listSectionSeparator(.hidden)
                }


                Section {
                    // 金額を先に入力する。
                    HStack(spacing: 6) {
                        Text(CurrencyCatalog.option(for: currencyCode).symbol)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .leading)
                        // UIKit (UITextView) ベース。onAppear で focus を立てると即座に
                        // キーボードが開く (SwiftUI TextField + @FocusState だと遅延する)。
                        // 数字キーボードには Return が無いので「次へ」アクセサリでタイトルへ送る。
                        DynamicTextField(
                            text: $amountText,
                            focus: $amountFocused,
                            placeholder: "0",
                            font: .monospacedDigitSystemFont(
                                ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize,
                                weight: .regular),
                            keyboardType: decimalKeypadNeeded ? .decimalPad : .numberPad,
                            accessoryNextTitle: "次へ",
                            onAccessoryNext: { amountFocused = false; titleFocused = true }
                        )
                        .onChange(of: amountText) { _, new in
                            // 全角数字 / 全角ピリオドを半角に正規化してから許可文字でフィルタ
                            let normalized = new
                                .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? new
                            let allowed = decimalKeypadNeeded
                                ? normalized.filter { $0.isASCII && ($0.isNumber || $0 == ".") }
                                : normalized.filter { $0.isASCII && $0.isNumber }
                            if allowed != new { amountText = allowed }
                        }
                    }
                    // 次にタイトルを入力する。
                    DynamicTextField(
                        text: $title,
                        focus: $titleFocused,
                        placeholder: kind == .expense ? "タイトル (例: スーパー)" : "タイトル (例: 給料)",
                        onSubmit: { titleFocused = false }
                    )
                    .onChange(of: title) { _, _ in
                        recomputeTitleSuggestion()
                    }
                    Picker("通貨", selection: $currencyCode) {
                        ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                            Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                suggestionSection
                aiCategorySuggestionSection

                categorySection

                Section {
                    DatePicker("日付", selection: $date, displayedComponents: [.date])
                }

                payerSection

                if kind == .expense, shouldShowSharingFields, let sheet = contextSheet {
                    Section {
                        Toggle("割り勘", isOn: Binding(
                            get: { splitEnabled },
                            set: { on in
                                splitEnabled = on
                                // オンにした直後は全員を選択する (空 = 全員にはしない)。
                                // 後から相手を絞れる。空のまま保存させないため。
                                if on, selectedBeneficiaries.isEmpty
                                    || selectedBeneficiaries == Set([selectedPayerProfileID ?? ""]) {
                                    selectAllBeneficiaries(sheet: sheet)
                                }
                            }
                        ))
                        if splitEnabled {
                            // 別画面に遷移せず、この場でメンバーを選ぶ (インライン)。
                            // 候補は参加中 (受諾済み) のメンバー + バーチャルメンバー。
                            ForEach(sheet.acceptedMemberProfileIDs(), id: \.self) { id in
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
                                Text("割る相手")
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
                        Text(splitEnabled
                             ? (selectedBeneficiaries.isEmpty
                                ? "割る相手を 1 人以上選んでください。"
                                : "チェックした人で均等割りします。")
                             : "オフのときはこの支出を支払者の負担として扱い、精算では割りません。")
                            .foregroundStyle(splitEnabled && selectedBeneficiaries.isEmpty ? Color.red : Color.secondary)
                    }
                }

                recurringSection

                Section {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                photoSection

                if case .edit = mode {
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
            .tint(sheetTint)
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: kind) { _, newKind in
                // 種別変更時にカテゴリの整合を取り、提案も再計算
                if let cur = selectedCategory, cur.kind == newKind {
                    recomputeTitleSuggestion()
                    return
                }
                selectedCategory = nil
                recomputeTitleSuggestion()
            }
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
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") {
                        trySave()
                    }
                    .disabled(!canSave)
                    .tint(sheetTint)
                }
            }
            // ロック中はロック画面を overlay で重ねる (再ホストしないので入力を保持)。
            .lockOverlay(contextSheet)
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
                "この支出を削除しますか？",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) { deleteExpense() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("元に戻せません。")
            }
            .onAppear {
                loadIfNeeded()
                // 新規追加時はキーボードを自動で開いて金額にフォーカス (金額を先に入力)。
                // 編集 (.edit) では既存値を読みやすくするため自動フォーカスしない。
                if case .create = mode {
                    amountFocused = true
                }
            }
            .onDisappear {
                amountFocused = false
                titleFocused = false
            }
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
        }
        // NavigationStack の外側 = シートのルートビューに適用すると、
        // `DismissAwareHostingController` がシートのホスト VC そのものに
        // なって delegate が確実に届く。
        // (内側に置くと UINavigationController の子 VC になってしまう)
        .onAttemptToDismiss(
            shouldAllowDismiss: { !hasUnsavedChanges },
            onAttempt: { showDiscardConfirm = true }
        )
        .ignoresSafeArea()
        // 注意: ここに sheetLockCover (fullScreenCover) を付けると、
        // DismissAwareHostingController を使うこのシートが再ホストされ、
        // @State がリセットされて編集中の入力が消える。編集画面のロック保護は
        // 行わない (詳細/精算など push 画面のみ sheetLockCover で保護)。
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
        Section {
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
        Section {
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
        if (selectedPayerProfileID ?? "") != origPayerProfileID { return true }
        if selectedCategory?.objectID != origCategoryObjectID { return true }
        if effectiveBeneficiaryCSV != origBeneficiaryCSV { return true }
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
        let newPayerProfileID = selectedPayerProfileID ?? ""
        if newPayerProfileID != origPayerProfileID {
            expense.payerProfileID = selectedPayerProfileID
            // paidBy は denormalized キャッシュなので書かない。表示は payerProfileID +
            // CKShare 参加者 / UserProfileStore から動的解決される。
            expense.paidBy = nil
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
        if effectiveBeneficiaryCSV != origBeneficiaryCSV {
            expense.beneficiaryProfileIDs = effectiveBeneficiaryCSV
        }
        // 受益者から外した人の精算済みフラグを掃除する。
        expense.pruneSettledBeneficiaries()
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
        let newPayerProfileID = selectedPayerProfileID ?? ""
        if newPayerProfileID != origPayerProfileID {
            rule.payerProfileID = selectedPayerProfileID
            rule.paidBy = nil
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
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.platformTertiarySystemBackground)
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
            // 受益者が「支払者ただ 1 人」なら割り勘オフ (支払者のみの負担)。
            // 空 (=全員) や複数なら割り勘オン。
            let loadedPayerID = expense.payerProfileID ?? ""
            splitEnabled = !(!loadedPayerID.isEmpty && selectedBeneficiaries == Set([loadedPayerID]))
            // 旧「全員均等」(空) の支出を編集する場合は、現在のメンバーを明示選択に展開して
            // 保存できるようにする (空のままだと保存不可のため)。
            if splitEnabled, selectedBeneficiaries.isEmpty {
                selectedBeneficiaries = Set(expense.sheet?.acceptedMemberProfileIDs() ?? [])
            }

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
            expense.paidBy = nil
            expense.payerProfileID = selectedPayerProfileID
            expense.payerMemberID = selectedPayer?.id
            expense.date = date
            expense.note = note
            expense.photoData = photoData
            expense.createdAt = .now
            expense.beneficiaryProfileIDs = effectiveBeneficiaryCSV

            expense.sheet = record
            // category は Expense と同じストア (= sheet と同じストア) に居る前提でのみ紐付ける
            if let cat = selectedCategory,
               cat.objectID.persistentStore == sheetStore {
                expense.category = cat
            }
            // 自分の ParticipantProfile を同シートに ensure (まだ無ければ作成、あれば更新)
            if BuildInfo.profileFeatureEnabled {
                profile.ensureProfile(in: record, ctx: viewContext)
            }

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
        rule.paidBy = nil
        rule.payerProfileID = selectedPayerProfileID
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


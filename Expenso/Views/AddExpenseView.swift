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
                            CategoryPickerView(selected: $selectedCategory, record: sheet)
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

                Section("支払者") {
                    NavigationLink {
                        MemberPickerView(selected: $selectedPayer, record: contextSheet)
                    } label: {
                        HStack {
                            Text("支払者")
                            Spacer()
                            if let m = selectedPayer {
                                ObservedMemberAvatar(member: m, size: 24)
                                Text(m.displayName)
                                    .foregroundStyle(.secondary)
                            } else {
                                // selectedPayer が未確定でも、登録済みのプロフィールがあれば自分として表示
                                AvatarView(
                                    photoData: profile.photoData,
                                    displayName: profile.resolvedDisplayName,
                                    colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                                    size: 24
                                )
                                Text(profile.resolvedDisplayName)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                    Button("保存") { save() }
                        .disabled(!canSave)
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

            // CRDT 用スナップショット
            origTitle = title
            origAmountText = amountText
            origKindRaw = expense.kindRaw ?? ""
            origCurrencyCode = expense.currencyCode ?? ""
            origCategoryObjectID = expense.category?.objectID
            origPayerProfileID = expense.payerProfileID ?? ""
            origDate = expense.date ?? .distantPast
            origNote = expense.note ?? ""
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
            expense.date = date
            expense.note = note
            expense.createdAt = .now

            expense.sheet = record
            // category は Expense と同じストア (= sheet と同じストア) に居る前提でのみ紐付ける
            if let cat = selectedCategory,
               cat.objectID.persistentStore == sheetStore {
                expense.category = cat
            }
            // 自分の ParticipantProfile を同シートに ensure (まだ無ければ作成、あれば更新)
            profile.ensureProfile(in: record, ctx: viewContext)
        case .edit(let expense):
            // CloudKit 経由で取り込まれた最新値を取り込んでから差分のみ書き戻す。
            // (こうすることで、ユーザーが触っていないフィールドが他デバイスの更新を
            //  上書きしないようになる = 操作ベースの CRDT 動作)
            viewContext.refresh(expense, mergeChanges: true)

            let newTitle = title.trimmingCharacters(in: .whitespaces)
            if newTitle != origTitle {
                expense.title = newTitle
            }
            if amountText != origAmountText {
                expense.amount = NSDecimalNumber(decimal: amountDecimal)
            }
            if kind.rawValue != origKindRaw {
                expense.kindRaw = kind.rawValue
            }
            if currencyCode != origCurrencyCode {
                expense.currencyCode = currencyCode
            }
            if note != origNote {
                expense.note = note
            }
            if !Calendar.current.isDate(date, inSameDayAs: origDate) {
                expense.date = date
            }

            // 支払者: profileID + paidBy + Member 関係をひとセットでまとめて反映
            let newPayerProfileID = selectedPayer?.profileID ?? ""
            if newPayerProfileID != origPayerProfileID {
                expense.payerProfileID = selectedPayer?.profileID
                expense.paidBy = selectedPayer?.name
            }

            // カテゴリ: 元の category objectID と比較し、変更があった時のみ反映
            let newCategoryObjectID = selectedCategory?.objectID
            if newCategoryObjectID != origCategoryObjectID {
                expense.categoryRaw = selectedCategory?.name
                let expStore = expense.objectID.persistentStore
                if let cat = selectedCategory,
                   cat.objectID.persistentStore == expStore {
                    expense.category = cat
                } else {
                    expense.category = nil
                }
            }
        }
        PersistenceController.shared.save()
        Haptics.success()
        dismiss()
    }
}

//
//  VisionAddExpenseView.swift
//  Budgety For visionOS
//
//  シンプル版の支出追加・編集フォーム。
//  - title / amount / date / category / kind を編集できる
//  - 支払者は「自分」固定 (canonical self ID を書く)
//

import SwiftUI
import CoreData

struct VisionAddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let sheet: ExpenseSheet
    let expense: Expense?
    var isVirtualDraft = false

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = .now
    @State private var kind: TransactionKind = .expense
    @State private var note: String = ""
    @State private var selectedCategory: ExpenseCategory?
    @State private var didLoad: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var choosingScope = false
    @State private var saveFailure: String?
    @State private var original: Fields?

    private struct Fields: Equatable {
        var title: String
        var amount: Decimal?
        var date: Date
        var kind: TransactionKind
        var note: String
        var category: NSManagedObjectID?
    }

    private var fields: Fields {
        Fields(title: title.trimmingCharacters(in: .whitespaces),
               amount: Decimal(string: amountText.replacingOccurrences(of: ",", with: "")),
               date: Calendar.current.startOfDay(for: date),
               kind: kind, note: note, category: selectedCategory?.objectID)
    }


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

    var body: some View {
        NavigationStack {
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
                Section("金額 (\(expense?.resolvedCurrencyCode ?? sheet.resolvedDefaultCurrencyCode))") {
                    TextField("0", text: $amountText)
                        .font(.sheetNumber(.body))
                }
                Section("日付") {
                    DatePicker("日付", selection: $date, displayedComponents: .date)
                }
                Section {
                    TransactionCategoryMenu(sheet: sheet, kind: kind, selection: $selectedCategory)
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
            .navigationTitle(expense == nil ? String(localized: "支出を追加") : String(localized: "支出を編集"))
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
                "この支出を削除しますか？",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    deleteExpense()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("元に戻せません。")
            }
            .confirmationDialog("変更の適用範囲", isPresented: $choosingScope, titleVisibility: .visible) {
                Button("この回のみ") { saveRecurring(.thisOnly) }
                Button("この回以降") { saveRecurring(.thisAndFollowing) }
                Button("すべて") { saveRecurring(.all) }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("保存に失敗しました: \(saveFailure ?? "")", isPresented: Binding(
                get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
            .onAppear { loadIfNeeded() }
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let e = expense {
            title = e.displayTitle
            amountText = NSDecimalNumber(decimal: e.amountDecimal).stringValue
            date = e.date ?? .now
            kind = e.kind
            note = e.note ?? ""
            selectedCategory = e.category.flatMap { try? viewContext.existingObject(with: $0.objectID) as? ExpenseCategory }
            original = fields
        } else {
            // 新規: 最初のカテゴリを既定にする
            selectedCategory = categories.first
        }
    }

    private func trySave() {
        guard let expense, isVirtualDraft || expense.relatedRule != nil else { save(); return }
        guard fields != original else { dismiss(); return }
        choosingScope = true
    }

    private func saveRecurring(_ scope: RecurringEditScope) {
        guard let expense, let context = expense.managedObjectContext, let original else { return }
        let changes = fields
        do {
            try RecurringExpenseGenerator.edit(expense, scope: scope, isVirtualDraft: isVirtualDraft) { row, includeDate in
                if changes.title != original.title { row.title = changes.title }
                if changes.amount != original.amount, let amount = changes.amount { row.amountDecimal = amount }
                if changes.kind != original.kind { row.kindRaw = changes.kind.rawValue }
                if changes.note != original.note { row.note = changes.note }
                if includeDate, changes.date != original.date { row.date = changes.date }
                if changes.category != original.category {
                    row.categoryRaw = selectedCategory?.name
                    row.category = changes.category.flatMap { try? context.existingObject(with: $0) as? ExpenseCategory }
                }
            } updateRule: { rule in
                if changes.title != original.title { rule.title = changes.title }
                if changes.amount != original.amount, let amount = changes.amount { rule.amountDecimal = amount }
                if changes.kind != original.kind { rule.kindRaw = changes.kind.rawValue }
                if changes.note != original.note { rule.note = changes.note }
                if changes.category != original.category { rule.categoryRaw = selectedCategory?.name }
            }
            try context.save()
        } catch {
            saveFailure = error.localizedDescription
            return
        }
        dismiss()
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) else { return }

        let profile = UserProfileStore.shared
        #if !os(watchOS)
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        let selfPID = profile.canonicalSelfID(forShare: share)
        #else
        let selfPID = profile.userRecordName
        #endif

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
            if let pid = selfPID { target.payerProfileID = pid }
            if let mid = profile.selfMemberID { target.payerMemberID = mid }
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
        PersistenceController.shared.save()
        dismiss()
    }

    private func deleteExpense() {
        guard let e = expense, let context = e.managedObjectContext else { return }
        RecurringExpenseGenerator.deleteExpense(e, in: context)
        do {
            try context.save()
        } catch {
            saveFailure = error.localizedDescription
            return
        }
        dismiss()
    }
}

import AppIntents
import CoreData
import SwiftUI

enum BatchTransactionMode: Identifiable {
    case add, edit
    var id: Self { self }
    var title: LocalizedStringKey { self == .add ? "まとめて追加" : "まとめて編集" }
}

struct BatchTransactionActions: View {
    @ObservedObject var sheet: ExpenseSheet
    @Binding var selection: BatchTransactionMode?

    var body: some View {
        if Self.isAvailable(for: sheet) {
            Button { selection = .add } label: {
                Label("まとめて追加", systemImage: "plus.rectangle.on.rectangle")
            }
            Button { selection = .edit } label: {
                Label("まとめて編集", systemImage: "square.and.pencil")
            }
        }
    }

    static func isAvailable(for sheet: ExpenseSheet) -> Bool {
        guard let context = sheet.managedObjectContext,
              let access = try? IntentSheetAccess(checking: context),
              access.allows(sheet) else { return false }
        return PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: sheet.objectID)
    }
}

struct BatchTransactionView: View {
    @ObservedObject var sheet: ExpenseSheet
    let mode: BatchTransactionMode
    @Environment(\.dismiss) private var dismiss
    @FetchRequest private var expenses: FetchedResults<Expense>
    @State private var entries: [Draft]
    @State private var selected: Set<NSManagedObjectID> = []
    @State private var editingSelection = false
    @State private var review: SiriBatchTransactionStore.Prepared?
    @State private var errorMessage: String?

    private struct Draft: Identifiable {
        let id = UUID()
        let source: Expense?
        let originalTitle: String
        let originalAmount: String
        let originalCurrency: String
        let originalDate: Date
        var title: String
        var amount: String
        var currency: String
        var date: Date
        var kind: TransactionKind

        init(sheet: ExpenseSheet, source: Expense? = nil) {
            self.source = source
            originalTitle = source?.displayTitle ?? ""
            originalAmount = source.map { $0.amountDecimal.formatted(.number.grouping(.never).precision(.fractionLength(0...38))) } ?? ""
            originalCurrency = source?.resolvedCurrencyCode ?? sheet.resolvedDefaultCurrencyCode
            originalDate = source?.date ?? .now
            title = originalTitle
            amount = originalAmount
            currency = originalCurrency
            date = originalDate
            kind = source?.kind ?? .expense
        }

        func parsedAmount() throws -> Decimal {
            let raw = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = raw.wholeMatch(of: Decimal.FormatStyle.number)?.output,
                  value > 0, !value.isNaN else { throw AppIntentError.invalidAmount }
            return value
        }

        func edit() throws -> SiriBatchTransactionStore.Edit {
            guard let source else { throw SiriBatchTransactionStore.BatchError.stale }
            return .init(identifier: source.objectID.uriRepresentation().absoluteString,
                         title: title == originalTitle ? nil : title,
                         amount: amount == originalAmount ? nil : try parsedAmount(),
                         currencyCode: currency == originalCurrency ? nil : currency,
                         date: date == originalDate ? nil : date)
        }
    }

    init(sheet: ExpenseSheet, mode: BatchTransactionMode) {
        self.sheet = sheet
        self.mode = mode
        _entries = State(initialValue: mode == .add ? [Draft(sheet: sheet)] : [])
        _expenses = FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
                                 predicate: NSPredicate(format: "sheet == %@ AND (isSkipped == NO OR isSkipped == nil)", sheet))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !BatchTransactionActions.isAvailable(for: sheet) {
                    ContentUnavailableView("このシートは編集できません", systemImage: "lock")
                } else if let review {
                    List {
                        Text(verbatim: review.summary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("保存") { save(review) }
                            .accessibilityIdentifier("batchSave")
                        Button("入力に戻る") { self.review = nil }
                    }
                } else if mode == .edit && !editingSelection {
                    selectionList
                } else {
                    editor
                }
            }
            .navigationTitle(review == nil ? mode.title : "変更内容の確認")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 380, idealHeight: 540)
        #endif
        .alert("保存できません", isPresented: Binding(get: { errorMessage != nil },
                                                   set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private var selectionList: some View {
        List {
            if expenses.isEmpty {
                Text("編集できる明細がありません")
            }
            ForEach(expenses, id: \.objectID) { expense in
                let isSelected = selected.contains(expense.objectID)
                Button {
                    if isSelected { selected.remove(expense.objectID) }
                    else { selected.insert(expense.objectID) }
                } label: {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(verbatim: expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle)
                            Text(verbatim: [expense.date?.formatted(date: .abbreviated, time: .omitted), expense.formattedSignedAmount]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .disabled(!PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: expense.objectID))
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("次へ") {
                    let previous = Dictionary(uniqueKeysWithValues: entries.compactMap { draft in
                        draft.source.map { ($0.objectID, draft) }
                    })
                    entries = expenses.filter { selected.contains($0.objectID) }.map {
                        previous[$0.objectID] ?? Draft(sheet: sheet, source: $0)
                    }
                    editingSelection = !entries.isEmpty
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private var editor: some View {
        List {
            ForEach($entries) { $entry in
                Section {
                    if mode == .add {
                        Picker("種類", selection: $entry.kind) {
                            ForEach(TransactionKind.allCases) { Text(verbatim: $0.label).tag($0) }
                        }
                    }
                    TextField("名前", text: $entry.title)
                        .accessibilityLabel("名前")
                    TextField("金額", text: $entry.amount)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityLabel("金額")
                    Picker("通貨", selection: $entry.currency) {
                        if !CurrencyCatalog.all.contains(where: { $0.code == entry.originalCurrency }) {
                            Text(verbatim: entry.originalCurrency).tag(entry.originalCurrency)
                        }
                        ForEach(CurrencyCatalog.allOrderedByLocale) { Text(verbatim: $0.code).tag($0.code) }
                    }
                    DatePicker("日付", selection: $entry.date, displayedComponents: .date)
                    if mode == .add && entries.count > 1 {
                        Button("この行を削除", role: .destructive) { entries.removeAll { $0.id == entry.id } }
                    }
                } header: {
                    if mode == .edit {
                        Text(verbatim: entry.originalTitle.isEmpty ? (entry.source?.categoryDisplayName ?? "") : entry.originalTitle)
                    }
                }
            }
            if mode == .add {
                Button { entries.append(Draft(sheet: sheet)) } label: {
                    Label("行を追加", systemImage: "plus")
                }
            } else {
                Button("選択に戻る") { editingSelection = false }
            }
            Button("内容を確認") { prepare() }
                .accessibilityIdentifier("batchReview")
        }
    }

    private func prepare() {
        do {
            let id = sheet.objectID.uriRepresentation().absoluteString
            switch mode {
            case .add:
                let rows = try entries.map {
                    SiriBatchTransactionStore.Entry(title: $0.title, amount: try $0.parsedAmount(),
                                                   kind: $0.kind, currencyCode: $0.currency, date: $0.date)
                }
                review = try SiriBatchTransactionStore.prepareAdd(sheetID: id, entries: rows)
            case .edit:
                review = try SiriBatchTransactionStore.prepareEdit(sheetID: id, edits: entries.map { try $0.edit() })
            }
        } catch { show(error) }
    }

    private func save(_ prepared: SiriBatchTransactionStore.Prepared) {
        do {
            try SiriBatchTransactionStore.commit(prepared)
            dismiss()
        } catch {
            review = nil
            show(error)
        }
    }

    private func show(_ error: Error) {
        if let localized = error as? CustomLocalizedStringResourceConvertible {
            errorMessage = String(localized: localized.localizedStringResource)
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

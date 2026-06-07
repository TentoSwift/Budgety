//
//  MacEditCategoryView.swift
//  Budgety For macOS
//
//  Mac 用のカテゴリ追加・編集ダイアログ。
//  MacEditSheetView と同じ「リマインダー風」のコンパクトレイアウトを使う。
//

import SwiftUI
import CoreData

struct MacEditCategoryView: View {
    enum Mode {
        case create(record: ExpenseSheet, defaultKind: TransactionKind)
        case edit(category: ExpenseCategory)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let mode: Mode
    /// 新規作成時、作成した ExpenseCategory を呼び出し元へ渡す (支出追加画面で自動選択する等)。
    var onCreate: ((ExpenseCategory) -> Void)? = nil

    @State private var name: String = ""
    @State private var selectedColor: String = "#FF9500"
    @State private var selectedSymbol: String = "fork.knife"
    @State private var kind: TransactionKind = .expense
    @State private var didLoad: Bool = false
    @State private var showingDeleteConfirm: Bool = false

    @State private var origColor: String = ""
    @State private var origSymbol: String = ""

    @State private var showingSymbolPicker: Bool = false
    @State private var showingPaywall: Bool = false
    @StateObject private var pm = PurchaseManager.shared

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// このカテゴリが属するシートのテーマカラー (Tint)。
    private var sheetTint: Color {
        switch mode {
        case .create(let record, _):
            return record.tint
        case .edit(let category):
            return category.sheet?.tint ?? .accentColor
        }
    }

    private var title: String {
        isEditing ? "カテゴリを編集" : "新しいカテゴリ"
    }

    private var selectedSwiftColor: Color {
        Color(hex: selectedColor) ?? .gray
    }

    private var useStackedLayout: Bool {
        dynamicTypeSize >= .accessibility1
    }

    private var labelColumnWidth: CGFloat {
        switch dynamicTypeSize {
        case .accessibility5, .accessibility4: return 140
        case .accessibility3, .accessibility2: return 120
        case .accessibility1, .xxxLarge:       return 100
        default:                               return 80
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ヘッダ (タブ風タイトル)
                HStack {
                    Spacer()
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selectedSwiftColor))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.bottom, 14)

                VStack(spacing: 16) {
                    // 名前
                    formRow(label: "名前:") {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 種別 (create のみ)
                    if !isEditing {
                        formRow(label: "種別:") {
                            Picker("", selection: $kind) {
                                Text("支出").tag(TransactionKind.expense)
                                Text("収入").tag(TransactionKind.income)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 240, alignment: .leading)
                            Spacer(minLength: 0)
                        }
                    }

                    // カラー + アイコン
                    colorAndIconRow

                    Divider().padding(.top, 4)

                    // ボタン
                    HStack {
                        if isEditing {
                            Button {
                                showingDeleteConfirm = true
                            } label: {
                                Text("削除")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        Spacer()
                        Button("キャンセル") { dismiss() }
                        Button(isEditing ? "保存" : "OK") { save() }
                            .keyboardShortcut(.return)
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
        .scrollIndicators(.never)
        .frame(width: 560)
        .frame(minHeight: 260, maxHeight: 720)
        .tint(sheetTint)
        .onAppear { loadIfNeeded() }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        .confirmationDialog(
            "「\(name)」を削除しますか？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("カテゴリなしに分類") { deleteCategory(deleteExpenses: false) }
            Button("カテゴリと支出をすべて削除", role: .destructive) {
                deleteCategory(deleteExpenses: true)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このカテゴリを使っている支出を「カテゴリなし」に変えてカテゴリのみ削除するか、支出ごとすべて削除するかを選んでください。")
        }
    }

    // MARK: - Form row helper

    @ViewBuilder
    private func formRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if useStackedLayout {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                content()
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .frame(width: labelColumnWidth, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    @ViewBuilder
    private var colorAndIconRow: some View {
        if useStackedLayout {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("カラー:")
                    colorGrid
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("アイコン:")
                    symbolPickerButton
                }
            }
        } else {
            HStack(alignment: .top, spacing: 24) {
                HStack(alignment: .top) {
                    Text("カラー:")
                        .frame(width: labelColumnWidth, alignment: .trailing)
                    colorGrid
                }
                Divider().frame(height: 60)
                HStack(spacing: 10) {
                    Text("アイコン:")
                    symbolPickerButton
                }
            }
        }
    }

    // MARK: - Color

    private var colorGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(28), spacing: 10), count: 6)
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(CategoryDefaults.palette, id: \.self) { hex in
                let isOn = (hex == selectedColor)
                Circle()
                    .fill(Color(hex: hex) ?? .blue)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if isOn {
                            Circle()
                                .stroke(Color(hex: hex) ?? .blue, lineWidth: 2)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedColor = hex }
            }
        }
    }

    // MARK: - Symbol picker

    private var symbolPickerButton: some View {
        Button {
            showingSymbolPicker.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(selectedSwiftColor)
                    .frame(width: 44, height: 44)
                Image(systemName: selectedSymbol)
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSymbolPicker, arrowEdge: .top) {
            symbolGrid
        }
    }

    private var symbolGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(CategoryDefaults.symbolSections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(section.symbols, id: \.self) { sym in
                                symbolButton(sym)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .frame(width: 320, height: 360)
    }

    @ViewBuilder
    private func symbolButton(_ sym: String) -> some View {
        let isSelected = (selectedSymbol == sym)
        let isLocked = CategoryDefaults.isPremiumSymbol(sym)
            && !pm.isPremium
            && sym != origSymbol
        Button {
            if isLocked {
                showingPaywall = true
            } else {
                selectedSymbol = sym
                showingSymbolPicker = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected
                          ? AnyShapeStyle(selectedSwiftColor)
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 36, height: 36)
                if isSelected {
                    Circle()
                        .stroke(selectedSwiftColor, lineWidth: 2)
                        .frame(width: 40, height: 40)
                }
                Image(systemName: sym)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .opacity(isLocked ? 0.45 : 1)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 13, y: 13)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lifecycle

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .create(_, let defaultKind):
            kind = defaultKind
            if defaultKind == .income {
                selectedColor = "#34C759"
                selectedSymbol = "briefcase.fill"
            }
        case .edit(let category):
            name = category.displayName
            selectedColor = category.displayColorHex
            selectedSymbol = category.displaySymbol
            kind = category.kind
            origColor = selectedColor
            origSymbol = selectedSymbol
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create(let sheet, _):
            let cat = ExpenseCategory(context: viewContext)
            if let store = sheet.objectID.persistentStore {
                viewContext.assign(cat, to: store)
            }
            cat.id = UUID()
            cat.name = trimmed
            cat.colorHex = selectedColor
            cat.symbol = selectedSymbol
            cat.kindRaw = kind.rawValue
            cat.isBuiltIn = false
            cat.createdAt = .now
            cat.sortOrder = nextSortOrder(in: sheet)
            cat.sheet = sheet
            PersistenceController.shared.save()
            onCreate?(cat)
        case .edit(let category):
            viewContext.refresh(category, mergeChanges: true)
            category.name = trimmed
            category.colorHex = selectedColor
            category.symbol = selectedSymbol
            PersistenceController.shared.save()
        }
        dismiss()
    }

    private func deleteCategory(deleteExpenses: Bool) {
        guard case .edit(let category) = mode else { return }
        EditCategoryView.deleteCategory(
            category,
            deleteExpenses: deleteExpenses,
            in: viewContext
        )
        dismiss()
    }

    private func nextSortOrder(in sheet: ExpenseSheet) -> Int32 {
        let req = NSFetchRequest<ExpenseCategory>(entityName: "ExpenseCategory")
        req.predicate = NSPredicate(format: "sheet == %@", sheet)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseCategory.sortOrder, ascending: false)]
        req.fetchLimit = 1
        if let last = (try? viewContext.fetch(req))?.first {
            return last.sortOrder + 1
        }
        return 0
    }
}

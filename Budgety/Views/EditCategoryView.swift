//
//  EditCategoryView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct EditCategoryView: View {
    enum Mode {
        case create(record: ExpenseSheet)
        case edit(category: ExpenseCategory)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let mode: Mode
    var defaultKind: TransactionKind = .expense
    var onSave: ((ExpenseCategory) -> Void)? = nil

    @State private var name: String = ""
    @State private var selectedColor: String = "#FF9500"
    @State private var selectedSymbol: String = "fork.knife"
    @State private var customColor: Color = .orange
    @State private var kind: TransactionKind = .expense
    @State private var didLoad: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var showingMoreIcons: Bool = false

    @State private var origName: String = ""
    @State private var origColor: String = ""
    @State private var origSymbol: String = ""
    @State private var showingPaywallForSymbol: Bool = false

    private var navTitle: String {
        switch mode {
        case .create: "新しいカテゴリ"
        case .edit:   "カテゴリを編集"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// iOS の confirmation ボタン文言。新規は「追加」、編集は「保存」。
    /// 他のシート (EditSheetView 等) のラベル運用に揃える。
    private var saveButtonLabel: String {
        switch mode {
        case .create: "追加"
        case .edit:   "保存"
        }
    }

    /// このカテゴリが属する (新規作成なら作成先の) シート。
    private var contextSheet: ExpenseSheet? {
        switch mode {
        case .create(let record): return record
        case .edit(let category): return category.sheet
        }
    }

    /// このシートで課金機能 (プレミアムアイコン) が使えるか。
    /// 自分が Premium、または共有シートなら true。
    private var premiumUnlocked: Bool {
        if let sheet = contextSheet { return PurchaseManager.hasPremiumAccess(to: sheet) }
        return PurchaseManager.isCurrentUserPremium
    }

    private var previewColor: Color {
        Color(hex: selectedColor) ?? .gray
    }

    private var isEditingBuiltIn: Bool {
        if case .edit(let cat) = mode { return cat.isBuiltIn }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    if case .create = mode {
                        kindCard
                    }
                    colorCard
                    iconCard
                    if case .edit = mode {
                        deleteCard
                    }
                }
                .padding()
            }
            .background(Color.platformSystemGroupedBackground.ignoresSafeArea())
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    #if os(macOS)
                    Button("完了") { save() }
                        .disabled(!canSave)
                        .keyboardShortcut(.return)
                    #else
                    Button(saveButtonLabel, systemImage: "checkmark") { save() }
                        .disabled(!canSave)
                    #endif
                }
            }
            .onAppear { loadIfNeeded() }
            .sheet(isPresented: $showingPaywallForSymbol) {
                PaywallView()
            }
            .confirmationDialog(
                "「\(name)」を削除しますか?",
                isPresented: $showDeleteConfirm,
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
    }

    // MARK: - Cards

    private var headerCard: some View {
        VStack(spacing: 18) {
            CategoryIconView(symbol: selectedSymbol, tint: previewColor, size: 92)
                .padding(.top, 24)
                .shadow(color: previewColor.opacity(0.4), radius: 16, x: 0, y: 6)
            TextField("カテゴリ名", text: $name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(Color.platformTertiarySystemBackground, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(Color.platformSecondarySystemGroupedBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private var kindCard: some View {
        HStack(spacing: 12) {
            CategoryIconView(symbol: kind.symbol, tint: kind == .income ? .green : .red, size: 36)
            Text("種別").font(.headline)
            Spacer()
            Menu {
                ForEach(TransactionKind.allCases) { k in
                    Button {
                        kind = k
                    } label: {
                        HStack {
                            Text(k.label)
                            if k == kind { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(kind.label)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.platformSecondarySystemGroupedBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private var colorCard: some View {
        // AX サイズでも列が詰まらないよう、最小幅 54pt の adaptive grid
        let columns = [GridItem(.adaptive(minimum: 54), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(CategoryDefaults.palette, id: \.self) { hex in
                colorCircle(hex: hex)
            }
            customColorPicker
        }
        .padding(16)
        .background(Color.platformSecondarySystemGroupedBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private func colorCircle(hex: String) -> some View {
        let color = Color(hex: hex) ?? .gray
        let isSelected = selectedColor == hex
        return Button {
            selectedColor = hex
            customColor = color
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 3)
                        .frame(width: 50, height: 50)
                }
                Circle()
                    .fill(color)
                    .frame(width: 40, height: 40)
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
    }

    /// パレットの最後にカスタムカラー用の ColorPicker (= 虹色のリング) を置く。
    private var customColorPicker: some View {
        let isCustom = !CategoryDefaults.palette.contains(selectedColor)
        return ZStack {
            if isCustom {
                Circle()
                    .stroke(Color.primary.opacity(0.35), lineWidth: 3)
                    .frame(width: 50, height: 50)
            }
            ColorPicker("", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40, height: 40)
                .onChange(of: customColor) { _, newValue in
                    selectedColor = newValue.toHex() ?? selectedColor
                }
        }
        .frame(width: 50, height: 50)
    }

    private var iconCard: some View {
        // AX サイズでも列が詰まらないよう、最小幅 54pt の adaptive grid
        let columns = [GridItem(.adaptive(minimum: 54), spacing: 14)]
        return VStack(alignment: .leading, spacing: 14) {
            // 基本セクションのみインライン表示
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(CategoryDefaults.freeSymbols, id: \.self) { sym in
                    iconButton(sym)
                }
            }
            // その他カテゴリは別画面で選択。Form 内の NavigationLink は行に
            // 自動でシェブロンが付き、カード内の手動シェブロンと二重になるため、
            // Button + navigationDestination でカスタムカードのまま遷移する。
            Button {
                showingMoreIcons = true
            } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Text("その他のアイコン")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.platformTertiarySystemBackground)
                )
            }
            .buttonStyle(.plain)
            .navigationDestination(isPresented: $showingMoreIcons) {
                CategoryIconPickerView(
                    selectedSymbol: $selectedSymbol,
                    tint: previewColor,
                    origSymbol: origSymbol,
                    premiumUnlocked: premiumUnlocked
                )
            }
        }
        .padding(16)
        .background(Color.platformSecondarySystemGroupedBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private func iconButton(_ sym: String) -> some View {
        let isSelected = selectedSymbol == sym
        let isPremiumOnly = CategoryDefaults.isPremiumSymbol(sym)
        // Premium symbol を非 Premium ユーザーが選ぶのを抑止。
        // ただし「既に保存済みのシンボル (= 編集ロード時にこの ID と一致)」は
        // ロックを外して再選択可能にする (= 後で課金が切れた時の救済)。
        let isLockedForUser = isPremiumOnly
            && !premiumUnlocked
            && sym != origSymbol
        return Button {
            if isLockedForUser {
                showingPaywallForSymbol = true
                Haptics.warning()
            } else {
                selectedSymbol = sym
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 3)
                        .frame(width: 50, height: 50)
                }
                Circle()
                    .fill(isSelected ? AnyShapeStyle(previewColor.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 40, height: 40)
                // 固定サイズで Dynamic Type に追従させない (AX で circle を突き抜けないように)
                Image(systemName: sym)
                    .foregroundStyle(isSelected ? .white : Color.primary)
                    .font(.system(size: 18, weight: .medium))
                    .opacity(isLockedForUser ? 0.45 : 1)
                if isLockedForUser {
                    // 右下に小さな鍵アイコン
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 14, y: 14)
                }
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
    }

    private var deleteCard: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("カテゴリを削除", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(Color.platformSecondarySystemGroupedBackground, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: - Toolbar circle button helper

    private func circleToolbarButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.platformTertiarySystemBackground))
        }
    }

    // MARK: - Lifecycle

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .create:
            kind = defaultKind
            if defaultKind == .income {
                selectedColor = "#34C759"
                selectedSymbol = "briefcase.fill"
            }
            customColor = Color(hex: selectedColor) ?? .orange
        case .edit(let category):
            name = category.displayName
            selectedColor = category.displayColorHex
            selectedSymbol = category.displaySymbol
            kind = category.kind
            customColor = Color(hex: selectedColor) ?? .gray

            origName = name
            origColor = selectedColor
            origSymbol = selectedSymbol
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create(let record):
            let pc = PersistenceController.shared
            let sheetStore = record.objectID.persistentStore

            let cat = ExpenseCategory(context: viewContext)
            if let store = sheetStore {
                viewContext.assign(cat, to: store)
            }

            cat.id = UUID()
            cat.name = trimmed
            cat.colorHex = selectedColor
            cat.symbol = selectedSymbol
            cat.kindRaw = kind.rawValue
            cat.isBuiltIn = false
            cat.createdAt = .now
            cat.sortOrder = nextSortOrder(in: record)
            cat.sheet = record
            pc.save()
            Haptics.success()
            onSave?(cat)
        case .edit(let category):
            viewContext.refresh(category, mergeChanges: true)
            if trimmed != origName { category.name = trimmed }
            if selectedColor != origColor { category.colorHex = selectedColor }
            if selectedSymbol != origSymbol { category.symbol = selectedSymbol }
            PersistenceController.shared.save()
            Haptics.success()
        }
        dismiss()
    }

    /// カテゴリを削除する。
    /// - Parameter deleteExpenses: `true` ならこのカテゴリを使っている支出もすべて削除。
    ///   `false` なら支出は残し、`category`/`categoryRaw` を空にして「カテゴリなし」扱いにする。
    private func deleteCategory(deleteExpenses: Bool) {
        guard case .edit(let category) = mode else { return }
        EditCategoryView.deleteCategory(
            category,
            deleteExpenses: deleteExpenses,
            in: viewContext
        )
        Haptics.warning()
        dismiss()
    }

    /// CategoryListView の swipe 削除と共有する実装。
    /// `category == self` リレーション一致だけでなく、`categoryRaw` 文字列一致もカバーする。
    /// ただし他シート / 別 kind に同名カテゴリがあるケースを誤爆しないよう、
    /// **同一シート + 同一 kind** に限定して `categoryRaw` 一致を引く。
    static func deleteCategory(_ category: ExpenseCategory,
                               deleteExpenses: Bool,
                               in ctx: NSManagedObjectContext) {
        let categoryName = category.name ?? ""
        let kindRaw = category.kindRaw ?? TransactionKind.expense.rawValue

        let req = NSFetchRequest<Expense>(entityName: "Expense")
        if let sheet = category.sheet, !categoryName.isEmpty {
            req.predicate = NSPredicate(
                format: "sheet == %@ AND (category == %@ OR (categoryRaw == %@ AND kindRaw == %@))",
                sheet, category, categoryName, kindRaw
            )
        } else {
            req.predicate = NSPredicate(format: "category == %@", category)
        }
        let related = (try? ctx.fetch(req)) ?? []

        if deleteExpenses {
            for e in related { ctx.delete(e) }
        } else {
            // category リレーションは deletionRule=Nullify で自動的に nil になるが、
            // categoryRaw 文字列は残るので明示的にクリアして「未分類」表示にする
            for e in related {
                e.categoryRaw = ""
                e.category = nil
            }
        }

        ctx.delete(category)
        PersistenceController.shared.save()
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

// MARK: - Color → Hex helper

private extension Color {
    func toHex() -> String? {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let R = Int((r * 255).rounded())
        let G = Int((g * 255).rounded())
        let B = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", R, G, B)
        #else
        return nil
        #endif
    }
}

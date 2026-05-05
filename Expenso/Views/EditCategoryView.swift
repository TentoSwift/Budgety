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
    var onSave: ((ExpenseCategory) -> Void)? = nil

    @State private var name: String = ""
    @State private var selectedColor: String = "#FF9500"
    @State private var selectedSymbol: String = "fork.knife"
    @State private var customColor: Color = .orange
    @State private var didLoad: Bool = false
    @State private var showDeleteConfirm: Bool = false

    // CRDT 用スナップショット
    @State private var origName: String = ""
    @State private var origColor: String = ""
    @State private var origSymbol: String = ""

    private var navTitle: String {
        switch mode {
        case .create: "新しいカテゴリ"
        case .edit: "カテゴリを編集"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("例: コーヒー", text: $name)
                }

                Section("プレビュー") {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(previewColor.opacity(0.18))
                                .frame(width: 56, height: 56)
                            Image(systemName: selectedSymbol)
                                .font(.title)
                                .foregroundStyle(previewColor)
                        }
                        Text(name.isEmpty ? "(名前未入力)" : name)
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("カラー") {
                    paletteRow
                    ColorPicker("カスタムカラー", selection: $customColor, supportsOpacity: false)
                        .onChange(of: customColor) { _, newValue in
                            selectedColor = newValue.toHex() ?? selectedColor
                        }
                }

                Section("アイコン") {
                    iconGrid
                }

                if case .edit(let category) = mode, !category.isBuiltIn {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("カテゴリを削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("このカテゴリを削除しても、紐付いていた支出は残ります。")
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
            .confirmationDialog("「\(name)」を削除しますか?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("削除", role: .destructive) { deleteCategory() }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    private var previewColor: Color {
        Color(hex: selectedColor) ?? .gray
    }

    private var paletteRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CategoryDefaults.palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selectedColor == hex {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .onTapGesture {
                            selectedColor = hex
                            customColor = Color(hex: hex) ?? .gray
                        }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var iconGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(CategoryDefaults.availableSymbols, id: \.self) { sym in
                Button {
                    selectedSymbol = sym
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedSymbol == sym ? previewColor.opacity(0.22) : Color(.tertiarySystemBackground))
                            .frame(height: 44)
                        Image(systemName: sym)
                            .foregroundStyle(selectedSymbol == sym ? previewColor : .primary)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selectedSymbol == sym ? previewColor : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .create:
            customColor = Color(hex: selectedColor) ?? .orange
        case .edit(let category):
            name = category.displayName
            selectedColor = category.displayColorHex
            selectedSymbol = category.displaySymbol
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
            // 親シートと同じストアに先に割り当てる (Shared シート対応)。
            // 順序が逆だとクロスストア関係でリレーション設定が失敗する。
            if let store = sheetStore {
                viewContext.assign(cat, to: store)
            }

            cat.id = UUID()
            cat.name = trimmed
            cat.colorHex = selectedColor
            cat.symbol = selectedSymbol
            cat.isBuiltIn = false
            cat.createdAt = .now
            cat.sortOrder = nextSortOrder(in: record)
            cat.sheet = record
            pc.save()
            Haptics.success()
            onSave?(cat)
        case .edit(let category):
            // 差分のみ書き戻し
            viewContext.refresh(category, mergeChanges: true)
            if trimmed != origName { category.name = trimmed }
            if selectedColor != origColor { category.colorHex = selectedColor }
            if selectedSymbol != origSymbol { category.symbol = selectedSymbol }
            PersistenceController.shared.save()
            Haptics.success()
        }
        dismiss()
    }

    private func deleteCategory() {
        if case .edit(let category) = mode {
            viewContext.delete(category)
            PersistenceController.shared.save()
            dismiss()
        }
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

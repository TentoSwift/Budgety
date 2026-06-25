//
//  BudgetyVisionContentView.swift
//  Budgety For visionOS
//
//  iOS 版 SheetListView 相当。左サイドバーにシート一覧、右に詳細。
//

import SwiftUI
import CoreData

struct BudgetyVisionContentView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)
        ],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var selectedSheet: ExpenseSheet?
    @State private var showingAddSheet: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let sheet = selectedSheet {
                BudgetyVisionSheetView(sheet: sheet)
            } else {
                ContentUnavailableView {
                    Label("シートを選択", systemImage: "rectangle.stack")
                } description: {
                    Text("左のリストからシートを選んでください。")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            VisionAddSheetView()
        }
        .onAppear {
            if selectedSheet == nil { selectedSheet = sheets.first }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSheet) {
            if sheets.isEmpty {
                Section {
                    Label("シートがありません", systemImage: "tray")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(sheets) { sheet in
                    NavigationLink(value: sheet) {
                        sheetRow(sheet)
                    }
                }
            }
        }
        .navigationTitle("Budgety")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("シートを追加")
            }
        }
    }

    private func sheetRow(_ sheet: ExpenseSheet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(sheet.tint.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: sheet.symbol ?? "person.2.fill")
                    .foregroundStyle(.white)
                    .font(.callout.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sheet.displayName).font(.body.weight(.medium))
                Text(monthlyLabel(for: sheet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if sheet.isOwnedByCurrentUser == false {
                Image(systemName: "person.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func monthlyLabel(for sheet: ExpenseSheet) -> String {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let monthlyTotal = ((sheet.expenses as? Set<Expense>) ?? [])
            .filter { e in
                guard let d = e.date, e.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: d)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        return String(localized: "今月 \(CurrencyCatalog.format(monthlyTotal, code: sheet.resolvedDefaultCurrencyCode))")
    }
}

// MARK: - 簡易シート追加 (シート名 + 色 + アイコン + 通貨)

struct VisionAddSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @State private var name: String = ""
    @State private var colorHex: String = "#5B8DEF"
    @State private var symbol: String = "person.2.fill"
    @State private var currencyCode: String = CurrencyCatalog.defaultCode

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]
    private let symbols: [String] = [
        "person.2.fill", "house.fill", "airplane",
        "cart.fill", "fork.knife", "gift.fill",
        "briefcase.fill", "book.fill"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("シート名") {
                    TextField("家計、旅行 など", text: $name)
                }
                Section("カラー") {
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if hex == colorHex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("アイコン") {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(symbols, id: \.self) { s in
                            Button {
                                symbol = s
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(symbol == s
                                              ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                              : AnyShapeStyle(.regularMaterial))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: s)
                                        .font(.callout)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("既定通貨") {
                    Picker("通貨", selection: $currencyCode) {
                        ForEach(CurrencyCatalog.all) { opt in
                            Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                        }
                    }
                }
            }
            .navigationTitle("新しいシート")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let sheet = ExpenseSheet(context: viewContext)
        sheet.name = name.trimmingCharacters(in: .whitespaces)
        sheet.colorHex = colorHex
        sheet.symbol = symbol
        sheet.defaultCurrencyCode = currencyCode
        sheet.createdAt = .now
        PersistenceController.seedDefaultCategories(for: sheet, in: viewContext)
        PersistenceController.shared.save()
        Task { @MainActor in
            await UserProfileStore.shared.ensureUserRecordNameLoaded()
            UserProfileStore.shared.ensureSelfMemberExists(in: viewContext)
            UserProfileStore.shared.ensureProfile(in: sheet, ctx: viewContext)
        }
        dismiss()
    }
}

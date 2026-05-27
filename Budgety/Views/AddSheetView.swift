//
//  AddSheetView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct AddSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @StateObject private var profile = UserProfileStore.shared

    @State private var name: String = ""
    @State private var note: String = ""
    @State private var selectedColor: String = "#5B8DEF"
    @State private var selectedSymbol: String = "person.2.fill"
    @State private var defaultCurrencyCode: String = CurrencyCatalog.defaultCode
    @State private var budgetText: String = ""

    @State private var showingPaywall: Bool = false
    @State private var showingMoreIcons: Bool = false

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// JPY/KRW など最小単位のない通貨は decimalPad 不要
    private var decimalKeypadNeeded: Bool {
        !["JPY", "KRW", "VND", "IDR"].contains(defaultCurrencyCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        SheetIconView.baseIcon(symbol: selectedSymbol,
                                               tint: Color(hex: selectedColor) ?? .blue,
                                               size: 72)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section("シート名") {
                    TextField("家族の家計、旅行など", text: $name)
                }

                Section("カラー") {
                    paletteRow
                }

                Section("アイコン") {
                    sheetIconGrid
                }

                Section {
                    currencyPicker
                } header: {
                    Text("既定通貨")
                } footer: {
                    Text("このシートに支出を追加する時の初期通貨。各支出ごとに通貨を変更することもできます。")
                }

                Section {
                    HStack(spacing: 6) {
                        Text(CurrencyCatalog.option(for: defaultCurrencyCode).symbol)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .leading)
                        TextField("0 (未設定)", text: $budgetText)
                            .keyboardType(decimalKeypadNeeded ? .decimalPad : .numberPad)
                            .monospacedDigit()
                            .onChange(of: budgetText) { _, new in
                                let allowed = decimalKeypadNeeded
                                    ? new.filter { $0.isNumber || $0 == "." }
                                    : new.filter { $0.isNumber }
                                if allowed != new { budgetText = allowed }
                            }
                    }
                } header: {
                    Text("月予算 (任意)")
                } footer: {
                    Text("「今月」表示時に進捗バーで残額を可視化します。0 のまま保存すると予算なし扱い。")
                }

                Section("メモ (任意)") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("新しいシート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成", systemImage: "checkmark") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var currencyPicker: some View {
        Picker("通貨", selection: $defaultCurrencyCode) {
            ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                Text(opt.symbol + "  " + opt.code + " — " + opt.displayName).tag(opt.code)
            }
        }
        #if os(macOS)
        .pickerStyle(.menu)
        #else
        .pickerStyle(.navigationLink)
        #endif
    }

    private var sheetIconGrid: some View {
        // AX サイズで列が詰まらないよう、最小幅 50pt の adaptive grid
        let columns = [GridItem(.adaptive(minimum: 50), spacing: 12)]
        let tint = Color(hex: selectedColor) ?? .blue
        return VStack(alignment: .leading, spacing: 12) {
            // 基本セクションのみインライン表示 (Free)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(SheetSymbols.freeOptions, id: \.self) { sym in
                    sheetIconButton(sym, tint: tint)
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
                SheetIconPickerView(selectedSymbol: $selectedSymbol, tint: tint)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }

    @ViewBuilder
    private func sheetIconButton(_ sym: String, tint: Color) -> some View {
        let isSelected = selectedSymbol == sym
        let isLocked = SheetSymbols.isPremiumSymbol(sym) && !PurchaseManager.shared.isPremium
        Button {
            if isLocked {
                showingPaywall = true
                Haptics.warning()
            } else {
                selectedSymbol = sym
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 3)
                        .frame(width: 46, height: 46)
                }
                Circle()
                    .fill(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 38, height: 38)
                // 固定サイズで Dynamic Type に追従させない (AX で circle を突き抜けないように)
                Image(systemName: sym)
                    .foregroundStyle(isSelected ? .white : Color.primary)
                    .font(.system(size: 17, weight: .medium))
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
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
    }

    /// カラーパレット。AX サイズで TextField の幅が広がっても自動で折り返すよう
    /// LazyVGrid(.adaptive) で並べる。
    private var paletteRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 40), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(palette, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex) ?? .blue)
                    .frame(width: 32, height: 32)
                    .overlay {
                        if hex == selectedColor {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .onTapGesture { selectedColor = hex }
            }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        let sheet = ExpenseSheet(context: viewContext)
        sheet.name = name.trimmingCharacters(in: .whitespaces)
        sheet.note = note
        sheet.colorHex = selectedColor
        sheet.symbol = selectedSymbol
        sheet.defaultCurrencyCode = defaultCurrencyCode
        sheet.monthlyBudgetDecimal = Decimal(string: budgetText)
        sheet.createdAt = .now
        PersistenceController.seedDefaultCategories(for: sheet, in: viewContext)
        PersistenceController.shared.save()
        // シート作成後に自分の ParticipantProfile を生成 (推進・受信両方の同期キー)
        Task { @MainActor in
            await profile.ensureUserRecordNameLoaded()
            profile.ensureSelfMemberExists(in: viewContext)
            profile.ensureProfile(in: sheet, ctx: viewContext)
        }
        Haptics.success()
        dismiss()
    }
}

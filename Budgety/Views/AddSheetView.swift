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

    /// AddSheetView を開いた時点でプロフィールが未設定だったかを記録。
    /// 一度入力したら以降のシートでは出さない (= 「最初のシート作成時のみ」UX)。
    @State private var needsProfileSetup: Bool

    @State private var showingPaywall: Bool = false

    init() {
        _needsProfileSetup = State(initialValue: UserProfileStore.shared.isEmpty)
    }

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]

    private var canSave: Bool {
        let nameOk = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let profileOk = !needsProfileSetup || !profile.isEmpty
        return nameOk && profileOk
    }

    /// JPY/KRW など最小単位のない通貨は decimalPad 不要
    private var decimalKeypadNeeded: Bool {
        !["JPY", "KRW", "VND", "IDR"].contains(defaultCurrencyCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                if needsProfileSetup {
                    profileSection
                }
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
            .navigationTitle("新しいシート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View { EmptyView() }

    private var currencyPicker: some View {
        Picker("通貨", selection: $defaultCurrencyCode) {
            ForEach(CurrencyCatalog.all) { opt in
                Text(opt.symbol + "  " + opt.code + " — " + opt.displayName).tag(opt.code)
            }
        }
        .pickerStyle(.navigationLink)
    }

    private var sheetIconGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
        let tint = Color(hex: selectedColor) ?? .blue
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(SheetSymbols.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(section.symbols, id: \.self) { sym in
                            sheetIconButton(sym, tint: tint)
                        }
                    }
                }
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
                    .fill(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color(.tertiarySystemBackground)))
                    .frame(width: 38, height: 38)
                Image(systemName: sym)
                    .foregroundStyle(isSelected ? .white : Color.primary)
                    .font(.callout.weight(.medium))
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
            .frame(height: 46)
        }
        .buttonStyle(.plain)
    }

    private var paletteRow: some View {
        HStack(spacing: 12) {
            ForEach(palette, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex) ?? .blue)
                    .frame(width: 32, height: 32)
                    .overlay {
                        if hex == selectedColor {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
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

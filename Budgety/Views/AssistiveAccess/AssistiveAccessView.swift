//
//  AssistiveAccessView.swift
//  Expenso
//
//  Assistive Access モード用の単純化された UI。
//  - 大きな「支出を追加」ボタン → カスタムテンキーで金額を入力 → 保存
//  - 直近 3 件の支出を表示
//  - シート切替 / カテゴリ / 共有 / 統計などの複雑機能は意図的に省略
//

import SwiftUI
import CoreData

struct AssistiveAccessView: View {
    @Environment(\.managedObjectContext) private var ctx
    @State private var showAddSheet: Bool = false
    @State private var savedToast: String?

    /// 今日の支出のみ取得 (画面の主役)。
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Expense.date, ascending: false)],
        animation: .default
    )
    private var allExpenses: FetchedResults<Expense>

    private var todayExpenses: [Expense] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        return allExpenses.filter {
            ($0.date ?? .distantPast) >= dayStart
        }
    }

    private var todayTotal: Decimal {
        todayExpenses
            .filter { $0.kind == .expense }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    /// AA で使うシート (= 一番最初に作成されたシート)。無ければ nil。
    private var primarySheet: ExpenseSheet? {
        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        req.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)]
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    addButton
                    recentList
                    Spacer()
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Budgety")
            // WWDC 2025 #238: AA でナビゲーションタイトル横にアイコンを出すと
            // テキストが読み取れないユーザーでも視覚的に画面を識別できる。
            .assistiveAccessNavigationIcon(systemImage: "yensign.circle.fill")
        }
        .sheet(isPresented: $showAddSheet) {
            if let sheet = primarySheet {
                AAAddExpenseView(sheet: sheet) { saved in
                    if saved { flashSavedToast() }
                }
            } else {
                AANoSheetView()
            }
        }
        .overlay(alignment: .top) {
            if let savedToast {
                Text(savedToast)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.green))
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .shadow(radius: 6)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("今日の支出")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(formatYen(todayTotal))
                .font(.system(size: 56, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.top, 4)
        }
    }

    private var addButton: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 56, weight: .bold))
                Text("支出を追加")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.accentColor)
            )
            .shadow(color: Color.accentColor.opacity(0.4), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近の支出")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            if todayExpenses.isEmpty {
                Text("まだ何も記録していません")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(todayExpenses.prefix(3), id: \.objectID) { expense in
                    HStack(spacing: 14) {
                        Image(systemName: expense.category?.symbol ?? "yensign.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(
                                Circle().fill(Color(hex: expense.category?.colorHex ?? "#5B8DEF") ?? .blue)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(expense.displayTitle.isEmpty ? expense.categoryDisplayName : expense.displayTitle)
                                .font(.system(size: 22, weight: .semibold))
                            Text(formatYen(expense.amountDecimal))
                                .font(.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
                }
            }
        }
    }

    private func flashSavedToast() {
        withAnimation { savedToast = "保存しました" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { savedToast = nil }
        }
    }

    private func formatYen(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "JPY"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: amount as NSDecimalNumber) ?? "¥0"
    }
}

// MARK: - Add Expense (AA simplified)

struct AAAddExpenseView: View {
    let sheet: ExpenseSheet
    var onClose: (_ saved: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx
    /// Reduce Motion 時は数値ロールを止める。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var amountText: String = ""

    private var amount: Decimal? {
        guard !amountText.isEmpty else { return nil }
        return Decimal(string: amountText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                Text("いくら使った?")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(amountText.isEmpty ? "¥0" : "¥" + amountText)
                    .font(.system(size: 80, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy, value: amountText)
                Spacer(minLength: 0)
                AAKeypad(amountText: $amountText)
                    .padding(.horizontal)
                Button(action: save) {
                    Text("保存")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .fill(canSave ? Color.green : Color.green.opacity(0.35))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("支出を追加")
            .navigationBarTitleDisplayMode(.inline)
            .assistiveAccessNavigationIcon(systemImage: "plus.circle.fill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onClose(false)
                        dismiss()
                    } label: {
                        Label("閉じる", systemImage: "xmark")
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        guard let a = amount else { return false }
        return a > 0
    }

    private func save() {
        guard let a = amount, a > 0 else { return }
        let expense = Expense(context: ctx)
        expense.amount = NSDecimalNumber(decimal: a)
        expense.currencyCode = sheet.resolvedDefaultCurrencyCode
        expense.kindRaw = TransactionKind.expense.rawValue
        expense.date = Date()
        expense.title = ""
        expense.note = ""
        expense.createdAt = .now
        expense.sheet = sheet
        // 第一カテゴリ (= 食費 など seed の最初) があれば自動採用
        if let cats = sheet.categories as? Set<ExpenseCategory> {
            let sorted = cats.sorted { $0.sortOrder < $1.sortOrder }
            expense.category = sorted.first { $0.kind == .expense }
        }
        if let store = sheet.objectID.persistentStore {
            ctx.assign(expense, to: store)
        }
        do {
            try ctx.save()
            Haptics.success()
            onClose(true)
            dismiss()
        } catch {
            // ベストエフォート: AA では複雑なエラー UI を出さず、そのまま閉じる
            onClose(false)
            dismiss()
        }
    }
}

// MARK: - Big Number Pad

struct AAKeypad: View {
    @Binding var amountText: String

    private let buttons: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["00", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(buttons.indices, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(buttons[row], id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        Button {
            tap(key)
        } label: {
            Text(key)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.secondarySystemBackground))
                )
        }
        .buttonStyle(.plain)
    }

    private func tap(_ key: String) {
        switch key {
        case "⌫":
            if !amountText.isEmpty {
                amountText.removeLast()
            }
        default:
            // 8 桁を上限 (= 99,999,999 まで)
            guard amountText.count + key.count <= 8 else { return }
            // 先頭 0 を防ぐ ("0" → "01" にしない)
            if amountText == "0" { amountText = "" }
            amountText.append(key)
        }
        Haptics.light()
    }
}

private struct AANoSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "tray")
                .font(.system(size: 80, weight: .bold))
                .foregroundStyle(.secondary)
            Text("シートがありません")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("通常モードでシートを作成してから\nもう一度試してください。")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("閉じる") { dismiss() }
                .font(.system(size: 24, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor))
                .foregroundStyle(.white)
                .padding(.horizontal)
        }
        .padding()
    }
}

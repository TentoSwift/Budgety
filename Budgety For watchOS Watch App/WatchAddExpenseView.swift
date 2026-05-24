//
//  WatchAddExpenseView.swift
//  Budgety Watch
//
//  Digital Crown で金額を回し、保存する超シンプル追加画面。
//  - シートのテーマ色 (= sheet.tint) で UI が彩られる
//  - 自動採用される予定のカテゴリをプレビュー表示
//  - 保存時にチェックマークがバウンス + ハプティクス
//

import SwiftUI
import CoreData

struct WatchAddExpenseView: View {
    let sheet: ExpenseSheet

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx

    /// Digital Crown で操作する金額 (= 円)。100 円刻み 0 ... 100,000 (= 10 万円)。
    @State private var amount: Double = 0
    @FocusState private var crownFocused: Bool
    @State private var saved: Bool = false
    @State private var saveBounce: Int = 0
    @State private var showingCategoryPicker: Bool = false
    @State private var manuallySelectedCategory: ExpenseCategory?

    /// シートの全支出カテゴリ (= sortOrder 順)。
    private var availableCategories: [ExpenseCategory] {
        guard let cats = sheet.categories as? Set<ExpenseCategory> else { return [] }
        return cats
            .filter { $0.kind == .expense }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 自動採用されるカテゴリ (= シートの最初の支出カテゴリ)。
    private var autoCategory: ExpenseCategory? {
        availableCategories.first
    }

    /// 実際に保存に使うカテゴリ (= ユーザー選択優先 / 無ければ auto)。
    private var effectiveCategory: ExpenseCategory? {
        manuallySelectedCategory ?? autoCategory
    }

    /// シートの通貨記号 (¥ / $ / € など)。
    private var currencySymbol: String {
        CurrencyCatalog.option(for: sheet.resolvedDefaultCurrencyCode).symbol
    }

    /// シート既定通貨の小数桁数 (0 = JPY/KRW 等 / 2 = USD/EUR 等)。
    private var currencyDecimals: Int {
        CurrencyCatalog.fractionDigits(for: sheet.resolvedDefaultCurrencyCode)
    }
    /// Digital Crown の刻み。小数なし通貨は 100、小数あり通貨は 1。
    private var amountStep: Double { currencyDecimals == 0 ? 100 : 1 }
    /// クイック加算ボタンの刻み (通貨の桁数に合わせる)。
    private var quickSteps: [Int] { currencyDecimals == 0 ? [100, 500, 1000] : [1, 10, 100] }
    /// 金額を通貨フォーマットしたテキスト (¥5,000 / $5.00 など)。
    private var amountText: String {
        CurrencyCatalog.format(Decimal(amount), code: sheet.resolvedDefaultCurrencyCode)
    }

    var body: some View {
        ZStack {
            content
            if saved {
                savedOverlay
                    .transition(.opacity)
            }
        }
        .containerBackground(sheet.tint.gradient, for: .navigation)
        .navigationTitle {
            Text("追加")
                .foregroundStyle(sheet.tint)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                let canSave = amount > 0 && !saved
                Button {
                    save()
                } label: {
                    Image(systemName: "checkmark")
                }
                .tint(canSave ? sheet.tint : .clear)
                .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            WatchCategoryPicker(
                categories: availableCategories,
                selected: effectiveCategory
            ) { picked in
                manuallySelectedCategory = picked
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 6) {
            categoryPreview
            Spacer(minLength: 0)
            Text(amountText)
                .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy, value: amount)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("Digital Crown で調整")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(quickSteps, id: \.self) { step in
                    quickButton(step)
                }
            }
        }
        .padding(.horizontal, 4)
        .focusable(true)
        .focused($crownFocused)
        .digitalCrownRotation(
            $amount,
            from: 0, through: 100_000, by: amountStep,
            sensitivity: .high,
            isContinuous: true,
            isHapticFeedbackEnabled: true
        )
        .onAppear { crownFocused = true }
        .opacity(saved ? 0 : 1)
    }

    @ViewBuilder
    private var categoryPreview: some View {
        if let cat = effectiveCategory {
            Button {
                showingCategoryPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cat.symbol ?? "tag.fill")
                        .font(.caption.weight(.semibold))
                    Text(cat.name ?? "")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.20)))
            }
            .buttonStyle(.plain)
        }
    }

    private func quickButton(_ step: Int) -> some View {
        Button {
            amount = min(100_000, amount + Double(step))
            WKInterfaceDevice.current().play(.click)
        } label: {
            Text("+\(step)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.20))
                )
        }
        .buttonStyle(.plain)
    }

    private var savedOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: saveBounce)
            Text("保存しました")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() {
        guard amount > 0 else { return }
        let dec = Decimal(amount)
        let expense = Expense(context: ctx)
        // ストア割当は Expense 自体の作成直後にやる。Member などほかのエンティティを
        // 触る前に固定しないと cross-store エラーになる。
        if let store = sheet.objectID.persistentStore {
            ctx.assign(expense, to: store)
        }
        expense.amount = NSDecimalNumber(decimal: dec)
        expense.currencyCode = sheet.resolvedDefaultCurrencyCode
        expense.kindRaw = TransactionKind.expense.rawValue
        expense.date = Date()
        expense.title = ""
        expense.note = ""
        expense.createdAt = .now
        expense.sheet = sheet
        expense.category = effectiveCategory
        // 支払者: 自分。watchOS では Member は触らず、payerProfileID と payerMemberID を
        // UserProfileStore キャッシュから直接埋めるだけにする (ensureSelfMemberExists を
        // 呼ぶと別ストアに Member が作られて cross-store クラッシュを起こす可能性あり)。
        // 旧 userRecordName を入れておけば、iOS 側 auto-migration が共有シートの場合に
        // email canonical へ書き換える。
        let profile = UserProfileStore.shared
        let mid = profile.ensureSelfMemberID()
        expense.payerMemberID = mid
        if let pid = profile.userRecordName, !pid.isEmpty {
            expense.payerProfileID = pid
        }
        do {
            try ctx.save()
            WKInterfaceDevice.current().play(.success)
            withAnimation(.snappy) {
                saved = true
                saveBounce += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                dismiss()
            }
        } catch {
            WKInterfaceDevice.current().play(.failure)
        }
    }
}

// MARK: - Category Picker

struct WatchCategoryPicker: View {
    let categories: [ExpenseCategory]
    let selected: ExpenseCategory?
    let onPick: (ExpenseCategory) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories, id: \.objectID) { cat in
                    Button {
                        onPick(cat)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: cat.symbol ?? "tag.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle().fill(Color(hex: cat.colorHex ?? "#5B8DEF") ?? .blue)
                                )
                            Text(cat.name ?? "")
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            if cat.objectID == selected?.objectID {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("カテゴリ")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

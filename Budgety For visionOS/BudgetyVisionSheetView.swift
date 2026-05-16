//
//  BudgetyVisionSheetView.swift
//  Budgety For visionOS
//
//  選択中シートのサマリ。Immersive Space の Open/Close ボタンと
//  カテゴリ別棒グラフ・最近の支出リストを表示する。
//

import SwiftUI
import CoreData

struct BudgetyVisionSheetView: View {
    @ObservedObject var sheet: ExpenseSheet
    @Binding var immersiveSheetID: NSManagedObjectID?

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var isImmersive: Bool = false
    @State private var status: String = ""

    private var expenses: [Expense] {
        ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var monthly: Decimal {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        return expenses.filter {
            guard let d = $0.date, $0.kind == .expense else { return false }
            let c = cal.dateComponents([.year, .month], from: d)
            return c.year == comps.year && c.month == comps.month
        }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                immersiveToggle
                categoriesSection
                recentSection
            }
            .padding(32)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(sheet.displayName)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(sheet.tint.gradient)
                    .frame(width: 120, height: 120)
                    .shadow(color: sheet.tint.opacity(0.4), radius: 20, y: 10)
                Image(systemName: sheet.symbol ?? "person.2.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("今月の支出")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(CurrencyCatalog.format(monthly, code: sheet.resolvedDefaultCurrencyCode))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var immersiveToggle: some View {
        Button {
            Task { await toggleImmersive() }
        } label: {
            HStack {
                Image(systemName: isImmersive ? "xmark.circle.fill" : "sparkles")
                Text(isImmersive ? "没入モードを閉じる" : "没入モードで可視化")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .tint(isImmersive ? .red : .accentColor)
    }

    private var categoriesSection: some View {
        let cats = categoryTotals()
        return VStack(alignment: .leading, spacing: 12) {
            Text("カテゴリ別 (今月)")
                .font(.title3.weight(.semibold))
            if cats.isEmpty {
                Text("今月の支出はまだありません。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(cats, id: \.name) { c in
                    HStack(spacing: 12) {
                        Circle().fill(c.color).frame(width: 14, height: 14)
                        Text(c.name).frame(width: 140, alignment: .leading)
                        GeometryReader { geo in
                            let ratio = NSDecimalNumber(decimal: c.total / max(c.maxTotal, Decimal(1))).doubleValue
                            RoundedRectangle(cornerRadius: 4)
                                .fill(c.color.gradient)
                                .frame(width: CGFloat(ratio) * geo.size.width, height: 12)
                        }
                        .frame(height: 12)
                        Text(CurrencyCatalog.format(c.total, code: sheet.resolvedDefaultCurrencyCode))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .trailing)
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近の支出")
                .font(.title3.weight(.semibold))
            ForEach(expenses.prefix(8), id: \.objectID) { e in
                HStack {
                    Image(systemName: e.categorySymbol)
                        .foregroundStyle(e.categoryTint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.displayTitle).font(.body)
                        Text(formatDate(e.date ?? .now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(e.formattedSignedAmount)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(e.kind == .income ? .green : .primary)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Helpers

    private struct CategoryTotal {
        let name: String
        let total: Decimal
        let color: Color
        let maxTotal: Decimal
    }

    private func categoryTotals() -> [CategoryTotal] {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let monthExp = expenses.filter {
            guard let d = $0.date, $0.kind == .expense else { return false }
            let c = cal.dateComponents([.year, .month], from: d)
            return c.year == comps.year && c.month == comps.month
        }
        let grouped = Dictionary(grouping: monthExp) { $0.categoryDisplayName }
        let totals = grouped.map { (name, items) -> (String, Decimal, Color) in
            let sum = items.reduce(Decimal(0)) { $0 + $1.amountDecimal }
            let color = items.first?.categoryTint ?? .gray
            return (name, sum, color)
        }
        let maxV = totals.map(\.1).max() ?? Decimal(1)
        return totals
            .map { CategoryTotal(name: $0.0, total: $0.1, color: $0.2, maxTotal: maxV) }
            .sorted { $0.total > $1.total }
    }

    private func formatDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d (E)"
        return df.string(from: d)
    }

    @MainActor
    private func toggleImmersive() async {
        if isImmersive {
            await dismissImmersiveSpace()
            isImmersive = false
            immersiveSheetID = nil
        } else {
            immersiveSheetID = sheet.objectID
            let result = await openImmersiveSpace(id: "budgety-immersive")
            if case .opened = result {
                isImmersive = true
            }
        }
    }
}

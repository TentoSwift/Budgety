//
//  PDFReportView.swift
//  Budgety
//
//  PDF 出力用の SwiftUI ビュー。SheetDetailView の見た目に寄せた
//  サマリーカード + 日付セクション付き支出リストをレンダリングする。
//  ImageRenderer で PDF に変換して出力する (SheetExporter.writePDF 参照)。
//

import SwiftUI
import CoreData

#if !os(watchOS)

/// A4 幅 (595 pt) を前提に組まれた、PDF 出力専用のレポートビュー。
/// 動的色 (`.primary` 等) は PDF 文脈で解決されないため、すべて具体色を使う。
struct PDFReportView: View {
    let sheet: ExpenseSheet
    /// レンダリング時の固定幅。ImageRenderer.proposedSize と一致させる。
    var pageWidth: CGFloat = 595.2

    private struct DaySection: Identifiable {
        let id: Date
        let label: String
        let expenses: [Expense]
        let dayNet: Decimal
    }

    private var code: String { sheet.resolvedDefaultCurrencyCode }

    private var allExpenses: [Expense] {
        ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var totalExpense: Decimal {
        allExpenses.filter { $0.kind == .expense }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }
    private var totalIncome: Decimal {
        allExpenses.filter { $0.kind == .income }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: allExpenses) { e -> Date in
            cal.startOfDay(for: e.date ?? .now)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy/MM/dd (EEE)"
        return groups.keys.sorted(by: >).map { day in
            let items = groups[day] ?? []
            let net = items.reduce(Decimal(0)) { acc, e in
                acc + (e.kind == .income ? e.amountDecimal : -e.amountDecimal)
            }
            return DaySection(id: day, label: df.string(from: day), expenses: items, dayNet: net)
        }
    }

    private var tint: Color { sheet.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerCard
            if sections.isEmpty {
                Text("まだ支出 / 収入が記録されていません")
                    .font(.callout)
                    .foregroundStyle(Color.gray)
                    .padding(.horizontal, 24)
            } else {
                ForEach(sections) { section in
                    daySection(section)
                }
            }
            footer
        }
        .padding(.vertical, 24)
        .frame(width: pageWidth, alignment: .leading)
        .background(Color.white)
    }

    // MARK: - Header (summary card)

    @ViewBuilder
    private var headerCard: some View {
        let net = totalIncome - totalExpense
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.gradient)
                    Image(systemName: sheet.symbol ?? "person.2.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 20, weight: .semibold))
                }
                .frame(width: 40, height: 40)
                Text(sheet.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                Spacer()
            }

            Text("全期間")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.gray)

            Text(CurrencyCatalog.format(totalExpense, code: code))
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.black)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            HStack(spacing: 14) {
                amountChip(label: "収入", value: totalIncome, color: .green)
                amountChip(label: "支出", value: totalExpense, color: .red)
                amountChip(label: "収支", value: net, color: net < 0 ? .red : .green)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func amountChip(label: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.gray)
            Text(CurrencyCatalog.format(value, code: code))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: - Day sections

    @ViewBuilder
    private func daySection(_ section: DaySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.black)
                Spacer()
                Text(CurrencyCatalog.format(section.dayNet, code: code))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(section.dayNet < 0 ? Color.red : Color.green)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.expenses.enumerated()), id: \.element.objectID) { idx, e in
                    expenseRow(e)
                    if idx < section.expenses.count - 1 {
                        Divider().background(Color(white: 0.85))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.97))
            )
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func expenseRow(_ e: Expense) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(e.categoryTint.gradient)
                Image(systemName: e.categorySymbol)
                    .foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.categoryDisplayName)
                    .font(.callout)
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                let titleText = e.displayTitle
                let payerText = e.displayPaidBy
                let subtitleParts = [titleText, payerText].filter { !$0.isEmpty }
                if !subtitleParts.isEmpty {
                    Text(subtitleParts.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Color.gray)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(e.formattedSignedAmount)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(e.kind == .income ? Color.green : Color.black)
                    .lineLimit(1)
                if e.resolvedCurrencyCode != code {
                    Text(e.resolvedCurrencyCode)
                        .font(.caption2)
                        .foregroundStyle(Color.gray)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        let df = DateFormatter()
        let _ = {
            df.locale = Locale(identifier: "ja_JP")
            df.dateFormat = "yyyy/MM/dd HH:mm"
        }()
        HStack {
            Spacer()
            Text("Budgety レポート · \(df.string(from: .now)) 出力")
                .font(.caption2)
                .foregroundStyle(Color.gray)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 24)
    }
}

#endif

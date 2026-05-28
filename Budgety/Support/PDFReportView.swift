//
//  PDFReportView.swift
//  Budgety
//
//  PDF 出力用の SwiftUI ビュー。SheetDetailView の見た目に寄せた
//  サマリーカード + 日付セクション付き支出リストをレンダリングする。
//  ImageRenderer で PDF に変換して出力する (SheetExporter.writePDF 参照)。
//
//  ブロック (= ヘッダーカード + 各日セクション) ごとに別々の SwiftUI
//  ビューに切り出してあり、SheetExporter 側で 1 ブロックずつ ImageRenderer
//  にかけて A4 ページに積んで行く設計。これにより支出行が途中で見切れる
//  ことが無くなる (= 1 ブロック単位でしか改ページしない)。
//

import SwiftUI
import CoreData

#if !os(watchOS)

/// 1 日分のグルーピング。Header + 各 DaySection を別々にレンダリングするための
/// 中間モデル。SheetExporter から参照されるので enum ではなく struct で。
struct PDFReportDaySection: Identifiable {
    let id: Date
    let label: String
    let expenses: [Expense]
    let dayNet: Decimal
}

enum PDFReport {
    /// A4 幅 (72dpi 換算)。
    static let pageWidth: CGFloat = 595.2
    /// A4 高 (72dpi 換算)。
    static let pageHeight: CGFloat = 841.8

    /// 各ブロックの左右 padding (= レポート全体の左右の余白)。
    static let horizontalPadding: CGFloat = 24

    /// シート配下の支出を日付セクション化して返す (新しい順)。
    @MainActor
    static func daySections(for sheet: ExpenseSheet) -> [PDFReportDaySection] {
        let cal = Calendar.current
        let all = ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let groups = Dictionary(grouping: all) { e -> Date in
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
            return PDFReportDaySection(id: day, label: df.string(from: day), expenses: items, dayNet: net)
        }
    }
}

// MARK: - Header card (= SheetDetailView の SummaryCardView 相当)

/// SheetDetailView のサマリーカードと同じレイアウトを PDF 用に再現。
/// 緑/赤の色分けは使わず、すべて secondary グレー + 黒で表現する。
struct PDFHeaderCardView: View {
    let sheet: ExpenseSheet

    private var code: String { sheet.resolvedDefaultCurrencyCode }

    private var allExpenses: [Expense] {
        ((sheet.expenses as? Set<Expense>) ?? []).filter { _ in true }
    }
    private var totalExpense: Decimal {
        allExpenses.filter { $0.kind == .expense }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }
    private var totalIncome: Decimal {
        allExpenses.filter { $0.kind == .income }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 上段: シートアイコン + 名前
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(sheet.tint.gradient)
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

            // 大型の支出合計 (Mac と同じ rounded font)
            Text(CurrencyCatalog.format(totalExpense, code: code))
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.black)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            // 支出合計の直下に「+収入 | -支出」のサマリ行 (左寄せ、グレー)
            HStack(spacing: 12) {
                Text("+ \(CurrencyCatalog.format(totalIncome, code: code))")
                Text("|").foregroundStyle(Color(white: 0.75))
                Text("- \(CurrencyCatalog.format(totalExpense, code: code))")
            }
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(Color.gray)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(sheet.tint.opacity(0.12))
        )
        .padding(.horizontal, PDFReport.horizontalPadding)
        .background(Color.white)
    }
}

// MARK: - Day section

struct PDFDaySectionView: View {
    let sheet: ExpenseSheet
    let section: PDFReportDaySection

    private var code: String { sheet.resolvedDefaultCurrencyCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.black)
                Spacer()
                Text(CurrencyCatalog.format(section.dayNet, code: code))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.gray)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.expenses.enumerated()), id: \.element.objectID) { idx, e in
                    expenseRow(e)
                    if idx < section.expenses.count - 1 {
                        Divider().background(Color(white: 0.88))
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
        .padding(.horizontal, PDFReport.horizontalPadding)
        .padding(.top, 12)
        .background(Color.white)
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
                    .foregroundStyle(Color.black)
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
}

// MARK: - Footer

struct PDFFooterView: View {
    var body: some View {
        let df = DateFormatter()
        let _: Void = {
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
        .padding(.top, 12)
        .padding(.bottom, 8)
        .padding(.horizontal, PDFReport.horizontalPadding)
        .background(Color.white)
    }
}

// MARK: - Single-view preview / fallback

/// Header + 全 day section + footer を縦に並べた 1 つの View。
/// プレビューや単一画像化したい時用 (出力本体はブロックごとレンダリング)。
struct PDFReportView: View {
    let sheet: ExpenseSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PDFHeaderCardView(sheet: sheet)
                .padding(.top, 24)
            ForEach(PDFReport.daySections(for: sheet)) { section in
                PDFDaySectionView(sheet: sheet, section: section)
            }
            PDFFooterView()
        }
        .frame(width: PDFReport.pageWidth, alignment: .leading)
        .background(Color.white)
    }
}

#endif

//
//  SheetExporter.swift
//  Expenso
//
//  シート 1 つ分の Expense をエクスポートするサービス。
//  CSV (RFC 4180 風) と PDF (PDFKit) を提供。
//  どちらも Premium 機能なので、UI 側で `PurchaseManager.isPremium` を
//  ゲートしてから呼ぶ。
//

import Foundation
import CoreData
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum SheetExporter {
    // MARK: - CSV

    /// シート配下の Expense を 1 行 1 件で CSV 化する。
    /// 列: date, kind, title, category, payer, amount, currency, note
    /// 改行・カンマ・ダブルクォートを含む値はクォートし、内部の `"` を `""` にエスケープ。
    static func makeCSV(for sheet: ExpenseSheet) -> Data {
        let header = ["date", "kind", "title", "category", "payer", "amount", "currency", "note"]
        var rows: [[String]] = [header]

        let expenses = ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"

        for e in expenses {
            rows.append([
                df.string(from: e.date ?? .now),
                e.kind == .income ? "income" : "expense",
                e.displayTitle,
                e.categoryDisplayName,
                e.displayPaidBy,
                NSDecimalNumber(decimal: e.amountDecimal).stringValue,
                e.resolvedCurrencyCode,
                e.note ?? ""
            ])
        }

        let csv = rows.map { line in
            line.map(escape).joined(separator: ",")
        }.joined(separator: "\r\n")
        // BOM を付けると Excel で UTF-8 が正しく開ける。
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(csv.data(using: .utf8) ?? Data())
        return data
    }

    private static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// 一時ディレクトリに CSV を書いて URL を返す。共有シート用。
    static func writeCSV(for sheet: ExpenseSheet) -> URL? {
        let data = makeCSV(for: sheet)
        let dir = FileManager.default.temporaryDirectory
        let safe = sheet.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined()
        let url = dir.appendingPathComponent("Expenso-\(safe).csv")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            #if DEBUG
            print("⚠️ writeCSV: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - PDF (iOS only)

    #if canImport(UIKit)
    /// シートの月別サマリレポート PDF を生成。
    /// - 1 ページ目: 表紙 (シート名 / 期間 / 総合計)
    /// - 以降: 月ごとに 支出/収入 合計 + カテゴリ別内訳
    static func writePDF(for sheet: ExpenseSheet) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let safe = sheet.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined()
        let url = dir.appendingPathComponent("Expenso-\(safe).pdf")

        // A4 (72dpi 換算)
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: UIGraphicsPDFRendererFormat())

        do {
            try renderer.writePDF(to: url) { ctx in
                drawPDF(into: ctx, sheet: sheet, pageRect: pageRect)
            }
            return url
        } catch {
            #if DEBUG
            print("⚠️ writePDF: \(error)")
            #endif
            return nil
        }
    }

    private static func drawPDF(
        into ctx: UIGraphicsPDFRendererContext,
        sheet: ExpenseSheet,
        pageRect: CGRect
    ) {
        let margin: CGFloat = 36
        let contentWidth = pageRect.width - margin * 2
        let code = sheet.resolvedDefaultCurrencyCode

        let titleFont = UIFont.systemFont(ofSize: 28, weight: .bold)
        let h2Font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 12, weight: .regular)
        let subFont = UIFont.systemFont(ofSize: 11, weight: .regular)

        // PDF コンテキストには UITraitCollection が無く UIColor.label など動的色は
        // 解決されない (= 透明として扱われテキストが見えない)。具体色を使う。
        let primaryColor = UIColor.black
        let secondaryColor = UIColor.darkGray
        let separatorColor = UIColor.lightGray

        func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            NSAttributedString(string: text, attributes: attrs).draw(at: point)
        }

        let expenses = ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy/MM/dd"

        // ===== Page 1: 表紙 =====
        ctx.beginPage()
        var y: CGFloat = margin

        draw(sheet.displayName, at: CGPoint(x: margin, y: y),
             font: titleFont, color: primaryColor)
        y += titleFont.lineHeight + 8

        draw("Budgety レポート (\(df.string(from: .now)) 出力)",
             at: CGPoint(x: margin, y: y), font: subFont, color: secondaryColor)
        y += subFont.lineHeight + 24

        let totalExpense = expenses.filter { $0.kind == .expense }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let totalIncome = expenses.filter { $0.kind == .income }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let net = totalIncome - totalExpense

        for (label, value) in [
            ("支出合計", totalExpense),
            ("収入合計", totalIncome),
            ("差引",   net)
        ] {
            let line = "\(label):  \(CurrencyCatalog.format(value, code: code))"
            draw(line, at: CGPoint(x: margin, y: y),
                 font: bodyFont, color: primaryColor)
            y += bodyFont.lineHeight + 6
        }

        if expenses.isEmpty {
            y += 12
            draw("(まだ支出 / 収入が記録されていません)",
                 at: CGPoint(x: margin, y: y),
                 font: subFont, color: secondaryColor)
        }

        // ===== Page 2+: 月別 =====
        let cal = Calendar.current
        let byMonth = Dictionary(grouping: expenses) { e -> DateComponents in
            let d = e.date ?? .now
            return cal.dateComponents([.year, .month], from: d)
        }
        let sortedKeys = byMonth.keys.sorted { (a, b) in
            (a.year ?? 0, a.month ?? 0) > (b.year ?? 0, b.month ?? 0)
        }

        let monthHeader = DateFormatter()
        monthHeader.locale = Locale(identifier: "ja_JP")
        monthHeader.dateFormat = "yyyy 年 M 月"

        for comps in sortedKeys {
            ctx.beginPage()
            var py: CGFloat = margin

            let monthDate = cal.date(from: comps) ?? .now
            draw(monthHeader.string(from: monthDate),
                 at: CGPoint(x: margin, y: py),
                 font: h2Font, color: primaryColor)
            py += h2Font.lineHeight + 12

            let items = byMonth[comps] ?? []
            let mExp = items.filter { $0.kind == .expense }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
            let mInc = items.filter { $0.kind == .income }.reduce(Decimal(0)) { $0 + $1.amountDecimal }

            draw("支出 \(CurrencyCatalog.format(mExp, code: code))    収入 \(CurrencyCatalog.format(mInc, code: code))",
                 at: CGPoint(x: margin, y: py),
                 font: bodyFont, color: secondaryColor)
            py += bodyFont.lineHeight + 16

            let byCategory = Dictionary(grouping: items.filter { $0.kind == .expense }) { $0.categoryDisplayName }
            let rows = byCategory.map { (name, items) -> (String, Decimal, Int) in
                let sum = items.reduce(Decimal(0)) { $0 + $1.amountDecimal }
                return (name, sum, items.count)
            }.sorted { $0.1 > $1.1 }

            draw("カテゴリ別 (支出):",
                 at: CGPoint(x: margin, y: py),
                 font: bodyFont, color: primaryColor)
            py += bodyFont.lineHeight + 4

            for (name, total, count) in rows {
                guard py < pageRect.height - margin - bodyFont.lineHeight else { break }
                draw("  \(name):  \(CurrencyCatalog.format(total, code: code))  (\(count) 件)",
                     at: CGPoint(x: margin, y: py),
                     font: subFont, color: primaryColor)
                py += subFont.lineHeight + 2
            }

            separatorColor.setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: margin, y: py + 8))
            path.addLine(to: CGPoint(x: margin + contentWidth, y: py + 8))
            path.lineWidth = 0.5
            path.stroke()
        }
    }
    #endif

    // MARK: - PDF (macOS / AppKit)

    #if os(macOS)
    /// シートの月別サマリレポート PDF を生成 (iOS 版と同じ構成の AppKit 実装)。
    /// - 1 ページ目: 表紙 (シート名 / 期間 / 総合計)
    /// - 以降: 月ごとに 支出/収入 合計 + カテゴリ別内訳
    static func writePDF(for sheet: ExpenseSheet) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let safe = sheet.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined()
        let url = dir.appendingPathComponent("Budgety-\(safe).pdf")

        // A4 (72dpi 換算)
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let cg = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }
        drawPDFmacOS(into: cg, sheet: sheet, pageRect: pageRect)
        cg.closePDF()
        return url
    }

    private static func drawPDFmacOS(into cg: CGContext, sheet: ExpenseSheet, pageRect: CGRect) {
        let margin: CGFloat = 36
        let contentWidth = pageRect.width - margin * 2
        let code = sheet.resolvedDefaultCurrencyCode

        let titleFont = NSFont.systemFont(ofSize: 28, weight: .bold)
        let h2Font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let subFont = NSFont.systemFont(ofSize: 11, weight: .regular)

        // PDF コンテキストでは動的色が解決されないので具体色を使う。
        let primaryColor = NSColor.black
        let secondaryColor = NSColor.darkGray
        let separatorColor = NSColor.lightGray

        func lineHeight(_ f: NSFont) -> CGFloat { f.ascender - f.descender + f.leading }

        // 原点を左上・Y 下向きにして iOS のレイアウト計算をそのまま使う。
        // CTM を反転 (translate + scale) し、かつ NSGraphicsContext を flipped:true に
        // することで、テキストが正立 + 左上原点になる (片方だけだと上下反転する)。
        func beginPage() {
            cg.beginPDFPage(nil)
            cg.saveGState()
            cg.translateBy(x: 0, y: pageRect.height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        }
        func endPage() {
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
            cg.endPDFPage()
        }
        func draw(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            NSAttributedString(string: text, attributes: attrs).draw(at: point)
        }

        let expenses = ((sheet.expenses as? Set<Expense>) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy/MM/dd"

        // ===== Page 1: 表紙 =====
        beginPage()
        var y: CGFloat = margin

        draw(sheet.displayName, at: CGPoint(x: margin, y: y), font: titleFont, color: primaryColor)
        y += lineHeight(titleFont) + 8

        draw("Budgety レポート (\(df.string(from: .now)) 出力)",
             at: CGPoint(x: margin, y: y), font: subFont, color: secondaryColor)
        y += lineHeight(subFont) + 24

        let totalExpense = expenses.filter { $0.kind == .expense }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let totalIncome = expenses.filter { $0.kind == .income }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
        let net = totalIncome - totalExpense

        for (label, value) in [("支出合計", totalExpense), ("収入合計", totalIncome), ("差引", net)] {
            draw("\(label):  \(CurrencyCatalog.format(value, code: code))",
                 at: CGPoint(x: margin, y: y), font: bodyFont, color: primaryColor)
            y += lineHeight(bodyFont) + 6
        }

        if expenses.isEmpty {
            y += 12
            draw("(まだ支出 / 収入が記録されていません)",
                 at: CGPoint(x: margin, y: y), font: subFont, color: secondaryColor)
        }
        endPage()

        // ===== Page 2+: 月別 =====
        let cal = Calendar.current
        let byMonth = Dictionary(grouping: expenses) { e -> DateComponents in
            cal.dateComponents([.year, .month], from: e.date ?? .now)
        }
        let sortedKeys = byMonth.keys.sorted { (a, b) in
            (a.year ?? 0, a.month ?? 0) > (b.year ?? 0, b.month ?? 0)
        }
        let monthHeader = DateFormatter()
        monthHeader.locale = Locale(identifier: "ja_JP")
        monthHeader.dateFormat = "yyyy 年 M 月"

        for comps in sortedKeys {
            beginPage()
            var py: CGFloat = margin

            let monthDate = cal.date(from: comps) ?? .now
            draw(monthHeader.string(from: monthDate), at: CGPoint(x: margin, y: py), font: h2Font, color: primaryColor)
            py += lineHeight(h2Font) + 12

            let items = byMonth[comps] ?? []
            let mExp = items.filter { $0.kind == .expense }.reduce(Decimal(0)) { $0 + $1.amountDecimal }
            let mInc = items.filter { $0.kind == .income }.reduce(Decimal(0)) { $0 + $1.amountDecimal }

            draw("支出 \(CurrencyCatalog.format(mExp, code: code))    収入 \(CurrencyCatalog.format(mInc, code: code))",
                 at: CGPoint(x: margin, y: py), font: bodyFont, color: secondaryColor)
            py += lineHeight(bodyFont) + 16

            let byCategory = Dictionary(grouping: items.filter { $0.kind == .expense }) { $0.categoryDisplayName }
            let rows = byCategory.map { (name, items) -> (String, Decimal, Int) in
                (name, items.reduce(Decimal(0)) { $0 + $1.amountDecimal }, items.count)
            }.sorted { $0.1 > $1.1 }

            draw("カテゴリ別 (支出):", at: CGPoint(x: margin, y: py), font: bodyFont, color: primaryColor)
            py += lineHeight(bodyFont) + 4

            for (name, total, count) in rows {
                guard py < pageRect.height - margin - lineHeight(bodyFont) else { break }
                draw("  \(name):  \(CurrencyCatalog.format(total, code: code))  (\(count) 件)",
                     at: CGPoint(x: margin, y: py), font: subFont, color: primaryColor)
                py += lineHeight(subFont) + 2
            }

            separatorColor.setStroke()
            let path = NSBezierPath()
            path.move(to: CGPoint(x: margin, y: py + 8))
            path.line(to: CGPoint(x: margin + contentWidth, y: py + 8))
            path.lineWidth = 0.5
            path.stroke()
            endPage()
        }
    }
    #endif
}

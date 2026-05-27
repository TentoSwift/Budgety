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
import SwiftUI
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

    // MARK: - PDF (SwiftUI ImageRenderer ベース, iOS / macOS 共通)

    /// 1 ブロック (= ヘッダーカード or 日セクション or フッター) を ImageRenderer で
    /// 画像化した結果。`heightPt` は PDF ポイント単位での高さ。
    private struct RenderedBlock {
        let image: CGImage
        let widthPt: CGFloat
        let heightPt: CGFloat
    }

    /// 1 View を ImageRenderer で CGImage 化する。scale=2 で高解像度に。
    /// 返値の寸法は PDF ポイント単位 (= pixel / scale)。
    @MainActor
    private static func renderBlock<V: View>(_ view: V, pageWidth: CGFloat) -> RenderedBlock? {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)
        renderer.scale = 2
        #if canImport(AppKit)
        guard let nsImg = renderer.nsImage,
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        #elseif canImport(UIKit)
        guard let uiImg = renderer.uiImage, let cg = uiImg.cgImage else { return nil }
        #else
        return nil
        #endif
        return RenderedBlock(
            image: cg,
            widthPt: CGFloat(cg.width) / renderer.scale,
            heightPt: CGFloat(cg.height) / renderer.scale
        )
    }

    /// シートのレポート PDF を生成。
    /// ヘッダーカードと各日セクションを **ブロック単位** で ImageRenderer に通して
    /// A4 ページに積み上げる。1 ブロックが切れて見切れることが無いように
    /// 「ブロックがページ末尾に収まらなければ次ページの先頭から始める」方式で
    /// 改ページする (= 単一ブロックがページより長い場合のみ強制スプリット)。
    @MainActor
    static func writePDF(for sheet: ExpenseSheet) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let safe = sheet.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined()
        let url = dir.appendingPathComponent("Budgety-\(safe).pdf")

        let pageWidth = PDFReport.pageWidth
        let pageHeight = PDFReport.pageHeight

        // 1) 描画するブロックを順に並べる
        var blocks: [RenderedBlock] = []
        if let header = renderBlock(
            PDFHeaderCardView(sheet: sheet).padding(.top, 24),
            pageWidth: pageWidth
        ) {
            blocks.append(header)
        }
        for section in PDFReport.daySections(for: sheet) {
            if let block = renderBlock(
                PDFDaySectionView(sheet: sheet, section: section),
                pageWidth: pageWidth
            ) {
                blocks.append(block)
            }
        }
        if let footer = renderBlock(PDFFooterView(), pageWidth: pageWidth) {
            blocks.append(footer)
        }
        guard !blocks.isEmpty else { return nil }

        // 2) ページ組み: ブロックを順に積んで、収まらなければ次ページに送る
        struct Placement { let block: RenderedBlock; let topY: CGFloat }
        var pages: [[Placement]] = [[]]
        var currentY: CGFloat = 0
        for block in blocks {
            let fits = currentY + block.heightPt <= pageHeight
            if !fits, !pages[pages.count - 1].isEmpty {
                pages.append([])
                currentY = 0
            }
            pages[pages.count - 1].append(Placement(block: block, topY: currentY))
            currentY += block.heightPt
            // 単一ブロックが pageHeight 超の場合: そのページの後ろに何も置かないため
            // 次の loop iteration で fits=false → 新ページ送り、で OK。
        }

        // 3) PDF 出力
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }
        for page in pages {
            pdf.beginPDFPage(nil)
            for placement in page {
                let b = placement.block
                // PDF は左下原点 + Y 上向き。topY (ページ上端からの距離) を
                // CGRect.origin に変換するには pageHeight - topY - heightPt。
                let originY = pageHeight - placement.topY - b.heightPt
                pdf.draw(b.image, in: CGRect(x: 0, y: originY, width: b.widthPt, height: b.heightPt))
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }
}

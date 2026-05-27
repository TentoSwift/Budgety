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

    /// シートのレポート PDF を生成。
    /// `PDFReportView` (SwiftUI) を ImageRenderer で A4 ページに分割描画する。
    /// SheetDetailView と同じ見た目のサマリーカード + 日付セクション付き支出一覧。
    @MainActor
    static func writePDF(for sheet: ExpenseSheet) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let safe = sheet.displayName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined()
        let url = dir.appendingPathComponent("Budgety-\(safe).pdf")

        // A4 (72dpi 換算)
        let pageWidth: CGFloat = 595.2
        let pageHeight: CGFloat = 841.8

        let report = PDFReportView(sheet: sheet, pageWidth: pageWidth)
        let renderer = ImageRenderer(content: report)
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)

        // まず view を画像に焼く (= 全高を確定)。長くなりすぎないように
        // rasterizationScale=2 で描画して見栄えを良くする (テキストが鮮明)。
        renderer.scale = 2

        #if canImport(AppKit)
        guard let nsImg = renderer.nsImage,
              let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        #elseif canImport(UIKit)
        guard let uiImg = renderer.uiImage, let cgImg = uiImg.cgImage else {
            return nil
        }
        #else
        return nil
        #endif

        // 画像のピクセルサイズ → PDF ポイントへの換算。
        // renderer.scale = 2 なので画像ピクセル = ポイント × 2。
        let imgW = CGFloat(cgImg.width) / renderer.scale
        let imgH = CGFloat(cgImg.height) / renderer.scale

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        // ページごとに「画像のどの部分を表示するか」を計算しながら描画。
        // PDF は左下原点 + Y 上向き、ImageRenderer の出力は左上原点なので、
        // image 全体を「drawY を下げて」描画し、各ページが該当する垂直スライス
        // (= y..y+pageHeight) を見せる。
        // image 高さ imgH を 1 枚の長い縦長画像と考え、ページ 0 はその上端、
        // ページ k は y=k*pageHeight..y=(k+1)*pageHeight 部分を表示する。
        var y: CGFloat = 0
        while y < imgH {
            pdf.beginPDFPage(nil)
            // 画像の origin は (0, drawY)。image top = drawY + imgH。
            // 画像の y(image-top 基準) 位置が PDF y(=pageHeight) に来るには:
            //   drawY + imgH - y = pageHeight  →  drawY = pageHeight - imgH + y
            let drawY = pageHeight - imgH + y
            pdf.draw(cgImg, in: CGRect(x: 0, y: drawY, width: imgW, height: imgH))
            pdf.endPDFPage()
            y += pageHeight
        }
        pdf.closePDF()
        return url
    }
}

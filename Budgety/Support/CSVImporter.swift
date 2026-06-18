//
//  CSVImporter.swift
//  Budgety
//
//  CSV → Expense へのインポータ。
//  - 自エクスポートと同じヘッダ (date, kind, title, category, payer, amount, currency, note)
//    を第一級でサポート。
//  - 列が無い / 順番が違う場合はヘッダ名でマッピング (case-insensitive)。
//  - 数値や日付パースは寛容にする (1,000 → 1000, ¥/$ 等の通貨記号除去、複数日付フォーマット)。
//  - 同じ Expense の重複防止はしない (= 同じ行を 2 度走らせると 2 件入る)。
//

import Foundation
import CoreData

enum CSVImporter {

    struct Row {
        let date: Date
        let title: String
        let amount: Decimal
        let kind: TransactionKind
        let currencyCode: String?
        let categoryName: String?
        let payerName: String?
        let note: String?
    }

    struct PreviewResult {
        /// 解析できた行 (= 取り込み候補)
        let rows: [Row]
        /// 解析失敗した行番号 (1 始まり、ヘッダ行は除く) と理由
        let skipped: [(line: Int, reason: String)]
        /// 元 CSV のヘッダ
        let header: [String]
    }

    // MARK: - Parse

    /// Data から CSV を解析する。エンコーディングは UTF-8 (BOM 付き含む) → SJIS の順で試す。
    static func parse(data: Data, defaultCurrency: String, defaultDate: Date = .now) -> PreviewResult? {
        guard let text = decodeText(data: data) else { return nil }
        return parse(text: text, defaultCurrency: defaultCurrency, defaultDate: defaultDate)
    }

    /// String から CSV を解析する。
    static func parse(text: String, defaultCurrency: String, defaultDate: Date = .now) -> PreviewResult {
        let lines = splitCSVLines(text)
        guard !lines.isEmpty else {
            return PreviewResult(rows: [], skipped: [], header: [])
        }
        let header = splitCSVRow(lines[0]).map { normalizeHeader($0) }
        let indices = ColumnIndices(header: header)
        // 金額列が 1 つも見つからない場合、全行が「解析不能」になるだけだと原因が
        // 分かりにくいので、ヘッダレベルの問題として明示的に 1 件だけ報告する。
        guard indices.hasAmount else {
            return PreviewResult(
                rows: [],
                skipped: [(1, String(localized: "金額列が見つかりません。ヘッダに「amount / 金額 / 利用金額 / 出金額・入金額」などの列名が必要です"))],
                header: header
            )
        }

        var rows: [Row] = []
        var skipped: [(Int, String)] = []
        for i in 1..<lines.count {
            let raw = lines[i]
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let cols = splitCSVRow(raw)
            switch makeRow(cols: cols, indices: indices, defaultCurrency: defaultCurrency, defaultDate: defaultDate) {
            case .success(let row):
                rows.append(row)
            case .failure(let reason):
                skipped.append((i, reason))
            }
        }
        return PreviewResult(rows: rows, skipped: skipped, header: header)
    }

    // MARK: - Import

    /// 解析済み rows を `sheet` に Expense として書き込む。
    /// カテゴリは name 一致でシート内 ExpenseCategory に紐付け、無ければ categoryRaw のみ。
    /// 戻り値は実際に作成した件数。
    @MainActor
    @discardableResult
    static func importRows(_ rows: [Row], into sheet: ExpenseSheet, ctx: NSManagedObjectContext) -> Int {
        guard let sheetStore = sheet.objectID.persistentStore else { return 0 }
        let categories = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let profile = UserProfileStore.shared
        #if !os(watchOS)
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        let selfPID = profile.canonicalSelfID(forShare: share)
        #else
        let selfPID = profile.userRecordName
        #endif

        var created = 0
        for r in rows {
            let e = Expense(context: ctx)
            ctx.assign(e, to: sheetStore)
            e.title = r.title
            e.amount = NSDecimalNumber(decimal: r.amount)
            e.kindRaw = r.kind.rawValue
            e.currencyCode = r.currencyCode ?? sheet.resolvedDefaultCurrencyCode
            e.date = r.date
            e.note = r.note
            e.createdAt = .now
            e.sheet = sheet
            // カテゴリ: name 一致でシート内のカテゴリを参照、無ければ categoryRaw のみ
            if let name = r.categoryName, !name.isEmpty {
                e.categoryRaw = name
                if let cat = categories.first(where: { $0.name == name }),
                   cat.objectID.persistentStore == sheetStore {
                    e.category = cat
                }
            }
            // 支払者: payer 列が自分の表示名と一致 (or 未指定) なら自分の canonical を立てる。
            // 他人の名前は payerProfileID 解決ができないので、paidBy のみ立てて legacy 扱い
            // → ピッカーで「過去の支払者」として現れて手動マージできる。
            let myDisplay = profile.resolvedDisplayName
            if let payer = r.payerName, !payer.isEmpty {
                if payer == myDisplay || payer == "自分" {
                    if let pid = selfPID { e.payerProfileID = pid }
                    if let mid = profile.selfMemberID { e.payerMemberID = mid }
                } else {
                    // 他人 → 表示用キャッシュだけ残す
                    e.paidBy = payer
                }
            } else {
                // payer 未指定 → 自分扱い
                if let pid = selfPID { e.payerProfileID = pid }
                if let mid = profile.selfMemberID { e.payerMemberID = mid }
            }
            // FX スナップショット (取り込み時の current FX で凍結)
            e.captureFXSnapshot()
            created += 1
        }
        if created > 0 {
            do { try ctx.save() } catch {
                #if DEBUG
                print("⚠️ CSVImporter save: \(error)")
                #endif
            }
        }
        return created
    }

    // MARK: - Internals

    /// 1) UTF-8 BOM 付き → 2) UTF-8 → 3) Shift_JIS の順で試す。
    private static func decodeText(data: Data) -> String? {
        var d = data
        // strip BOM
        if d.count >= 3, d[0] == 0xEF, d[1] == 0xBB, d[2] == 0xBF {
            d.removeSubrange(0..<3)
        }
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: .shiftJIS) { return s }
        return String(data: d, encoding: .isoLatin1)
    }

    /// RFC 4180 風: ダブルクォート内の改行を 1 セルとして扱う。
    private static func splitCSVLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "\r":
                if inQuotes { current.append(ch) }
            case "\n":
                if inQuotes { current.append(ch) }
                else { lines.append(current); current = "" }
            default:
                current.append(ch)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// 1 行を `,` 区切りでフィールドに分割。クォート (`"`) でエスケープ。
    /// 内部の `""` は `"` 1 文字に戻す。
    private static func splitCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\"")
                        i = line.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// ヘッダ名の正規化: 前後空白 (全角含む)・全角英数の半角化・小文字化・
    /// 「(円)」等の単位サフィックス除去。銀行/カード明細の表記ゆれを吸収する。
    private static func normalizeHeader(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "　", with: "")
        t = t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t
        t = t.lowercased()
        for suffix in ["(円)", "(jpy)", "(税込)", "[円]"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private struct ColumnIndices {
        let date: Int?
        let title: Int?
        let amount: Int?
        /// 「出金額」「お引出し」のような支出専用の金額列 (銀行明細の出金/入金 分離型)。
        let expenseAmount: Int?
        /// 「入金額」「お預入れ」のような収入専用の金額列。
        let incomeAmount: Int?
        let kind: Int?
        let currency: Int?
        let category: Int?
        let payer: Int?
        let note: Int?

        /// いずれかの金額列が見つかったか。無ければ全行解析不能なのでヘッダエラーにする。
        var hasAmount: Bool { amount != nil || expenseAmount != nil || incomeAmount != nil }

        init(header: [String]) {
            func find(_ aliases: [String]) -> Int? {
                for (idx, col) in header.enumerated() {
                    if aliases.contains(col) { return idx }
                }
                return nil
            }
            // 自エクスポート + マネーフォワード / 銀行 / カード明細のよくある表記を受け入れる
            self.date     = find(["date", "日付", "取引日", "利用日", "ご利用日", "お取引日", "年月日", "利用年月日", "日時", "取引日時"])
            self.title    = find(["title", "内容", "品目", "memo", "description", "店名",
                                  "名称", "摘要", "利用店名", "ご利用店名", "利用先", "取引内容", "お取引内容"])
            let amountIdx  = find(["amount", "金額", "value", "利用金額", "ご利用金額",
                                   "支払金額", "お支払い金額", "支払額", "利用額", "決済金額"])
            let expenseIdx = find(["支出金額", "出金額", "出金金額", "出金", "お引出し", "お引き出し", "引出金額", "支払い金額"])
            let incomeIdx  = find(["収入金額", "入金額", "入金金額", "入金", "お預入れ", "お預け入れ", "預入金額"])
            if amountIdx == nil && expenseIdx == nil && incomeIdx == nil {
                // どの金額エイリアスにも一致しない場合のフォールバック:
                // 「〜金額」のような列名を金額列とみなす (残高/balance 列は除外)。
                self.amount = header.firstIndex { col in
                    (col.contains("金額") || col.contains("amount"))
                        && !col.contains("残高") && !col.contains("balance")
                }
            } else {
                self.amount = amountIdx
            }
            self.expenseAmount = expenseIdx
            self.incomeAmount  = incomeIdx
            self.kind     = find(["kind", "区分", "type", "種別", "収支区分"])
            self.currency = find(["currency", "通貨"])
            self.category = find(["category", "カテゴリ", "カテゴリー", "大項目", "中項目", "費目"])
            self.payer    = find(["payer", "支払者", "paidby", "payment_user"])
            self.note     = find(["note", "メモ", "備考"])
        }
    }

    private enum RowResult {
        case success(Row)
        case failure(String)
    }

    private static func makeRow(
        cols: [String],
        indices: ColumnIndices,
        defaultCurrency: String,
        defaultDate: Date
    ) -> RowResult {
        func col(_ idx: Int?) -> String? {
            guard let i = idx, i < cols.count else { return nil }
            let s = cols[i].trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        // 金額 (必須): 単一の金額列 → 出金列 → 入金列 の順で拾う。
        // 出金/入金 分離型 (銀行明細) は埋まっている側から kind も確定する。
        var parsedAmount: Decimal?
        var splitKind: TransactionKind?
        if let s = col(indices.amount), let a = parseAmount(s) {
            parsedAmount = a
        }
        if parsedAmount == nil, let s = col(indices.expenseAmount), let a = parseAmount(s) {
            parsedAmount = a
            splitKind = .expense
        }
        if parsedAmount == nil, let s = col(indices.incomeAmount), let a = parseAmount(s) {
            parsedAmount = a
            splitKind = .income
        }
        guard var amount = parsedAmount else {
            return .failure(String(localized: "金額列が空または解析不能"))
        }
        let title = col(indices.title) ?? String(localized: "(無題)")
        let date = col(indices.date).flatMap(parseDate(_:)) ?? defaultDate
        // kind: 分離列で確定 > kind 列 > 既定は支出。
        let kind: TransactionKind
        if let splitKind {
            kind = splitKind
        } else {
            let kindStr = col(indices.kind)?.lowercased() ?? "expense"
            kind = (kindStr.contains("income") || kindStr.contains("収入") || kindStr.contains("inc"))
                ? .income : .expense
        }
        // 負の金額 (例: 銀行明細の出金 = -450) は kind に意味を移して絶対値で保存する。
        if amount < 0 { amount = -amount }
        let currency: String? = {
            if let c = col(indices.currency)?.uppercased(), !c.isEmpty { return c }
            return nil
        }()
        return .success(Row(
            date: date,
            title: title,
            amount: amount,
            kind: kind,
            currencyCode: currency,
            categoryName: col(indices.category),
            payerName: col(indices.payer),
            note: col(indices.note)
        ))
    }

    /// "¥1,234.50" / "$5.99" / "1500" / "１，２３４円" など寛容にパース。負号は許容。
    private static func parseAmount(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // 全角数字・記号を半角化してから、通貨記号 / 千区切りカンマを除去
        let half = trimmed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? trimmed
        var cleaned = ""
        for ch in half {
            if ch.isNumber || ch == "." || ch == "-" {
                cleaned.append(ch)
            }
        }
        guard cleaned.contains(where: \.isNumber) else { return nil }
        return Decimal(string: cleaned)
    }

    /// 複数の一般的な日付フォーマットを順に試す。
    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd",
            "yyyy/M/d",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "yyyy.MM.dd",
            "yyyy年M月d日",
            "yyyyMMdd"
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = fmt
            return df
        }
    }()

    private static func parseDate(_ s: String) -> Date? {
        for df in dateFormatters {
            if let d = df.date(from: s) { return d }
        }
        // ISO8601 fallback
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }
}

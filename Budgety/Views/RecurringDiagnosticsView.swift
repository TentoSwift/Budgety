//
//  RecurringDiagnosticsView.swift
//  Budgety
//
//  定期項目 (RecurringRule) の動作確認用の読み取り専用 診断ビュー。
//  各ルールについて「ルールが期待する occurrence 列 (drift-free 計算)」と
//  「実在する Expense 行」を突き合わせ、状態を可視化する:
//    - 正常   : 期待日に行があり、値もルールと一致
//    - 編集済み: 期待日に行があるが値がルールと異なる (override)
//    - 削除済み: 期待日 (≤ lastGeneratedDate) に行が無い (= 生成後に削除された)
//    - 重複   : 同じ予定日に行が 2 件以上 (= 冪等が破れている異常)
//    - 想定外 : ルールの期待列に無い予定日の行 (startDate/間隔の変更後など)
//
//  挙動は一切変えない (削除は従来どおり hard delete のまま)。削除済みは
//  「期待されるのに行が無い」差分から推定する。
//  内部ビルド (DEBUG / TestFlight) でのみ Settings から開ける。
//

import SwiftUI
import CoreData

struct RecurringDiagnosticsView: View {
    @Environment(\.managedObjectContext) private var ctx
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RecurringRule.createdAt, ascending: true)],
        animation: .default
    ) private var rules: FetchedResults<RecurringRule>

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView("定期項目がありません", systemImage: "repeat")
            } else {
                ForEach(rules) { rule in
                    RuleDiagnosticsSection(rule: rule, ctx: ctx)
                }
            }
        }
        .navigationTitle("定期項目の診断")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Per-rule section

private struct RuleDiagnosticsSection: View {
    @ObservedObject var rule: RecurringRule
    let ctx: NSManagedObjectContext

    private struct Occurrence: Identifiable {
        let id = UUID()
        let date: Date
        let kind: Kind
        enum Kind {
            case normal
            case edited([String])
            case deleted
            case duplicate(Int)
            case unexpected(Int)
        }
    }

    private struct Summary {
        var normal = 0, edited = 0, deleted = 0, duplicate = 0, unexpected = 0
    }

    var body: some View {
        let (occurrences, summary) = analyze()
        let shown = Array(occurrences.prefix(80))
        Section {
            ruleHeader
            summaryRow(summary)
            ForEach(shown) { occ in
                occurrenceRow(occ)
            }
            if occurrences.count > shown.count {
                Text("ほか \(occurrences.count - shown.count) 件は省略")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(rule.displayTitle.isEmpty ? "(無題)" : rule.displayTitle)
        }
    }

    private var ruleHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(rule.resolvedFrequency.summary(interval: rule.resolvedInterval)) · \(rule.kind == .income ? "収入" : "支出") · \(rule.formattedAmount)")
                .font(.caption)
            Text("開始 \(fmt(rule.startDate)) · 終了 \(rule.endDate.map(fmt) ?? "なし") · 最終生成 \(rule.lastGeneratedDate.map(fmt) ?? "なし")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let sheet = rule.sheet {
                Text("シート: \(sheet.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(_ s: Summary) -> some View {
        HStack(spacing: 10) {
            badge("正常 \(s.normal)", .secondary)
            if s.edited > 0 { badge("編集 \(s.edited)", .orange) }
            if s.deleted > 0 { badge("削除 \(s.deleted)", .red) }
            if s.duplicate > 0 { badge("重複 \(s.duplicate)", .pink) }
            if s.unexpected > 0 { badge("想定外 \(s.unexpected)", .purple) }
        }
        .font(.caption2.weight(.semibold))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    @ViewBuilder
    private func occurrenceRow(_ occ: Occurrence) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(occ.kind))
                .foregroundStyle(tint(occ.kind))
                .font(.footnote)
                .frame(width: 18)
            Text(fmt(occ.date))
                .font(.callout.monospacedDigit())
            Spacer()
            Text(label(occ.kind))
                .font(.caption2)
                .foregroundStyle(tint(occ.kind))
        }
    }

    // MARK: - Analysis

    private func analyze() -> ([Occurrence], Summary) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = rule.startDate else { return ([], Summary()) }
        let endLimit = rule.endDate.map { cal.startOfDay(for: $0) } ?? today
        let limit = min(today, endLimit)

        let expected = RecurringOccurrenceService.occurrenceDays(
            start: start,
            frequency: rule.resolvedFrequency,
            interval: rule.resolvedInterval,
            until: limit,
            cap: 400,
            calendar: cal
        )
        let expectedSet = Set(expected)

        // 実在する生成行を予定日でグルーピング
        var byDate: [Date: [Expense]] = [:]
        if let id = rule.id {
            let req = NSFetchRequest<Expense>(entityName: "Expense")
            req.predicate = NSPredicate(format: "generatedFromRuleID == %@", id as CVarArg)
            req.returnsObjectsAsFaults = false
            for e in (try? ctx.fetch(req)) ?? [] {
                let d = cal.startOfDay(for: e.scheduledDate ?? e.date ?? .distantPast)
                byDate[d, default: []].append(e)
            }
        }
        let floor = rule.lastGeneratedDate.map { cal.startOfDay(for: $0) } ?? .distantPast

        var rows: [Occurrence] = []
        var summary = Summary()

        for d in expected {
            let matches = byDate[d] ?? []
            if matches.count >= 2 {
                rows.append(.init(date: d, kind: .duplicate(matches.count)))
                summary.duplicate += 1
            } else if let e = matches.first {
                let fields = editedFields(expense: e)
                if fields.isEmpty {
                    rows.append(.init(date: d, kind: .normal)); summary.normal += 1
                } else {
                    rows.append(.init(date: d, kind: .edited(fields))); summary.edited += 1
                }
            } else if d <= floor {
                rows.append(.init(date: d, kind: .deleted)); summary.deleted += 1
            }
            // d > floor かつ行無し = 未生成 (まだ来ていない/次回生成待ち) → 表示しない
        }

        // 期待列に無い予定日の行 (startDate/間隔変更後の取り残し等)
        for (d, es) in byDate where !expectedSet.contains(d) {
            rows.append(.init(date: d, kind: .unexpected(es.count)))
            summary.unexpected += es.count
        }

        rows.sort { $0.date > $1.date }
        return (rows, summary)
    }

    /// 生成行 e の値がルールと異なるフィールド名。
    private func editedFields(expense e: Expense) -> [String] {
        var f: [String] = []
        if rule.amountDecimal != e.amountDecimal { f.append("金額") }
        if (rule.title ?? "") != (e.title ?? "") { f.append("タイトル") }
        if (rule.note ?? "") != (e.note ?? "") { f.append("メモ") }
        if (rule.categoryRaw ?? "") != (e.categoryRaw ?? "") { f.append("カテゴリ") }
        if (rule.payerProfileID ?? "") != (e.payerProfileID ?? "") { f.append("支払者") }
        if (rule.beneficiaryProfileIDs ?? "") != (e.beneficiaryProfileIDs ?? "") { f.append("割り勘") }
        if (rule.currencyCode ?? "") != (e.currencyCode ?? "") { f.append("通貨") }
        if (rule.kindRaw ?? "") != (e.kindRaw ?? "") { f.append("種別") }
        return f
    }

    // MARK: - Presentation

    private func icon(_ k: Occurrence.Kind) -> String {
        switch k {
        case .normal:      "checkmark.circle"
        case .edited:      "pencil.circle.fill"
        case .deleted:     "trash.circle.fill"
        case .duplicate:   "exclamationmark.2"
        case .unexpected:  "questionmark.circle.fill"
        }
    }

    private func tint(_ k: Occurrence.Kind) -> Color {
        switch k {
        case .normal:      .secondary
        case .edited:      .orange
        case .deleted:     .red
        case .duplicate:   .pink
        case .unexpected:  .purple
        }
    }

    private func label(_ k: Occurrence.Kind) -> String {
        switch k {
        case .normal:                "正常"
        case .edited(let fields):    "編集済み (\(fields.joined(separator: "/")))"
        case .deleted:               "削除済み"
        case .duplicate(let n):      "重複 ×\(n)"
        case .unexpected(let n):     n > 1 ? "想定外 ×\(n)" : "想定外"
        }
    }

    private func fmt(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d"
        return f.string(from: date)
    }
}

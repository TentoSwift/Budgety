//
//  RecurringExpenseGenerator.swift
//  Expenso
//
//  RecurringRule から Expense を展開する。アプリ起動時とフォアグラウンド復帰時に走り、
//  startDate から「今日まで」の未生成 occurrence を作る。
//
//  冪等性: occurrence は `(generatedFromRuleID, scheduledDate)` で一意に識別する。
//  既に同じスロットの行が在れば作らない。これによりマルチデバイスで生成が二重に
//  走っても重複しない (CloudKit はユニーク制約を持てないので、生成側の冪等チェック +
//  収束 dedup で担保する設計)。
//
//  drift-free: occurrence 日付は RecurringOccurrenceService が startDate を anchor に
//  `anchor + n×interval` で各回独立に算出する (月末ドリフトしない)。
//
//  FX: 定期 occurrence は FX スナップショットを取らない (現行レートで精算される)。
//  通常の手入力支出のみ凍結する、という方針 (2026-06-02 決定)。
//
//  暴走防止のため 1 回の generate で 1 ルールあたり 12 件まで新規作成で打ち切る。
//

import Foundation
import CoreData

enum RecurringEditScope {
    case thisOnly, thisAndFollowing, all
}

@MainActor
enum RecurringExpenseGenerator {
    /// 1 回の generate 呼び出しで 1 ルールにつき「新規作成」する最大数。
    /// 数年放置されたルールが起動直後に大量の Expense を作るのを防ぐ。
    static let perRuleCap = 12

    static func saveRule(in sheet: ExpenseSheet, context: NSManagedObjectContext, kind: TransactionKind,
                         title: String, amount: Decimal, currency: String, category: String?,
                         frequency: RecurrenceFrequency, interval: Int32, start: Date, end: Date?) throws {
        guard !sheet.isDeleted, sheet.managedObjectContext === context,
              PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: sheet.objectID)
        else { throw AppIntentError.sheetNotFound }
        let rule = RecurringRule(context: context)
        if let store = sheet.objectID.persistentStore { context.assign(rule, to: store) }
        rule.id = UUID()
        rule.createdAt = .now
        rule.sheet = sheet
        rule.kindRaw = kind.rawValue
        rule.title = title
        rule.amount = NSDecimalNumber(decimal: amount)
        rule.currencyCode = currency
        rule.categoryRaw = category
        rule.note = ""
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        rule.payerProfileID = UserProfileStore.shared.canonicalSelfID(forShare: share)
        rule.frequency = frequency.rawValue
        rule.interval = interval
        rule.startDate = start
        rule.endDate = end
        // Virtual series need only the rule. Materialized mode saves its due occurrences in the same transaction.
        if !RecurringOccurrenceService.virtualizationEnabled {
            generate(for: rule, in: context)
        }
        try context.save()
    }

    /// viewContext 上の全 RecurringRule を走査して未生成分を作成する。
    /// save まで含む。
    static func generateAll(in ctx: NSManagedObjectContext) {
        guard RecurringOccurrenceService.featureEnabled else { return }   // 機能オフ: 生成しない (既存ルールは休眠)
        // 完全仮想化 ON 時は実体化しない (occurrence は表示時にルールから算出する)。
        guard !RecurringOccurrenceService.virtualizationEnabled else { return }
        let req = NSFetchRequest<RecurringRule>(entityName: "RecurringRule")
        guard let rules = try? ctx.fetch(req), !rules.isEmpty else { return }

        var didChange = false
        for rule in rules {
            if generate(for: rule, in: ctx) > 0 { didChange = true }
        }
        if didChange { try? ctx.save() }
    }

    /// 1 ルールを処理し、新規生成した件数を返す。`save` は呼び出し側で。
    @discardableResult
    static func generate(for rule: RecurringRule, in ctx: NSManagedObjectContext) -> Int {
        guard let startDate = rule.startDate, let sheet = rule.sheet else { return 0 }
        let cal = Calendar.current
        let today = rule.scheduledDay(forPostingDay: cal.startOfDay(for: .now), calendar: cal)
        let endDate = rule.endDate.map { cal.startOfDay(for: $0) } ?? .distantFuture
        let limit = today.compare(endDate) == .orderedAscending ? today : endDate
        guard cal.startOfDay(for: startDate).compare(limit) != .orderedDescending else { return 0 }

        // lastGeneratedDate を下限 (floor) に使う。これ以下の日付は再生成しない。
        // → 生成済み occurrence を単発削除しても次回復活しない (= 削除を尊重)。
        // (drift-free 計算 + この floor で、旧来のカーソル方式の「過去は触らない」挙動を維持)
        let floor = rule.lastGeneratedDate

        // 既に実体化済みの occurrence 日付。多端末で先に生成済みのものを冪等にスキップする
        // (floor が CloudKit でまだ同期されていない短い窓の重複対策)。
        // scheduledDate が未設定の旧データは date で代替する (バックフィル前の保険)。
        let materialized = materializedDays(for: rule, in: ctx, cal: cal)

        // drift-free な occurrence 日付列。floor より後 ～ limit までを最大 perRuleCap 件。
        let days = rule.scheduledDays(after: floor, until: limit, cap: perRuleCap, calendar: cal)

        let sheetStore = sheet.objectID.persistentStore
        let matchedCategory: ExpenseCategory? = {
            guard let raw = rule.categoryRaw, !raw.isEmpty,
                  let cats = sheet.categories as? Set<ExpenseCategory>,
                  let cat = cats.first(where: { $0.name == raw }),
                  cat.objectID.persistentStore == sheetStore else { return nil }
            return cat
        }()

        let skipped = rule.skippedDaySet
        var generated = 0
        for day in days {
            if materialized.contains(day) { continue }   // 冪等: 他端末生成済みはスキップ
            if skipped.contains(day) { continue }         // スキップ (削除) 済みは作らない
            makeOccurrence(for: rule, on: day, sheet: sheet, category: matchedCategory, in: ctx)
            rule.lastGeneratedDate = day
            generated += 1
        }

        return generated
    }

    /// occurrence を 1 件、rule の現在値で作成する (FX スナップショットは取らない)。
    /// `save` は呼び出し側で。generate と materializePast で共用。
    @discardableResult
    static func makeOccurrence(
        for rule: RecurringRule,
        on day: Date,
        sheet: ExpenseSheet,
        category: ExpenseCategory?,
        in ctx: NSManagedObjectContext
    ) -> Expense {
        let expense = Expense(context: ctx)
        if let store = sheet.objectID.persistentStore { ctx.assign(expense, to: store) }
        expense.title = rule.title
        expense.amount = rule.amount
        expense.kindRaw = rule.kindRaw
        expense.currencyCode = rule.currencyCode
        expense.categoryRaw = rule.categoryRaw
        // paidBy は denormalized キャッシュなので継承しない。表示は payerProfileID から動的解決。
        expense.paidBy = nil
        expense.payerProfileID = rule.payerProfileID
        expense.beneficiaryProfileIDs = rule.beneficiaryProfileIDs
        expense.note = rule.note
        expense.photoData = rule.photoData
        expense.date = rule.postingDay(for: day)
        expense.scheduledDate = day              // ← occurrence 識別キー
        expense.createdAt = .now
        expense.sheet = sheet
        expense.generatedFromRuleID = rule.id
        if let category { expense.category = category }
        // 定期 occurrence は FX スナップショットを取らない (現行レートで精算)。
        return expense
    }

    /// Deleting a generated or transient row must also remove its virtual calendar slot.
    static func deleteExpense(_ expense: Expense, in context: NSManagedObjectContext) {
        if let ruleID = expense.generatedFromRuleID,
           let rules = expense.sheet?.recurringRules as? Set<RecurringRule>,
           let rule = rules.first(where: { !$0.isDeleted && $0.id == ruleID }),
           let day = expense.scheduledDate ?? expense.date {
            rule.addSkippedDay(day)
        }
        context.delete(expense)
    }

    /// Keep already-visible entries in the ledger when their schedule is removed.
    static func deleteRule(_ rule: RecurringRule, in context: NSManagedObjectContext) {
        let calendar = Calendar.current
        let segments = seriesSegments(containing: rule)
        let familyID = rule.recurringSeriesID
        let ids = Set(segments.compactMap(\.id))
        for segment in segments {
            if RecurringOccurrenceService.virtualizationEnabled,
               let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) {
                materializePast(for: segment, before: segment.scheduledDay(forPostingDay: tomorrow), in: context)
            }
        }
        // Deep links use the stable family ID, including after its rules have been deleted.
        if segments.count > 1, let familyID, let rows = rule.sheet?.expenses as? Set<Expense> {
            for row in rows where row.generatedFromRuleID.map(ids.contains) == true {
                row.generatedFromRuleID = familyID
            }
        }
        for segment in segments { context.delete(segment) }
    }

    /// 「今後のみ変更」用: ルールの occurrence を [startDate, cutoff) の範囲で
    /// 現在 (= 変更前) の値で実体化して凍結する。完全仮想化フラグに関係なく実体化する。
    /// 既に実体化済み / スキップ済みの日付は作らない。`save` は呼び出し側で。
    @discardableResult
    static func materializePast(for rule: RecurringRule, before cutoff: Date, in ctx: NSManagedObjectContext) -> Int {
        guard rule.id != nil, let startDate = rule.startDate, let sheet = rule.sheet else { return 0 }
        let cal = Calendar.current
        let cutoffDay = cal.startOfDay(for: cutoff)
        guard cal.startOfDay(for: startDate).compare(cutoffDay) == .orderedAscending else { return 0 }
        let materialized = materializedDays(for: rule, in: ctx, cal: cal)
        let skipped = rule.skippedDaySet
        let sheetStore = sheet.objectID.persistentStore
        let matchedCategory: ExpenseCategory? = {
            guard let raw = rule.categoryRaw, !raw.isEmpty,
                  let cats = sheet.categories as? Set<ExpenseCategory>,
                  let cat = cats.first(where: { $0.name == raw }),
                  cat.objectID.persistentStore == sheetStore else { return nil }
            return cat
        }()
        guard let lastDay = cal.date(byAdding: .day, value: -1, to: cutoffDay) else { return 0 }
        let days = rule.scheduledDays(until: lastDay, calendar: cal)
        var count = 0
        for day in days {
            if materialized.contains(day) || skipped.contains(day) { continue }
            makeOccurrence(for: rule, on: day, sheet: sheet, category: matchedCategory, in: ctx)
            count += 1
        }
        return count
    }

    /// このルールから実体化済みの occurrence 日付集合 (startOfDay 正規化)。
    /// 生成済み行・オーバーライド・スキップ tombstone はすべて `generatedFromRuleID` を持つ。
    private static func materializedDays(
        for rule: RecurringRule,
        in ctx: NSManagedObjectContext,
        cal: Calendar
    ) -> Set<Date> {
        guard let id = rule.id, let sheet = rule.sheet else { return [] }
        let req = NSFetchRequest<Expense>(entityName: "Expense")
        req.predicate = NSPredicate(format: "sheet == %@ AND generatedFromRuleID == %@", sheet, id as CVarArg)
        req.returnsObjectsAsFaults = false
        let rows = (try? ctx.fetch(req)) ?? []
        var set = Set<Date>()
        for e in rows {
            if let d = e.scheduledDate ?? e.date {
                set.insert(cal.startOfDay(for: d))
            }
        }
        return set
    }
}

extension RecurringExpenseGenerator {
    static func seriesSegments(containing rule: RecurringRule) -> [RecurringRule] {
        rule.orderedSeriesSegments
    }

    /// Resolve a historical or future revision by its original scheduled calendar day.
    static func segment(for rule: RecurringRule, on day: Date) -> RecurringRule? {
        let day = Calendar.current.startOfDay(for: day)
        guard let active = seriesSegments(containing: rule).last(where: { candidate in
            guard let start = candidate.startDate else { return false }
            return day.compare(start) != .orderedAscending
        }), active.endDate.map({ day.compare($0) != .orderedDescending }) ?? true else { return nil }
        return active
    }

    private static var unavailable: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectReferentialIntegrityError,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "この明細は現在表示できません。")])
    }

    /// The caller commits the edit in its own context. A preview created to edit a series is disposable.
    static func edit(_ expense: Expense, scope: RecurringEditScope, isVirtualDraft: Bool = false,
                     updateExpense: (Expense, Bool) -> Void, updateRule: (RecurringRule) -> Void) throws {
        guard !expense.isDeleted, !expense.isSkipped, let sheet = expense.sheet, let id = expense.generatedFromRuleID,
              let rule = (sheet.recurringRules as? Set<RecurringRule>)?.first(where: { !$0.isDeleted && $0.id == id }),
              let scheduled = expense.scheduledDate ?? expense.date,
              let active = segment(for: rule, on: scheduled), !active.isSkippedDay(scheduled)
        else { throw unavailable }
        try apply(scope, to: expense, rule: active, scheduled: scheduled, isVirtualDraft: isVirtualDraft || expense.isInserted,
                  updateExpense: updateExpense, updateRule: updateRule)
    }

    /// The schedule editor may select a future occurrence that has never appeared in the ledger.
    static func edit(_ rule: RecurringRule, on day: Date, scope: RecurringEditScope,
                     updateExpense: (Expense, Bool) -> Void, updateRule: (RecurringRule) -> Void) throws {
        guard !rule.isDeleted, let sheet = rule.sheet, let context = rule.managedObjectContext else { throw unavailable }
        let calendar = Calendar.current
        let scheduled = calendar.startOfDay(for: day)
        let active = segment(for: rule, on: scheduled) ?? rule
        guard let id = active.id, let dayBefore = calendar.date(byAdding: .day, value: -1, to: scheduled) else { throw unavailable }
        let rows = ((sheet.expenses as? Set<Expense>) ?? []).filter {
            !$0.isDeleted && $0.generatedFromRuleID == id &&
                ($0.scheduledDate ?? $0.date).map { calendar.isDate($0, inSameDayAs: scheduled) } == true
        }
        guard rows.count <= 1 else { throw unavailable }
        if scope != .all {
            guard !active.isSkippedDay(scheduled), rows.first?.isSkipped != true,
                  !rows.isEmpty || !active.scheduledDays(after: dayBefore, until: scheduled).isEmpty
            else { throw unavailable }
        }
        let existing = rows.first
        let category = (sheet.categories as? Set<ExpenseCategory>)?.first { $0.name == active.categoryRaw && $0.kind == active.kind }
        let row = existing ?? makeOccurrence(for: active, on: scheduled, sheet: sheet, category: category, in: context)
        do {
            try apply(scope, to: row, rule: active, scheduled: scheduled, isVirtualDraft: existing == nil,
                      updateExpense: updateExpense, updateRule: updateRule)
        } catch {
            if existing == nil { context.delete(row) }
            throw error
        }
    }

    private static func apply(_ scope: RecurringEditScope, to selected: Expense, rule: RecurringRule,
                              scheduled: Date, isVirtualDraft: Bool, updateExpense: (Expense, Bool) -> Void,
                              updateRule: (RecurringRule) -> Void) throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: scheduled)
        guard let context = rule.managedObjectContext, selected.managedObjectContext === context,
              let sheet = rule.sheet, let family = rule.recurringSeriesID, let start = rule.startDate,
              let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else { throw unavailable }

        let segments = seriesSegments(containing: rule)
        guard let index = segments.firstIndex(of: rule) else { throw unavailable }
        let rows = (sheet.expenses as? Set<Expense> ?? []).filter { !$0.isDeleted }
        guard !isVirtualDraft || !rows.contains(where: { row in
            row !== selected && row.generatedFromRuleID == rule.id &&
            (row.scheduledDate ?? row.date).map { calendar.isDate($0, inSameDayAs: day) } == true
        }) else { throw unavailable }

        // A cadence change can remove old calendar slots. Preserve a legacy row's own
        // receipt, edits or settlement if its slot goes away.
        let previousRules = Dictionary(segments.compactMap { segment in segment.id.map { ($0, segment) } },
                                       uniquingKeysWith: { first, _ in first })
        let independentRows = Set(rows.compactMap { row -> NSManagedObjectID? in
            guard let id = row.generatedFromRuleID, let source = previousRules[id],
                  let slot = row.scheduledDate ?? row.date, !row.isSkipped else { return nil }
            let customized = !(row.settledBeneficiaryProfileIDs ?? "").isEmpty ||
                row.amount != source.amount || row.kind != source.kind ||
                (row.title ?? "") != (source.title ?? "") || row.resolvedCurrencyCode != source.resolvedCurrencyCode ||
                (row.categoryRaw ?? "") != (source.categoryRaw ?? "") || (row.note ?? "") != (source.note ?? "") ||
                row.photoData != source.photoData || (row.payerProfileID ?? "") != (source.payerProfileID ?? "") ||
                (row.beneficiaryProfileIDs ?? "") != (source.beneficiaryProfileIDs ?? "") ||
                row.date.map { !calendar.isDate($0, inSameDayAs: source.postingDay(for: slot)) } == true
            return customized ? row.objectID : nil
        })

        let originalDate = selected.date ?? rule.postingDay(for: day)
        updateExpense(selected, true)
        if scope == .thisOnly {
            rule.addSkippedDay(day)
            selected.generatedFromRuleID = nil
            selected.scheduledDate = nil
            selected.captureFXSnapshot()
            return
        }

        let newDate = selected.date ?? originalDate
        let shift = calendar.dateComponents([.day], from: calendar.startOfDay(for: originalDate),
                                            to: calendar.startOfDay(for: newDate)).day ?? 0
        var targets = scope == .all ? segments : Array(segments[index...])
        if scope == .thisAndFollowing, day.compare(calendar.startOfDay(for: start)) == .orderedDescending {
            let suffix = RecurringRule(context: context)
            if let store = sheet.objectID.persistentStore { context.assign(suffix, to: store) }
            // All rule attributes are scalar values (or immutable Foundation values).
            // Copy receipts, split participants and future rule attributes together with the schedule.
            for key in rule.entity.attributesByName.keys { suffix.setValue(rule.value(forKey: key), forKey: key) }
            suffix.sheet = sheet
            suffix.id = UUID()
            suffix.seriesID = family
            suffix.createdAt = .now
            suffix.scheduleAnchor = rule.scheduleAnchor ?? start
            suffix.startDate = day
            let excluded = rule.skippedDaySet
            suffix.skippedDaySet = excluded.filter { $0.compare(day) != .orderedAscending }
            rule.skippedDaySet = excluded.subtracting(suffix.skippedDaySet)
            rule.endDate = previousDay
            if let cursor = rule.lastGeneratedDate, cursor.compare(day) != .orderedAscending {
                rule.lastGeneratedDate = previousDay
            }
            for row in rows where row.generatedFromRuleID == rule.id {
                if let slot = row.scheduledDate ?? row.date, calendar.startOfDay(for: slot).compare(day) != .orderedAscending {
                    row.generatedFromRuleID = suffix.id
                }
            }
            targets[0] = suffix
        }

        let commonStart = targets[0].startDate ?? day
        var rescheduled: [UUID: RecurringRule] = [:]
        for (offset, target) in targets.enumerated() {
            let boundary = target.startDate ?? day
            let oldFrequency = target.resolvedFrequency
            let oldInterval = target.resolvedInterval
            let oldEnd = target.endDate
            updateRule(target)
            let startWasEdited = target.startDate != boundary
            let cadenceWasEdited = oldFrequency != target.resolvedFrequency || oldInterval != target.resolvedInterval
            if let newStart = target.startDate, newStart != boundary {
                // Later revisions keep their boundaries; only the first revision in the
                // complete series may move its lower bound when the start date changes.
                target.scheduleAnchor = newStart
                let crossesNext = offset + 1 < targets.count &&
                    targets[offset + 1].startDate.map { newStart.compare($0) != .orderedAscending } == true
                if offset > 0 || scope == .thisAndFollowing || crossesNext { target.startDate = boundary }
            } else if cadenceWasEdited {
                target.scheduleAnchor = commonStart
            }
            if offset + 1 < targets.count, let next = targets[offset + 1].startDate,
               let last = calendar.date(byAdding: .day, value: -1, to: next),
               target.endDate.map({ $0.compare(last) == .orderedDescending }) ?? true {
                target.endDate = last
            }
            if (startWasEdited || cadenceWasEdited || target.endDate != oldEnd), let id = target.id {
                rescheduled[id] = target
                target.lastGeneratedDate = nil
            }
            target.postingDayOffset = Int32(clamping: Int(target.postingDayOffset) + shift)
        }

        let ids = Set(targets.compactMap(\.id))
        for row in rows {
            guard let id = row.generatedFromRuleID, ids.contains(id), !row.isSkipped else { continue }
            if let target = rescheduled[id], let slot = row.scheduledDate ?? row.date,
               let before = calendar.date(byAdding: .day, value: -1, to: slot),
               target.scheduledDays(after: before, until: slot, cap: 1).isEmpty {
                if independentRows.contains(row.objectID) {
                    row.generatedFromRuleID = nil
                    row.scheduledDate = nil
                    row.captureFXSnapshot()
                } else {
                    context.delete(row)
                }
                continue
            }
            if row !== selected {
                updateExpense(row, false)
                if shift != 0, let old = row.date { row.date = calendar.date(byAdding: .day, value: shift, to: old) }
            }
        }
        if isVirtualDraft && !selected.isDeleted { context.delete(selected) }
    }
}

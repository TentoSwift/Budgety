import CoreData

/// 仮想 occurrence を**実支出と同じ `ExpenseRowContainer`/`ExpenseRowView` で描画する**ための
/// 表示専用 Expense 供給器。occurrence は値型なので、行を描くには `Expense` インスタンスが要る。
///
/// ここでは viewContext の**子コンテキスト** (parent=viewContext) に Expense を作る。子は
/// **絶対に save しない**ので永続化されず、`ensureSelfMemberExists` 等の副次 save にも巻き込まれない
/// (= 仮想化の「occurrence を保存しない」前提を壊さない)。sheet/category は親 (record) と同じ
/// objectID を子で参照するので、`ExpenseRowView` の共有判定・支払者アバター・通貨・repeat アイコンが
/// そのまま正しく描ける。編集時の変更は保存を確定した時だけ別コンテキストで適用する。
///
/// occurrence の内容 (金額/カテゴリ/支払者/タイトル等) を署名キーにしてキャッシュするので、
/// ルール変更で値が変われば新しい行に作り直され、stale を防ぐ。
@MainActor
final class VirtualRowBacking {
    private var context: NSManagedObjectContext?
    private var cache: [String: Expense] = [:]

    func displayExpense(for occ: RecurringOccurrence, sheet: ExpenseSheet) -> Expense {
        let ctx = ensureContext(parent: sheet.managedObjectContext)
        let key = sheet.objectID.uriRepresentation().absoluteString + "|" + signature(occ)
        if let cached = cache[key] {
            if cached.note != occ.note { cached.note = occ.note }
            if cached.photoData != occ.photoData { cached.photoData = occ.photoData }
            return cached
        }
        // 暴走防止: 長期スクロール等でキャッシュが膨らんだら一旦クリアする。
        if cache.count > 400 {
            cache.values.forEach { ctx.delete($0) }
            cache.removeAll()
        }
        let e = Expense(context: ctx)
        if let childSheet = try? ctx.existingObject(with: sheet.objectID) as? ExpenseSheet {
            e.sheet = childSheet
            if !occ.categoryRaw.isEmpty,
               let cats = childSheet.categories as? Set<ExpenseCategory>,
               let cat = cats.first(where: { $0.kind == occ.kind && $0.name == occ.categoryRaw }) {
                e.category = cat
            }
        }
        e.title = occ.title.isEmpty ? nil : occ.title
        e.amount = NSDecimalNumber(decimal: occ.amount)
        e.kindRaw = occ.kind.rawValue
        e.currencyCode = occ.currencyCode
        e.categoryRaw = occ.categoryRaw.isEmpty ? nil : occ.categoryRaw
        e.payerProfileID = occ.payerProfileID
        e.beneficiaryProfileIDs = occ.beneficiaryProfileIDs
        e.note = occ.note
        e.photoData = occ.photoData
        e.date = occ.date
        e.scheduledDate = occ.scheduledDate
        e.generatedFromRuleID = occ.ruleID   // → ExpenseRowView が repeat アイコンを出す
        cache[key] = e
        return e
    }

    private func ensureContext(parent: NSManagedObjectContext?) -> NSManagedObjectContext {
        if let context { return context }
        let ctx = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        ctx.parent = parent
        // 親 (viewContext) の変更 (共有ロード・メンバー名変更等) を子の sheet に反映させる。
        ctx.automaticallyMergesChangesFromParent = true
        context = ctx
        return ctx
    }

    private func signature(_ o: RecurringOccurrence) -> String {
        "\(o.id)|\(o.date.timeIntervalSinceReferenceDate)|\(o.amount)|\(o.categoryRaw)|\(o.payerProfileID ?? "")|\(o.beneficiaryProfileIDs)|\(o.title)|\(o.kind.rawValue)|\(o.currencyCode)"
    }
}

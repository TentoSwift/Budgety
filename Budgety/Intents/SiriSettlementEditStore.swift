#if os(watchOS) || (os(iOS) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData

@available(iOS 27.3, *)
@MainActor
enum SiriSettlementEditStore {
    typealias Store = SiriSettlementStore

    struct Request {
        var sender: SiriSheetMemberEntity?
        var recipient: SiriSheetMemberEntity?
        var amount: Double?
        var currency: String?
        var date: Date?
        var note: String?
    }

    struct Values: Equatable {
        var sender: String
        var recipient: String
        var amount: Decimal
        var currency: String
        var date: Date?
        var note: String?

        init(_ row: SettlementRecord) {
            sender = row.fromProfileID ?? ""
            recipient = row.toProfileID ?? ""
            amount = row.amountDecimal
            currency = row.resolvedCurrencyCode
            date = row.date
            note = row.note
        }
    }

    struct Prepared {
        let sheetID: String
        let sheetName: String
        let sheetCurrency: String
        let sheetSymbol: String
        let sheetColorHex: String
        let fromAvatar: Store.Avatar
        let toAvatar: Store.Avatar
        let after: Values
        let changes: [String]
        fileprivate let identifier: String
        fileprivate let original: NSDictionary
        fileprivate let request: Request
        @MainActor var formattedAmount: String { Store.formatAmount(after.amount, currency: after.currency) }
    }

    static func prepare(identifier: String, sheetID: String, request: Request) throws -> Prepared {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try Store.writableSheet(sheetID, access: access)
        let row = try record(identifier: identifier, in: sheet, access: access)
        return try prepare(row, identifier: identifier, sheet: sheet, access: access, request: request)
    }

    private static func prepare(_ row: SettlementRecord, identifier: String, sheet: ExpenseSheet,
                                access: IntentSheetAccess, request: Request) throws -> Prepared {
        let old = Values(row)
        var new = old
        let roster = try SiriSheetMemberRoster(sheet: sheet, access: access)
        if request.sender != nil || request.recipient != nil {
            let members = try Store.members(in: sheet, access: access)
            func selectedID(_ selection: SiriSheetMemberEntity) throws -> String {
                guard let member = members.first(where: { $0.id == selection.id }) else { throw Store.Failure.members }
                return member.profileID
            }
            if let sender = request.sender { new.sender = try selectedID(sender) }
            if let recipient = request.recipient { new.recipient = try selectedID(recipient) }
        }
        guard !new.sender.isEmpty, !new.recipient.isEmpty, new.sender != new.recipient,
              !(roster.selfProfileIDs.contains(new.sender) && roster.selfProfileIDs.contains(new.recipient))
        else { throw Store.Failure.members }
        if let value = request.amount { new.amount = try Store.amount(value) }
        if let currency = request.currency { new.currency = try Store.currencyCode(currency, fallback: old.currency) }
        if let date = request.date, old.date.map({ Calendar.current.isDate($0, inSameDayAs: date) }) != true { new.date = date }
        if let note = request.note { new.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }

        let from = Store.avatar(new.sender, in: sheet)
        let to = Store.avatar(new.recipient, in: sheet)
        var changes: [String] = []
        func change(_ label: String, _ before: String, _ after: String) {
            changes.append(String(localized: "\(label)：\(before) → \(after)"))
        }
        if old.sender != new.sender { change(String(localized: "送金元"), Store.avatar(old.sender, in: sheet).name, from.name) }
        if old.recipient != new.recipient { change(String(localized: "送金先"), Store.avatar(old.recipient, in: sheet).name, to.name) }
        if old.amount != new.amount || old.currency != new.currency {
            change(String(localized: "金額"), Store.formatAmount(old.amount, currency: old.currency) + " " + old.currency,
                   Store.formatAmount(new.amount, currency: new.currency) + " " + new.currency)
        }
        if old.date != new.date {
            let unknown = String(localized: "日付不明")
            change(String(localized: "送金日"), old.date?.formatted(date: .abbreviated, time: .omitted) ?? unknown,
                   new.date?.formatted(date: .abbreviated, time: .omitted) ?? unknown)
        }
        if (old.note ?? "") != (new.note ?? "") {
            let empty = String(localized: "なし")
            change(String(localized: "メモ"), old.note.flatMap { $0.isEmpty ? nil : $0 } ?? empty,
                   new.note.flatMap { $0.isEmpty ? nil : $0 } ?? empty)
        }
        guard !changes.isEmpty else { throw EditError.unchanged }
        return Prepared(sheetID: sheet.objectID.uriRepresentation().absoluteString, sheetName: sheet.displayName,
                        sheetCurrency: sheet.resolvedDefaultCurrencyCode, sheetSymbol: sheet.displaySymbol,
                        sheetColorHex: sheet.displayColorHex, fromAvatar: from, toAvatar: to, after: new, changes: changes,
                        identifier: identifier, original: snapshot(row), request: request)
    }

    static func commit(_ prepared: Prepared) throws -> UUID {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try Store.writableSheet(prepared.sheetID, access: access)
        let row = try record(identifier: prepared.identifier, in: sheet, access: access)
        guard snapshot(row) == prepared.original else { throw Store.Failure.changed }
        let fresh = try prepare(row, identifier: prepared.identifier, sheet: sheet, access: access, request: prepared.request)
        guard fresh.after == prepared.after, fresh.changes == prepared.changes, fresh.sheetName == prepared.sheetName,
              fresh.sheetCurrency == prepared.sheetCurrency, fresh.fromAvatar.name == prepared.fromAvatar.name,
              fresh.toAvatar.name == prepared.toAvatar.name else { throw Store.Failure.changed }
        let new = fresh.after
        let refreshFX = row.amountDecimal != new.amount || row.resolvedCurrencyCode != new.currency
        let rawCurrency = row.currencyCode
        Store.apply(to: row, sheet: sheet, fromID: new.sender, toID: new.recipient, amount: new.amount,
                    currencyCode: new.currency, date: new.date, note: new.note, refreshFX: refreshFX)
        if !refreshFX { row.currencyCode = rawCurrency }
        let id = row.id ?? UUID()
        row.id = id
        try access.context.save()
        return id
    }

    private static func snapshot(_ row: SettlementRecord) -> NSDictionary {
        row.committedValues(forKeys: Array(row.entity.attributesByName.keys)) as NSDictionary
    }

    static func record(identifier: String, in sheet: ExpenseSheet, access: IntentSheetAccess) throws -> SettlementRecord {
        let prefix = sheet.objectID.uriRepresentation().absoluteString + "#"
        guard identifier.hasPrefix(prefix) else { throw Store.Failure.unavailable }
        let suffix = String(identifier.dropFirst(prefix.count))
        let record: SettlementRecord?
        if let uuid = UUID(uuidString: suffix) {
            let request = SettlementRecord.fetchRequest()
            request.predicate = NSPredicate(format: "sheet == %@ AND id == %@", sheet, uuid as CVarArg)
            request.fetchLimit = 2
            let matches = try access.context.fetch(request)
            record = matches.count == 1 ? matches[0] : nil
        } else if let url = URL(string: suffix), url.scheme == "x-coredata",
                  let oid = access.context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
                  oid.entity.name == "SettlementRecord" {
            record = try? access.context.existingObject(with: oid) as? SettlementRecord
        } else {
            record = nil
        }
        guard let record, record.sheet == sheet, canEdit(record, access: access) else { throw Store.Failure.unavailable }
        return record
    }

    static func canEdit(_ row: SettlementRecord, access: IntentSheetAccess) -> Bool {
        guard !row.isDeleted, !row.objectID.isTemporaryID,
              PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: row.objectID) else { return false }
        if let live = access.viewContext.registeredObject(for: row.objectID) as? SettlementRecord {
            return !live.isDeleted && !live.hasPersistentChangedValues
        }
        return true
    }

    private enum EditError: Error, CustomLocalizedStringResourceConvertible {
        case unchanged
        var localizedStringResource: LocalizedStringResource { "変更する項目がありません。" }
    }
}
#endif

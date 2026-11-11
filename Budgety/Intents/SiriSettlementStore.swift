#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import CloudKit
import CryptoKit

@available(iOS 27.3, *)
@MainActor
enum SiriSettlementStore {
    struct Avatar {
        let name: String
        let colorHex: String
        let photoData: Data?
        let isVirtual: Bool
    }

    struct Balance {
        let id: String
        let avatar: Avatar
        let amount: Decimal
        var name: String { avatar.name }
    }

    struct Proposal {
        let id: String
        let fromAvatar: Avatar
        let toAvatar: Avatar
        let amount: Decimal
        let formattedAmount: String
        fileprivate let fromID: String
        fileprivate let toID: String
        var fromName: String { fromAvatar.name }
        var toName: String { toAvatar.name }
    }

    struct Status {
        let sheetID: String
        let sheetName: String
        let sheetSymbol: String
        let sheetColorHex: String
        let currencyCode: String
        let balances: [Balance]
        let proposals: [Proposal]
        let missingRateCurrencies: [String]
        let includedExpenseCount: Int
    }

    struct Receipt {
        let sheetName: String
        let sheetSymbol: String
        let sheetColorHex: String
        let fromAvatar: Avatar
        let toAvatar: Avatar
        let formattedAmount: String
        let date: Date?
        var fromName: String { fromAvatar.name }
        var toName: String { toAvatar.name }
    }

    fileprivate enum Source {
        case proposal(String)
        case manual(fromMemberID: String, toMemberID: String, previousPayments: Set<NSManagedObjectID>)
    }

    struct Prepared {
        let sheetID: String
        let sheetName: String
        let sheetSymbol: String
        let sheetColorHex: String
        let fromAvatar: Avatar
        let toAvatar: Avatar
        let amount: Decimal
        let currencyCode: String
        let date: Date
        let note: String?
        var fromName: String { fromAvatar.name }
        var toName: String { toAvatar.name }
        @MainActor var formattedAmount: String { SiriSettlementStore.formatAmount(amount, currency: currencyCode) }
        fileprivate let source: Source
        fileprivate let requestID: UUID
        fileprivate let fromID: String
        fileprivate let toID: String
        fileprivate let sheetCurrency: String
    }

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case changed, members, readOnly, unavailable
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .changed: "精算の内容が変わりました。最新の内容を確認してください。"
            case .members: "同じシートから別々の送金者と受取者を選んでください。"
            case .readOnly: "このシートには送金を記録できません。"
            case .unavailable: "この送金記録は現在表示できません。"
            }
        }
    }

    private static func access() throws -> IntentSheetAccess {
        try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
    }

    static func status(sheetID: String) throws -> Status {
        let access = try access()
        return snapshot(for: try access.resolve(sheetID))
    }

    static func writableSheets() throws -> [ExpenseSheetEntity] {
        let access = try access()
        return try access.sheets().filter(canWrite).map(ExpenseSheetEntity.from)
    }

    static func proposals(sheetID: String) throws -> [Proposal] {
        let access = try access()
        return snapshot(for: try writableSheet(sheetID, access: access)).proposals
    }

    static func prepareSuggested(sheetID: String, proposalID: String) throws -> Prepared {
        let access = try access()
        let sheet = try writableSheet(sheetID, access: access)
        guard let proposal = snapshot(for: sheet).proposals.first(where: { $0.id == proposalID }) else { throw Failure.changed }
        return prepared(sheet: sheet, fromID: proposal.fromID, toID: proposal.toID, amount: proposal.amount,
                        code: sheet.resolvedDefaultCurrencyCode, date: .now, note: nil, source: .proposal(proposalID))
    }

    static func prepareManual(sheetID: String, fromMemberID: String, toMemberID: String,
                              amount value: Double, currency: String?, date: Date?, note: String? = nil) throws -> Prepared {
        let access = try access()
        let sheet = try writableSheet(sheetID, access: access)
        let ids = try memberPair(from: fromMemberID, to: toMemberID, sheet: sheet, access: access)
        let code = try currencyCode(currency, fallback: sheet.resolvedDefaultCurrencyCode)
        let paymentDate = date ?? .now
        let value = try amount(value)
        let previous = matchingPayments(in: sheet, from: ids.from, to: ids.to, amount: value, currency: code, on: paymentDate)
        return prepared(sheet: sheet, fromID: ids.from, toID: ids.to, amount: value, code: code, date: paymentDate, note: note,
                        source: .manual(fromMemberID: fromMemberID, toMemberID: toMemberID, previousPayments: previous))
    }

    static func commit(_ confirmed: Prepared) throws -> UUID {
        let access = try access()
        let sheet = try writableSheet(confirmed.sheetID, access: access)
        if let existing = try find(confirmed.requestID, in: sheet, access: access) {
            guard existing.fromProfileID == confirmed.fromID, existing.toProfileID == confirmed.toID,
                  existing.amountDecimal == confirmed.amount, existing.resolvedCurrencyCode == confirmed.currencyCode,
                  existing.date == confirmed.date, existing.note == confirmed.note else { throw Failure.changed }
            return confirmed.requestID
        }
        guard sheet.displayName == confirmed.sheetName, sheet.resolvedDefaultCurrencyCode == confirmed.sheetCurrency,
              avatar(confirmed.fromID, in: sheet).name == confirmed.fromName,
              avatar(confirmed.toID, in: sheet).name == confirmed.toName else { throw Failure.changed }
        switch confirmed.source {
        case .proposal(let id):
            guard snapshot(for: sheet).proposals.contains(where: { $0.id == id }) else { throw Failure.changed }
        case .manual(let fromMemberID, let toMemberID, let previous):
            let ids = try memberPair(from: fromMemberID, to: toMemberID, sheet: sheet, access: access)
            guard ids.from == confirmed.fromID, ids.to == confirmed.toID,
                  matchingPayments(in: sheet, from: ids.from, to: ids.to, amount: confirmed.amount,
                                   currency: confirmed.currencyCode, on: confirmed.date) == previous else { throw Failure.changed }
        }
        guard let store = sheet.objectID.persistentStore else { throw Failure.unavailable }
        let record = SettlementRecord(context: access.context)
        access.context.assign(record, to: store)
        record.id = confirmed.requestID
        record.createdAt = .now
        record.sheet = sheet
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        let profile = UserProfileStore.shared
        record.createdByProfileID = profile.canonicalSelfID(forShare: share) ?? profile.userRecordName ?? profile.selfMemberID?.uuidString
        apply(to: record, sheet: sheet, fromID: confirmed.fromID, toID: confirmed.toID, amount: confirmed.amount,
              currencyCode: confirmed.currencyCode, date: confirmed.date, note: confirmed.note)
        try access.context.save()
        return confirmed.requestID
    }

    static func receipt(sheetID: String, recordID: UUID) throws -> Receipt {
        let access = try access()
        let sheet = try access.resolve(sheetID)
        guard let record = try find(recordID, in: sheet, access: access),
              let fromID = record.fromProfileID, let toID = record.toProfileID else { throw Failure.unavailable }
        if let live = access.viewContext.registeredObject(for: record.objectID),
           live.isDeleted || live.hasPersistentChangedValues { throw Failure.changed }
        return Receipt(sheetName: sheet.displayName, sheetSymbol: sheet.displaySymbol, sheetColorHex: sheet.displayColorHex,
                       fromAvatar: avatar(fromID, in: sheet), toAvatar: avatar(toID, in: sheet),
                       formattedAmount: formatAmount(record.amountDecimal, currency: record.resolvedCurrencyCode), date: record.date)
    }

    /// Keep subunit amounts visible when a recorded value has more precision than the currency's usual display.
    static func formatAmount(_ amount: Decimal, currency: String) -> String {
        let places = max(0, -amount.exponent)
        if places > CurrencyCatalog.fractionDigits(for: currency) {
            return amount.formatted(.currency(code: currency).precision(.fractionLength(places)))
        }
        return CurrencyCatalog.format(amount, code: currency)
    }

    static func amount(_ value: Double) throws -> Decimal {
        guard value.isFinite, value > 0, let amount = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN, amount > 0 else { throw AppIntentError.invalidAmount }
        return amount
    }

    static func currencyCode(_ raw: String?, fallback: String) throws -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        guard let code = CurrencyCatalog.transactionCurrencyCode(for: raw) else { throw AppIntentError.unsupportedCurrency }
        return code
    }

    static func apply(to record: SettlementRecord, sheet: ExpenseSheet, fromID: String, toID: String,
                      amount: Decimal, currencyCode: String, date: Date?, note: String?, refreshFX: Bool = true) {
        record.fromProfileID = fromID
        record.toProfileID = toID
        record.amountDecimal = amount
        record.currencyCode = currencyCode
        record.date = date
        record.note = note
        if refreshFX {
            let target = sheet.resolvedDefaultCurrencyCode
            let converted = FXRatesService.shared.convert(amount, from: currencyCode, to: target)
            record.fxConvertedAmountDecimal = converted
            record.fxTargetCurrency = converted == nil ? nil : target
        }
    }

    static func writableSheet(_ sheetID: String, access: IntentSheetAccess) throws -> ExpenseSheet {
        let sheet = try access.resolve(sheetID)
        guard canWrite(sheet) else { throw Failure.readOnly }
        let context = access.viewContext
        if context.hasChanges {
            // The UIKit/SwiftUI editor may have a new, moved, deleted, or updated obligation
            // that the separate committed-data context cannot see yet.
            let changed = context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects)
            for obj in changed {
                if obj.objectID == sheet.objectID { throw Failure.changed }
                guard ["Expense", "RecurringRule", "SettlementRecord", "ParticipantProfile"].contains(obj.entity.name ?? "") else { continue }
                let current = obj.value(forKey: "sheet") as? ExpenseSheet
                let previous = obj.isInserted ? nil : obj.committedValues(forKeys: ["sheet"])["sheet"] as? ExpenseSheet
                if current?.objectID == sheet.objectID || previous?.objectID == sheet.objectID { throw Failure.changed }
            }
        }
        return sheet
    }

    private static func canWrite(_ sheet: ExpenseSheet) -> Bool {
        PersistenceController.shared.container.canUpdateRecord(forManagedObjectWith: sheet.objectID)
    }

    private static func memberPair(from: String, to: String, sheet: ExpenseSheet, access: IntentSheetAccess) throws -> (from: String, to: String) {
        let people = try members(in: sheet, access: access)
        guard let sender = people.first(where: { $0.id == from }),
              let recipient = people.first(where: { $0.id == to }),
              !sender.profileID.isEmpty, !recipient.profileID.isEmpty, sender.profileID != recipient.profileID else { throw Failure.members }
        return (sender.profileID, recipient.profileID)
    }

    static func members(in sheet: ExpenseSheet, access: IntentSheetAccess) throws -> [SiriSheetMemberEntity] {
        let roster = try SiriSheetMemberRoster(sheet: sheet, access: access)
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        // The settlement screen excludes cached nonvirtual invitees when no share is available.
        return roster.members.filter { person in
            person.isSelf || UserProfileStore.isVirtualRecordName(person.profileID)
                || share?.participants.contains(where: { $0.acceptanceStatus == .accepted && $0.budgetyCanonicalID == person.profileID }) == true
        }
    }

    static func avatar(_ id: String, in sheet: ExpenseSheet) -> Avatar {
        let info = sheet.memberDisplayInfo(for: id)
        return Avatar(name: info.name, colorHex: info.colorHex, photoData: info.photoData, isVirtual: UserProfileStore.isVirtualRecordName(id))
    }

    private static func prepared(sheet: ExpenseSheet, fromID: String, toID: String, amount: Decimal, code: String, date: Date, note: String?, source: Source) -> Prepared {
        Prepared(sheetID: sheet.objectID.uriRepresentation().absoluteString, sheetName: sheet.displayName, sheetSymbol: sheet.displaySymbol,
                 sheetColorHex: sheet.displayColorHex, fromAvatar: avatar(fromID, in: sheet), toAvatar: avatar(toID, in: sheet),
                 amount: amount, currencyCode: code, date: date, note: note, source: source, requestID: UUID(),
                 fromID: fromID, toID: toID, sheetCurrency: sheet.resolvedDefaultCurrencyCode)
    }

    // Two pending confirmations of the same manual payment must not both append a record.
    // Starting a new payment after the first one completed is still supported.
    private static func matchingPayments(in sheet: ExpenseSheet, from: String, to: String, amount: Decimal, currency: String,
                                         on date: Date) -> Set<NSManagedObjectID> {
        let records = sheet.settlements as? Set<SettlementRecord> ?? []
        return Set(records.compactMap { record in
            guard record.fromProfileID == from, record.toProfileID == to, record.amountDecimal == amount,
                  record.resolvedCurrencyCode == currency, let day = record.date,
                  Calendar.current.isDate(day, inSameDayAs: date) else { return nil }
            return record.objectID
        })
    }

    private static func find(_ id: UUID, in sheet: ExpenseSheet, access: IntentSheetAccess) throws -> SettlementRecord? {
        let request = NSFetchRequest<SettlementRecord>(entityName: "SettlementRecord")
        request.predicate = NSPredicate(format: "id == %@ AND sheet == %@", id as CVarArg, sheet)
        request.fetchLimit = 2
        let records = try access.context.fetch(request)
        guard records.count <= 1 else { throw Failure.unavailable }
        return records.first
    }

    private static func snapshot(for sheet: ExpenseSheet) -> Status {
        let result = SettlementCalculator.calculate(for: sheet)
        let sheetID = sheet.objectID.uriRepresentation().absoluteString
        let balances = result.balances.map { Balance(id: $0.profileID, avatar: avatar($0.profileID, in: sheet), amount: $0.amount) }
        let avatars = Dictionary(uniqueKeysWithValues: balances.map { ($0.id, $0.avatar) })
        // A transfer that disappears and later recurs after a payment must have a fresh selection ID.
        // Keep identifiers opaque to Siri and independent of the system's numeric locale.
        let records = sheet.settlements as? Set<SettlementRecord> ?? []
        var historyByMember: [String: [String]] = [:]
        for record in records {
            let id = record.objectID.uriRepresentation().absoluteString
            if let from = record.fromProfileID { historyByMember[from, default: []].append(id) }
            if let to = record.toProfileID { historyByMember[to, default: []].append(id) }
        }
        let proposals = result.transfers.map { item in
            let from = item.fromProfileID, to = item.toProfileID
            let history = Set(historyByMember[from] ?? []).intersection(historyByMember[to] ?? []).sorted()
            let fields = [from, to, result.currencyCode, NSDecimalNumber(decimal: item.amount).stringValue] + history
            let serialized = fields.map { "\($0.utf8.count):" + $0 }.joined()
            let hash = SHA256.hash(data: Data(serialized.utf8)).map { String(format: "%02x", $0) }.joined()
            return Proposal(id: sheetID + "#settlement:" + hash, fromAvatar: avatars[from] ?? avatar(from, in: sheet),
                            toAvatar: avatars[to] ?? avatar(to, in: sheet), amount: item.amount,
                            formattedAmount: CurrencyCatalog.format(item.amount, code: result.currencyCode), fromID: from, toID: to)
        }
        return Status(sheetID: sheetID, sheetName: sheet.displayName, sheetSymbol: sheet.displaySymbol, sheetColorHex: sheet.displayColorHex,
                      currencyCode: result.currencyCode, balances: balances, proposals: proposals,
                      missingRateCurrencies: result.missingRateCurrencies.sorted(), includedExpenseCount: result.includedExpenseCount)
    }
}
#endif

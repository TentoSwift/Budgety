#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, *)
enum SiriTransactionSplitChange: String, AppEnum {
    case unchanged, off, all, selected

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "割り勘の変更"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .unchanged: "変更しない", .off: "割り勘を解除", .all: "全員で割り勘", .selected: "メンバーを指定"
    ]
}

@available(iOS 27.3, *)
@MainActor
enum SiriTransactionEditStore {
    struct Change: Equatable {
        let label: String
        let before: String
        let after: String
    }

    struct Prepared {
        let identifier: String
        let sheetName: String
        let transactionTitle: String
        let changes: [Change]
        let originalReceipt: SiriRecordedTransaction
        fileprivate let sheetIdentifier: String
        fileprivate let original: Snapshot
        fileprivate let request: Request
        fileprivate let selectedMembers: [MemberIdentity]
    }

    fileprivate struct Request {
        let title: String?
        let amount: Double?
        let date: Date?
        let payer: SiriSheetMemberEntity?
        let split: SiriTransactionSplitChange
        let beneficiaries: [SiriSheetMemberEntity]
    }

    // Expense has no revision field. Compare persisted attributes and relationship identities
    // in fresh contexts on either side of confirmation, including fields not being edited.
    fileprivate struct Snapshot: Equatable {
        let attributes: NSDictionary
        let category: NSManagedObjectID?
        let sheet: NSManagedObjectID?
        init(_ row: Expense) {
            attributes = row.committedValues(forKeys: Array(row.entity.attributesByName.keys)) as NSDictionary
            category = row.category?.objectID
            sheet = row.sheet?.objectID
        }
    }

    fileprivate struct MemberIdentity: Equatable {
        let selectionID: String
        let profileID: String
        let localMember: UUID?
        init(_ person: SiriSheetMemberEntity) {
            selectionID = person.id
            profileID = person.profileID
            localMember = person.memberID
        }
    }

    private struct Plan {
        var changes: [Change] = []
        var title: String?
        var amount: Decimal?
        var date: Date?
        var payer: SiriSheetMemberEntity?
        var splitMembers: [SiriSheetMemberEntity]?
        var selectedMembers: [MemberIdentity] = []
    }

    private enum EditError: Error, CustomLocalizedStringResourceConvertible {
        case stale, unchanged
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .stale: "明細またはメンバーが変更されました。もう一度確認してください。"
            case .unchanged: "変更する項目がありません。"
            }
        }
    }

    static func prepare(identifier: String, sheetIdentifier: String, title: String? = nil, amount: Double? = nil,
                        date: Date? = nil, payer: SiriSheetMemberEntity? = nil, split: SiriTransactionSplitChange = .unchanged,
                        beneficiaries: [SiriSheetMemberEntity] = []) throws -> Prepared {
        let request = Request(title: title, amount: amount, date: date, payer: payer, split: split, beneficiaries: beneficiaries)
        let (access, row, sheet) = try target(identifier, in: sheetIdentifier)
        let plan = try plan(request, for: row, sheet: sheet, access: access)
        guard !plan.changes.isEmpty else { throw EditError.unchanged }
        return Prepared(identifier: identifier, sheetName: sheet.displayName,
                        transactionTitle: row.displayTitle.isEmpty ? row.categoryDisplayName : row.displayTitle,
                        changes: plan.changes, originalReceipt: SiriRecordedTransaction(transaction: row, sheet: sheet),
                        sheetIdentifier: sheetIdentifier, original: Snapshot(row),
                        request: request, selectedMembers: plan.selectedMembers)
    }

    static func commit(_ prepared: Prepared) throws -> AddExpenseIntent.RecordedTransaction {
        let (access, row, sheet) = try target(prepared.identifier, in: prepared.sheetIdentifier)
        let title = row.displayTitle.isEmpty ? row.categoryDisplayName : row.displayTitle
        guard Snapshot(row) == prepared.original, sheet.displayName == prepared.sheetName,
              title == prepared.transactionTitle else { throw EditError.stale }
        var updates = try plan(prepared.request, for: row, sheet: sheet, access: access)
        guard !updates.changes.isEmpty, updates.changes == prepared.changes,
              updates.selectedMembers == prepared.selectedMembers else { throw EditError.stale }
        // A newly configured account may have no stored self UUID until it saves for the first time.
        if updates.selectedMembers.contains(where: { $0.profileID.isEmpty }) {
            updates = try plan(prepared.request, for: row, sheet: sheet, access: access, preparingToSave: true)
        }
        if let title = updates.title { row.title = title }
        if let amount = updates.amount {
            row.amount = NSDecimalNumber(decimal: amount)
            if row.generatedFromRuleID == nil {
                row.captureFXSnapshot()
            } else {
                row.fxConvertedAmountDecimal = nil
                row.fxTargetCurrency = nil
            }
        }
        if let date = updates.date { row.date = date }
        if let payer = updates.payer {
            row.payerProfileID = payer.profileID
            row.payerMemberID = payer.memberID
            row.paidBy = nil
        }
        if let members = updates.splitMembers {
            row.beneficiaryIDList = members.map(\.profileID).sorted()
            row.pruneSettledBeneficiaries()
        }
        // The default error merge policy also rejects concurrent writes between this read and save.
        try access.context.save()
        return AddExpenseIntent.RecordedTransaction(transaction: row, sheet: sheet,
                                                    dialog: "明細を変更しました", context: access.context)
    }

    private static func target(_ identifier: String, in sheetIdentifier: String) throws
        -> (IntentSheetAccess, Expense, ExpenseSheet) {
        let container = PersistenceController.shared.container
        let access = try IntentSheetAccess(checking: container.viewContext)
        let sheet = try access.resolve(sheetIdentifier)
        let visible = try access.transactionForDisplay(identifier: identifier)
        guard !visible.hasPersistentChangedValues else { throw EditError.stale }
        guard let row = try access.context.existingObject(with: visible.objectID) as? Expense,
              row.sheet?.objectID == sheet.objectID, container.canUpdateRecord(forManagedObjectWith: row.objectID)
        else { throw AppIntentError.expenseUnavailable }
        return (access, row, sheet)
    }

    private static func plan(_ request: Request, for row: Expense, sheet: ExpenseSheet, access: IntentSheetAccess,
                             preparingToSave: Bool = false) throws -> Plan {
        var plan = Plan()
        if let text = request.title {
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if title != row.displayTitle {
                plan.title = title
                let empty = String(localized: "未設定")
                plan.changes.append(Change(label: String(localized: "タイトル"),
                                           before: row.displayTitle.isEmpty ? empty : row.displayTitle,
                                           after: title.isEmpty ? empty : title))
            }
        }
        if let input = request.amount {
            guard input.isFinite, input > 0 else { throw AppIntentError.invalidAmount }
            let amount = Decimal(input)
            guard !amount.isNaN, amount > 0 else { throw AppIntentError.invalidAmount }
            if amount != row.amountDecimal {
                plan.amount = amount
                let code = row.resolvedCurrencyCode
                let formatted = CurrencyCatalog.format(amount, code: code)
                let roundedEqual = row.formattedAmount == formatted
                plan.changes.append(Change(label: String(localized: "金額"),
                                           before: roundedEqual ? "\(row.amountDecimal) \(code)" : row.formattedAmount,
                                           after: roundedEqual ? "\(amount) \(code)" : formatted))
            }
        }
        if let date = request.date, row.date.map({ !Calendar.current.isDate($0, inSameDayAs: date) }) != false {
            plan.date = date
            plan.changes.append(Change(label: String(localized: "日付"),
                                       before: row.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "未設定"),
                                       after: date.formatted(date: .abbreviated, time: .omitted)))
        }
        guard request.payer != nil || request.split != .unchanged || !request.beneficiaries.isEmpty else { return plan }
        if request.split != .unchanged, row.kind != .expense { throw AppIntentError.incomeCannotSplit }
        let roster = try SiriSheetMemberRoster(sheet: sheet, access: access, preparingToSave: preparingToSave)
        let enablingSplit = request.split == .all || request.split == .selected
        let person: SiriSheetMemberEntity?
        if let selected = request.payer {
            person = try roster.resolve(selected)
        } else if enablingSplit {
            if let id = row.payerProfileID, !id.isEmpty {
                // An old payer outside the current roster cannot settle this new split.
                let localSelf = UserProfileStore.shared.selfMemberID
                guard let existing = roster.members.first(where: {
                    $0.profileID == id || ($0.isSelf && localSelf != nil && UUID(uuidString: id) == localSelf)
                }) else { throw AppIntentError.missingPayer }
                person = existing
            } else {
                // Older default-self recordings can lack a canonical payer until iCloud is configured.
                guard (row.paidBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      row.payerMemberID == nil || row.payerMemberID == UserProfileStore.shared.selfMemberID,
                      let me = roster.members.first(where: \.isSelf) else { throw AppIntentError.missingPayer }
                person = me
            }
        } else {
            person = nil
        }
        if let person {
            plan.selectedMembers.append(MemberIdentity(person))
            let needsPayer = (row.payerProfileID ?? "").isEmpty || (request.payer != nil && person.profileID != row.payerProfileID)
            if needsPayer {
                plan.payer = person
                let oldName = request.payer == nil ? "" : row.displayPaidBy
                plan.changes.append(Change(label: row.kind == .expense ? String(localized: "支払者") : String(localized: "受取者"),
                                           before: oldName.isEmpty ? String(localized: "未選択") : oldName, after: person.name))
            }
        }
        let members: [SiriSheetMemberEntity]
        switch request.split {
        case .unchanged, .off:
            guard request.beneficiaries.isEmpty else { throw AppIntentError.conflictingSplitMembers }
            if request.split == .unchanged { return plan }
            members = []
        case .all, .selected:
            members = try AddExpenseIntent.splitMembers(in: roster, splitAll: request.split == .all,
                                                        beneficiaries: request.beneficiaries)
        }
        plan.selectedMembers += members.map(MemberIdentity.init)
        if Set(members.map(\.profileID)) != Set(row.beneficiaryIDList) {
            plan.splitMembers = members
            let none = String(localized: "割り勘なし")
            let oldNames = row.beneficiaryIDList.map { sheet.memberDisplayInfo(for: $0).name }
            plan.changes.append(Change(label: String(localized: "割り勘"), before: oldNames.isEmpty ? none : oldNames.formatted(.list(type: .and)),
                                       after: members.isEmpty ? none : members.map(\.name).formatted(.list(type: .and))))
        }
        return plan
    }
}
#endif

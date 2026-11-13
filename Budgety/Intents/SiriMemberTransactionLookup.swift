#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CloudKit
import CoreData

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
@MainActor
enum SiriMemberTransactionLookup {
    struct Result {
        let card: SiriMemberCardResult
        let summary: String
    }

    static func search(sheetID: String, memberIdentifier: String, scope: SiriExpenseScope,
                       kind: SiriTransactionSelection, showAll: Bool = false, currency: SiriLedgerCurrency = .init()) throws -> Result {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try access.resolve(sheetID)
        let roster = try SiriSheetMemberRoster(sheet: sheet, access: access)
        guard let member = roster.members.first(where: { $0.id == memberIdentifier }) else { throw AppIntentError.missingPayer }
        let payer = Payer(member: member, roster: roster, sheet: sheet)
        let ledger = try SiriTransactionLedger.read(sheet: sheet, access: access, interval: scope.interval,
                                                    includeExpenses: kind.includesExpenses, includeIncome: kind.includesIncome, allRows: showAll, currency: currency,
                                                    matchesPayer: payer.matches)
        let color: String
        let photo: Data?
        if member.isSelf {
            color = UserProfileStore.shared.avatarBgColorHex ?? "#5B8DEF"
            photo = UserProfileStore.shared.photoData
        } else {
            let info = sheet.memberDisplayInfo(for: member.profileID)
            color = info.colorHex
            photo = info.photoData
        }
        let isVirtual = UserProfileStore.isVirtualRecordName(member.profileID)
        let expenseTotal = kind.includesExpenses ? ledger.expenseTotal : nil
        let incomeTotal = kind.includesIncome ? ledger.incomeTotal : nil
        let card = SiriMemberCardResult(memberName: member.name, memberColorHex: color,
                                        memberPhoto: SiriExpensePayer.thumbnail(from: photo), memberIsVirtual: isVirtual,
                                        sheetName: sheet.displayName, sheetSymbol: sheet.displaySymbol, sheetColorHex: sheet.displayColorHex,
                                        period: currency.periodLabel(scope.label), expenseTotal: expenseTotal, incomeTotal: incomeTotal,
                                        count: ledger.count, rows: ledger.rows)
        card.questionContext = try SiriLedgerQuestionContext(sheetID: sheetID, interval: scope.interval, period: scope.label, kind: kind,
            memberID: memberIdentifier, sourceCurrency: currency.sourceCurrency, targetCurrency: currency.targetCurrency,
            foreignOnly: currency.foreignOnly, grouped: currency.groupByOriginal,
            singleID: ledger.count == 1 ? ledger.rows.first?.expenseIdentifier : nil)
        card.questionContext?.editableTransaction = card.editableTransaction
        card.netTotal = kind == .both ? ledger.netTotal : nil
        let reply = ledger.reply(for: kind, sheetName: sheet.displayName, period: scope.label, member: member.name,
                                 category: nil, name: nil, showAll: showAll)
        return Result(card: card, summary: reply)
    }

    @MainActor
    struct Payer {
        let profileIDs: Set<String>
        let legacyMemberID: UUID?
        let legacyNames: Set<String>
        let legacyRuleNames: [UUID: String]

        init(member: SiriSheetMemberEntity, roster: SiriSheetMemberRoster, sheet: ExpenseSheet) {
            var ids = member.isSelf ? roster.selfProfileIDs : [member.profileID]
            if let local = member.memberID { ids.insert(local.uuidString) }
            if let share = ShareCoordinator.shared.existingShare(for: sheet),
               let person = share.participants.first(where: { $0.budgetyCanonicalID == member.profileID && $0.acceptanceStatus == .accepted }) {
                if let email = person.userIdentity.lookupInfo?.emailAddress { ids.insert("email:" + email) }
                if let phone = person.userIdentity.lookupInfo?.phoneNumber { ids.insert("phone:" + phone) }
            }
            profileIDs = Set(ids.filter { !$0.isEmpty && !UserProfileStore.isSelfPlaceholderRecordName($0) }.map(Self.profileKey))
            legacyMemberID = member.memberID
            legacyNames = roster.uniqueStoredNames(for: member, in: sheet)
            var ruleNames: [UUID: String] = [:]
            for rule in sheet.recurringRules as? Set<RecurringRule> ?? [] {
                if let id = rule.id, let name = rule.paidBy { ruleNames[id] = name }
            }
            legacyRuleNames = ruleNames
        }

        func matches(_ item: LedgerItem) -> Bool {
            switch item {
            case .expense(let row):
                return matches(profile: row.payerProfileID, local: row.payerMemberID, name: row.paidBy)
            case .occurrence(let occurrence):
                return matches(profile: occurrence.payerProfileID, local: nil, name: legacyRuleNames[occurrence.ruleID])
            }
        }

        private func matches(profile: String?, local: UUID?, name: String?) -> Bool {
            if let profile, !profile.isEmpty, !UserProfileStore.isSelfPlaceholderRecordName(profile) {
                return profileIDs.contains(Self.profileKey(profile))
            }
            if let local { return local == legacyMemberID }
            guard let name, !name.isEmpty else { return false }
            return legacyNames.contains(SiriSheetMemberRoster.storedNameKey(name))
        }

        private static func profileKey(_ id: String) -> String {
            if id.lowercased().hasPrefix("email:") { return id.lowercased() }
            return UUID(uuidString: id)?.uuidString ?? id
        }
    }
}
#endif

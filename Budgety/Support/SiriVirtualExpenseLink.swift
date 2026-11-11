#if os(iOS)
import CoreData
import Foundation

@MainActor
enum SiriVirtualExpenseLink {
    enum Target {
        case stored(Expense)
        case virtual(RecurringOccurrence, sheet: ExpenseSheet, rule: RecurringRule)
    }

    private static let separator = "#occurrence/"
    static func identifier(for occurrence: RecurringOccurrence, in sheet: ExpenseSheet) -> String {
        let day = occurrence.date
        return sheet.objectID.uriRepresentation().absoluteString + separator +
            "\(occurrence.ruleID.uuidString)/\(Int64(day.timeIntervalSince1970))/\(civilDay(day))"
    }

    private static func civilDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    static func resolve(_ identifier: String, access: IntentSheetAccess) throws -> Target {
        guard identifier.contains("#") else {
            return .stored(try access.transactionForDisplay(identifier: identifier))
        }
        let parts = identifier.components(separatedBy: separator)
        guard parts.count == 2 else { throw AppIntentError.expenseUnavailable }
        let key = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard key.count == 3, let ruleID = UUID(uuidString: String(key[0])),
              let seconds = Int64(key[1]) else { throw AppIntentError.expenseUnavailable }
        let day = Date(timeIntervalSince1970: TimeInterval(seconds))
        let calendar = Calendar.current
        guard day.compare(.distantPast) != .orderedAscending, day.compare(calendar.startOfDay(for: .now)) != .orderedDescending,
              calendar.startOfDay(for: day) == day, String(key[2]) == civilDay(day)
        else { throw AppIntentError.expenseUnavailable }

        let sheet = try access.resolve(parts[0])
        let rules = (sheet.recurringRules as? Set<RecurringRule> ?? []).filter { $0.id == ruleID }
        guard rules.count <= 1 else { throw AppIntentError.expenseUnavailable }
        var liveRule: RecurringRule?
        if let storedRule = rules.first {
            guard storedRule.kind == .expense, !storedRule.isSkippedDay(day),
                  let rule = try access.viewContext.existingObject(with: storedRule.objectID) as? RecurringRule,
                  !rule.isDeleted, !rule.hasPersistentChangedValues, let sheetInView = rule.sheet,
                  sheetInView.objectID == sheet.objectID, access.allows(sheetInView)
            else { throw AppIntentError.expenseUnavailable }
            liveRule = rule
        }

        func isSlot(_ row: Expense) -> Bool {
            guard row.generatedFromRuleID == ruleID, let scheduled = row.scheduledDate ?? row.date else { return false }
            return calendar.isDate(scheduled, inSameDayAs: day)
        }
        let matches = (sheet.expenses as? Set<Expense> ?? []).filter(isSlot)
        if let row = matches.first {
            guard matches.count == 1, !row.isSkipped, row.kind == .expense else { throw AppIntentError.expenseUnavailable }
            let live = try access.transactionForDisplay(identifier: row.objectID.uriRepresentation().absoluteString)
            guard !live.hasPersistentChangedValues, isSlot(live) else { throw AppIntentError.expenseUnavailable }
            return .stored(live)
        }
        // A local edit can already be materializing or removing this slot in the app.
        guard let liveRule, let liveSheet = liveRule.sheet,
              !(liveSheet.expenses as? Set<Expense> ?? []).contains(where: isSlot),
              let occurrence = RecurringOccurrenceService.virtualOccurrences(for: sheet, in: day...day)
                .first(where: { $0.ruleID == ruleID && $0.date == day && $0.kind == .expense })
        else { throw AppIntentError.expenseUnavailable }
        return .virtual(occurrence, sheet: liveSheet, rule: liveRule)
    }
}
#endif

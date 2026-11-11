#if os(iOS)
import Combine
import CoreData
import ImageIO
import UIKit
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher {
    private let container: NSPersistentCloudKitContainer
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshScheduled = false

    init(container: NSPersistentCloudKitContainer) {
        self.container = container
        let center = NotificationCenter.default
        let coordinator = container.persistentStoreCoordinator

        let saves = center.publisher(for: NSManagedObjectContext.didSaveObjectIDsNotification)
            .filter { notification in
                guard let context = notification.object as? NSManagedObjectContext,
                      context.persistentStoreCoordinator === coordinator else { return false }
                return [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey].contains { key in
                    let ids = notification.userInfo?[key] as? Set<NSManagedObjectID> ?? []
                    return ids.contains { id in
                        ["ExpenseSheet", "Expense", "RecurringRule", "ExpenseCategory", "ParticipantProfile", "Member"].contains(id.entity.name ?? "")
                    }
                }
            }.map { _ in () }.eraseToAnyPublisher()

        let changes = [UIApplication.didBecomeActiveNotification, UIApplication.significantTimeChangeNotification,
                       .expensoStoreReset, .NSPersistentStoreRemoteChange].map { name in
            center.publisher(for: name).map { _ in () }.eraseToAnyPublisher()
        }
        let profileChanges = UserProfileStore.shared.objectWillChange.eraseToAnyPublisher()
        let publicProfiles = PublicProfileSync.shared.$cache.dropFirst().map { _ in () }.eraseToAnyPublisher()
        let rates = FXRatesService.shared.$rates.dropFirst().map { _ in () }.eraseToAnyPublisher()
        Publishers.MergeMany(changes + [saves, rates, profileChanges, publicProfiles])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &subscriptions)
        scheduleRefresh()
    }

    /// Remove the old entry immediately, even if saving the new password later fails.
    static func exclude(_ id: NSManagedObjectID) {
        let uri = id.uriRepresentation().absoluteString
        let sheets = WidgetSheetStore.read().filter { $0.id != uri }
        if WidgetSheetStore.replace(with: sheets) {
            Self.reloadWidgets()
        }
    }

    private static func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSheetStore.kind)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSheetStore.chartKind)
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let sheets = (try? self.snapshots()) ?? []
            if WidgetSheetStore.replace(with: sheets) {
                Self.reloadWidgets()
            }
        }
    }

    private func snapshots() throws -> [WidgetSheetSnapshot] {
        // Read the committed state of both stores, including remote imports that
        // have not yet merged into the UI. Keep all reads at the same generation.
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = container.persistentStoreCoordinator
        try context.setQueryGenerationFrom(.current)
        let request = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)]
        let now = Date.now
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let month = calendar.dateInterval(of: .month, for: today),
              let oldestRecent = calendar.date(byAdding: .day, value: 1 - WidgetLedgerWindow.recentDayCount, to: today),
              let horizon = calendar.date(byAdding: .day, value: 31, to: today) else { return [] }
        let firstDay = oldestRecent.compare(month.start) == .orderedAscending ? oldestRecent : month.start

        return try context.fetch(request).compactMap { sheet in
            let uri = sheet.objectID.uriRepresentation().absoluteString
            // Session unlocks never authorize display on the Home Screen. Treat
            // partial imports and passwords awaiting the legacy migration as protected.
            let uiSheet = container.viewContext.registeredObject(for: sheet.objectID) as? ExpenseSheet
            for candidate in [sheet, uiSheet].compactMap({ $0 }) {
                if candidate.isDeleted || candidate.lockPasswordHash?.isEmpty == false ||
                    candidate.lockPasswordSalt?.isEmpty == false { return nil }
            }
            guard UserDefaults.standard.object(forKey: SheetLockManager.legacyPrefix + uri) == nil else { return nil }
            var snapshot = WidgetSheetSnapshot(id: uri, name: sheet.displayName,
                                               symbol: sheet.displaySymbol, colorHex: sheet.displayColorHex,
                                               monthStart: month.start, expense: 0, income: 0,
                                               currency: sheet.resolvedDefaultCurrencyCode, missingRates: false)
            let window = ledger(for: sheet, days: firstDay...horizon, today: today, calendar: calendar)
            snapshot.ledger = window
            // Retain current values for existing installed versions, sharing the same day calculation.
            guard var current = snapshot.displayed(at: today, calendar: calendar) else { return nil }
            current.ledger = window
            return current
        }
    }
    private func ledger(for sheet: ExpenseSheet, days: ClosedRange<Date>, today: Date, calendar: Calendar) -> WidgetLedgerWindow {
        let saved = ((sheet.expenses as? Set<Expense>) ?? []).compactMap { expense -> LedgerItem? in
            guard !expense.isDeleted, !expense.isSkipped, let date = expense.date,
                  calendar.startOfDay(for: date).compare(days.lowerBound) != .orderedAscending,
                  calendar.startOfDay(for: date).compare(days.upperBound) != .orderedDescending else { return nil }
            return .expense(expense)
        }
        let scheduled = RecurringOccurrenceService.virtualOccurrences(for: sheet, in: days, includeFuture: true,
                                                                      futureHorizon: days.upperBound, calendar: calendar)
        let items = (saved + scheduled.map(LedgerItem.occurrence)).sorted {
            let order = $0.date.compare($1.date)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedDescending
        }
        let target = sheet.resolvedDefaultCurrencyCode
        let backing = VirtualRowBacking()
        lazy var isSolo = !sheet.hasAcceptedOtherMembers()
        var historyRows = 0
        var daysByDate: [Date: WidgetLedgerDay] = [:]
        for item in items {
            let date = calendar.startOfDay(for: item.date)
            if daysByDate[date] == nil { daysByDate[date] = WidgetLedgerDay(date: date) }
            let converted = FXRatesService.shared.convert(item.amountDecimal, from: item.currencyCode, to: target)
            if converted == nil { daysByDate[date]?.missingRates = true }
            if item.kind == .income {
                daysByDate[date]?.income += converted ?? 0
                continue
            }
            daysByDate[date]?.expense += converted ?? 0
            daysByDate[date]?.count += 1
            // Older history can never enter the four visible rows as the timeline advances.
            guard daysByDate[date]!.rows.count < WidgetExpenseRow.limit,
                  date.compare(today) == .orderedDescending || historyRows < WidgetExpenseRow.limit else { continue }
            let expense: Expense
            switch item {
            case .expense(let value): expense = value
            case .occurrence(let value): expense = backing.displayExpense(for: value, sheet: sheet)
            }
            daysByDate[date]?.rows.append(Self.row(for: expense, date: item.date, isSolo: isSolo))
            if date.compare(today) != .orderedDescending { historyRows += 1 }
        }
        return WidgetLedgerWindow(firstDisplayDay: today, lastDisplayDay: days.upperBound, timeZoneID: calendar.timeZone.identifier,
                                  days: daysByDate.values.sorted { $0.date.compare($1.date) == .orderedDescending })
    }

    private static func row(for expense: Expense, date: Date, isSolo: Bool) -> WidgetExpenseRow {
        var row = WidgetExpenseRow(date: date, title: String(expense.displayTitle.prefix(100)),
                                   category: String(expense.categoryDisplayName.prefix(64)), symbol: expense.categorySymbol,
                                   colorHex: expense.resolvedCategory?.displayColorHex ?? "#888888",
                                   amount: expense.amountDecimal, currency: expense.resolvedCurrencyCode)
        guard !(isSolo && expense.isPayerSelf),
              !(expense.payerProfileID ?? "").isEmpty || expense.payerMemberID != nil || !(expense.paidBy ?? "").isEmpty
        else { return row }
        let name = expense.displayPaidBy
        guard !name.isEmpty else { return row }
        row.payerName = String(name.prefix(40))
        row.payerColorHex = expense.resolvedParticipantProfile?.colorHex
            ?? (expense.isPayerSelf ? UserProfileStore.shared.avatarBgColorHex : nil)
            ?? expense.resolvedPayer?.colorHex
        row.payerIsVirtual = UserProfileStore.isVirtualRecordName(expense.payerProfileID ?? "")
        row.payerThumbnail = thumbnail(expense.payerPhotoData)
        return row
    }

    /// Store only an avatar-sized thumbnail. Original photos stay in the app's store.
    private static func thumbnail(_ data: Data?) -> Data? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 40]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let thumbnail = UIImage(cgImage: image).jpegData(compressionQuality: 0.7),
              thumbnail.count <= 3072 else { return nil }
        return thumbnail
    }

}
#endif

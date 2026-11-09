#if os(iOS)
import Combine
import CoreData
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
                    return ids.contains { $0.entity.name == "ExpenseSheet" || $0.entity.name == "Expense" }
                }
            }.map { _ in () }.eraseToAnyPublisher()

        let changes = [UIApplication.didBecomeActiveNotification, UIApplication.significantTimeChangeNotification,
                       .expensoStoreReset, .NSPersistentStoreRemoteChange].map { name in
            center.publisher(for: name).map { _ in () }.eraseToAnyPublisher()
        }
        Publishers.MergeMany(changes + [saves, FXRatesService.shared.$rates.dropFirst().map { _ in () }.eraseToAnyPublisher()])
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
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSheetStore.kind)
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let sheets = (try? self.snapshots()) ?? []
            if WidgetSheetStore.replace(with: sheets) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSheetStore.kind)
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
        guard let month = Calendar.current.dateInterval(of: .month, for: now) else { return [] }

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
            let totals = sheet.convertedMonthlyTotals(month: now)
            return WidgetSheetSnapshot(id: uri, name: sheet.displayName, monthStart: month.start,
                                       expense: totals.expense, income: totals.income,
                                       currency: sheet.resolvedDefaultCurrencyCode,
                                       missingRates: !totals.missing.isEmpty)
        }
    }
}
#endif

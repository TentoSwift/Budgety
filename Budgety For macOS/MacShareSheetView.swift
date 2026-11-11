import AppKit
import CloudKit
import CoreData
import SwiftUI

struct MacSheetSharingButton: NSViewRepresentable {
    let sheet: ExpenseSheet
    let hasParticipants: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(), target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.sheet = sheet
        let label = hasParticipants ? String(localized: "共有メンバー") : String(localized: "シートを共有")
        let symbol = hasParticipants ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    @MainActor
    final class Coordinator: NSObject, NSCloudSharingServiceDelegate {
        var sheet: ExpenseSheet?
        private weak var anchor: NSButton?
        private var service: NSSharingService?

        @objc func share(_ sender: NSButton) {
            guard service == nil, let sheet, let window = sender.window,
                  !sheet.isDeleted, SheetLockManager.shared.isUnlocked(sheet) else { return }
            guard let sharing = NSSharingService(named: .cloudSharing) else {
                NSAlert(error: CocoaError(.featureUnsupported)).beginSheetModal(for: window)
                return
            }
            anchor = sender
            service = sharing
            sharing.delegate = self

            Task {
                do {
                    let provider = try await itemProvider(for: sheet)
                    guard self.sheet === sheet, !sheet.isDeleted, SheetLockManager.shared.isUnlocked(sheet),
                          sender.window === window else { service = nil; return }
                    guard sharing.canPerform(withItems: [provider]) else { throw CocoaError(.featureUnsupported) }
                    sharing.perform(withItems: [provider])
                } catch {
                    service = nil
                    if sender.window === window { await NSAlert(error: error).beginSheetModal(for: window) }
                }
            }
        }

        private func itemProvider(for sheet: ExpenseSheet) async throws -> NSItemProvider {
            let coordinator = ShareCoordinator.shared
            let provider = NSItemProvider()
            provider.suggestedName = sheet.displayName
            let icon = Self.thumbnail
            if let existing = coordinator.existingShare(for: sheet) {
                let share = await coordinator.shareForPresentation(existing, title: sheet.displayName, thumbnail: icon)
                provider.registerCloudKitShare(share, container: PersistenceController.shared.cloudKitContainer())
            } else {
                guard sheet.isOwnedByCurrentUser else { throw ShareError.storeNotReady }
                let id = sheet.objectID
                provider.registerCloudKitShare { completion in
                    Task { @MainActor in
                        do {
                            let share = try await Self.prepareShare(for: id, thumbnail: icon)
                            completion(share, PersistenceController.shared.cloudKitContainer(), nil)
                        } catch {
                            completion(nil, nil, error)
                        }
                    }
                }
            }
            return provider
        }

        private static func prepareShare(for id: NSManagedObjectID, thumbnail: Data?) async throws -> CKShare {
            let context = PersistenceController.shared.container.viewContext
            guard let sheet = try context.existingObject(with: id) as? ExpenseSheet, !sheet.isDeleted,
                  sheet.isOwnedByCurrentUser, SheetLockManager.shared.isUnlocked(sheet) else { throw ShareError.storeNotReady }
            return try await ShareCoordinator.shared.prepareShareLink(for: sheet, title: sheet.displayName, thumbnail: thumbnail).share
        }

        private static let thumbnail: Data? = {
            guard let icon = NSApp.applicationIconImage else { return nil }
            var bounds = NSRect(x: 0, y: 0, width: 120, height: 120)
            guard let cg = icon.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return nil }
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }()

        func anchoringView(for sharingService: NSSharingService, showRelativeTo rect: UnsafeMutablePointer<NSRect>,
                           preferredEdge edge: UnsafeMutablePointer<NSRectEdge>) -> NSView? {
            guard let anchor, anchor.window != nil else { return nil }
            rect.pointee = anchor.bounds
            edge.pointee = .minY
            return anchor
        }

        func options(for cloudKitSharingService: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
            [.allowPrivate, .allowReadWrite]
        }

        func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
            service = nil
            guard let error = error as NSError?,
                  !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError),
                  let window = anchor?.window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }
}

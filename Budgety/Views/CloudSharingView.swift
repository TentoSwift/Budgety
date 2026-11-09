import SwiftUI
import CloudKit
import UIKit

struct CloudSharingView: View {
    @ObservedObject var record: ExpenseSheet
    @Environment(\.dismiss) private var dismiss
    @State private var share: CKShare?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView {
                    Label("共有情報を取得できません", systemImage: "icloud.slash")
                } description: {
                    Text(failure)
                } actions: {
                    Button("再試行") { self.failure = nil; attempt += 1 }
                    Button("閉じる") { dismiss() }
                }
            } else if let share {
                SystemSharingSheet(share: share, title: record.displayName) {
                    failure = $0.localizedDescription
                }
            } else {
                ProgressView("共有情報を読み込み中")
            }
        }
        .task(id: attempt) {
            do {
                let coordinator = ShareCoordinator.shared
                if let existing = coordinator.existingShare(for: record) {
                    share = existing
                } else if record.isOwnedByCurrentUser {
                    share = try await coordinator.prepareShareLink(for: record).share
                } else {
                    throw ShareError.storeNotReady
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

private struct SystemSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let title: String
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(title: title, onFailure: onFailure) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: PersistenceController.shared.cloudKitContainer())
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let title: String
        let onFailure: (Error) -> Void

        init(title: String, onFailure: @escaping (Error) -> Void) {
            self.title = title
            self.onFailure = onFailure
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { title }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onFailure(error)
        }
    }
}

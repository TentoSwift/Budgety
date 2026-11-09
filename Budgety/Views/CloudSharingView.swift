import SwiftUI
import CloudKit
import UIKit

struct CloudSharingView: View {
    @ObservedObject var record: ExpenseSheet
    @Environment(\.dismiss) private var dismiss
    @State private var share: CKShare?
    @State private var failure: String?
    @State private var attempt = 0

    private var sharingTitle: String { "\(record.displayName)\nBudgety" }

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
                SystemSharingSheet(share: share, title: sharingTitle) {
                    failure = $0.localizedDescription
                }
            } else {
                ProgressView("共有情報を読み込み中")
            }
        }
        .task(id: attempt) {
            do {
                let coordinator = ShareCoordinator.shared
                let thumbnail = SharingAppIcon.pngData
                if let existing = coordinator.existingShare(for: record) {
                    share = await coordinator.shareForPresentation(existing, title: sharingTitle, thumbnail: thumbnail)
                } else if record.isOwnedByCurrentUser {
                    share = try await coordinator.prepareShareLink(for: record, title: sharingTitle, thumbnail: thumbnail).share
                } else {
                    throw ShareError.storeNotReady
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

@MainActor
private enum SharingAppIcon {
    static let pngData: Data? = {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let name = (primary["CFBundleIconFiles"] as? [String])?.last,
              let image = UIImage(named: name) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            UIBezierPath(roundedRect: bounds, cornerRadius: 27).addClip()
            image.draw(in: bounds)
        }
    }()
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

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            SharingAppIcon.pngData
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onFailure(error)
        }
    }
}

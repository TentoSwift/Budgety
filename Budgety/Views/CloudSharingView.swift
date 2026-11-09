import SwiftUI
import CloudKit
import UIKit

struct CloudSharingView: View {
    @ObservedObject var record: ExpenseSheet
    @Environment(\.dismiss) private var dismiss
    @State private var share: CKShare?
    @State private var failure: String?
    @State private var attempt = 0

    @State private var isManaging = false

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
            } else if let share, isManaging {
                SystemSharingSheet(share: share, title: record.displayName) {
                    failure = $0.localizedDescription
                }
            } else if let share {
                SharingOverview(title: record.displayName,
                                participantCount: share.participants.count,
                                manage: { isManaging = true })
            } else {
                ProgressView("共有情報を読み込み中")
            }
        }
        .presentationDetents(isManaging ? [.large] : [.medium, .large])
        .task(id: attempt) {
            do {
                let coordinator = ShareCoordinator.shared
                let thumbnail = SharingAppIcon.pngData
                if let existing = coordinator.existingShare(for: record) {
                    share = await coordinator.shareForPresentation(existing, title: record.displayName, thumbnail: thumbnail)
                } else if record.isOwnedByCurrentUser {
                    share = try await coordinator.prepareShareLink(for: record, title: record.displayName, thumbnail: thumbnail).share
                } else {
                    throw ShareError.storeNotReady
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

private struct SharingOverview: View {
    let title: String
    let participantCount: Int
    let manage: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 5) {
                        if let icon = SharingAppIcon.image {
                            Image(uiImage: icon)
                                .resizable()
                                .frame(width: 64, height: 64)
                                .accessibilityHidden(true)
                                .padding(.bottom, 4)
                        }
                        Text(verbatim: title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(verbatim: "Budgety")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    if participantCount > 0 {
                        Label("\(participantCount) 人の参加者", systemImage: "person.2")
                    }
                    Button("共有を管理", action: manage)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

@MainActor
private enum SharingAppIcon {
    static let image: UIImage? = {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let name = (primary["CFBundleIconFiles"] as? [String])?.last,
              let image = UIImage(named: name) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            UIBezierPath(roundedRect: bounds, cornerRadius: 27).addClip()
            image.draw(in: bounds)
        }
    }()

    static let pngData = image?.pngData()
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

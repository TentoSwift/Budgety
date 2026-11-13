#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import Foundation
import ImageIO
import UniformTypeIdentifiers

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpensePayer {
    let name: String
    let colorHex: String
    let photo: IntentFile?

    @MainActor
    static func snapshot(for expense: Expense, isSoloSheet: Bool) -> Self? {
        let savedID = expense.payerProfileID ?? ""
        let profileID = UserProfileStore.isSelfPlaceholderRecordName(savedID) ? "" : savedID
        let savedName = (expense.paidBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileID.isEmpty || expense.payerMemberID != nil || !savedName.isEmpty else { return nil }

        let store = UserProfileStore.shared
        let legacyID = profileID.isEmpty ? expense.payerMemberID : UUID(uuidString: profileID)
        let matchesSelfEmail = store.selfEmail.map {
            !$0.isEmpty && profileID.lowercased() == "email:" + $0.lowercased()
        } ?? false
        let isSelf = expense.isPayerSelf || matchesSelfEmail || (legacyID != nil && legacyID == store.selfMemberID)
        guard !(isSoloSheet && isSelf) else { return nil }

        let member: Member?
        if let legacyID, let context = expense.managedObjectContext {
            let request = NSFetchRequest<Member>(entityName: "Member")
            request.predicate = NSPredicate(format: "id == %@", legacyID as CVarArg)
            request.fetchLimit = 1
            member = try? context.fetch(request).first
        } else if !profileID.isEmpty {
            member = expense.resolvedPayer
        } else {
            member = nil
        }
        let recordName = profileID.isEmpty ? (member?.recordName ?? "") : profileID
        let participants = expense.sheet?.participantProfiles as? Set<ParticipantProfile>
        let participant = recordName.isEmpty ? nil : participants?.first { $0.recordName == recordName }
        let cached = PublicProfileSync.shared.cachedProfile(for: recordName)

        // Resolve the same display sources as the expense list, using only local snapshots.
        // A legacy free-text payer can supply a name, but cannot identify someone's photo.
        let name = [
            isSelf ? store.resolvedDisplayName : nil,
            cached?.displayName,
            expense.resolvedSharedParticipantName(includingEmail: false),
            participant?.displayName,
            member?.name,
            savedName
        ].compactMap { $0 }.first { !$0.isEmpty } ?? String(localized: "メンバー")
        let color = participant?.colorHex ?? (isSelf ? store.avatarBgColorHex : nil)
            ?? member?.colorHex ?? "#8E8E93"
        let photoData = participant?.photoData ?? (isSelf ? store.photoData : nil)
            ?? cached?.photoData ?? member?.photoData
        return Self(name: name, colorHex: color, photo: thumbnail(from: photoData))
    }

    static func thumbnail(from data: Data?) -> IntentFile? {
        guard let data, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 72
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return IntentFile(data: bytes as Data, filename: "avatar.png", type: .png)
    }
}
#endif

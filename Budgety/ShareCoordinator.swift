//
//  ShareCoordinator.swift
//  Expenso
//

import Foundation
import CoreData
import CloudKit
import os

enum ShareError: LocalizedError {
    case storeNotReady
    case urlNotAvailable
    case userNotFound

    var errorDescription: String? {
        switch self {
        case .storeNotReady: "iCloud ストアの初期化が完了していません。少し待ってから再度お試しください。"
        case .urlNotAvailable: "招待リンクを取得できませんでした。iCloud にサインインしているか確認してください。"
        case .userNotFound: "そのメールアドレスに紐づく iCloud アカウントが見つかりませんでした。Apple ID に登録されているメールアドレスをご確認ください。"
        }
    }
}

struct InvitationResult {
    let share: CKShare
    let url: URL
    let participant: CKShare.Participant
}

final class ShareCoordinator {
    static let shared = ShareCoordinator()

    @MainActor
    func invite(email: String, permission: CKShare.ParticipantPermission, to sheet: ExpenseSheet) async throws -> InvitationResult {
        let pc = PersistenceController.shared
        let container = pc.container
        let cloudKitContainer = pc.cloudKitContainer()

        let share = try await getOrCreateShare(for: sheet)

        let participant = try await fetchParticipant(email: email, container: cloudKitContainer)
        participant.permission = permission
        participant.role = .privateUser

        let alreadyAdded = share.participants.contains { existing in
            existing.userIdentity.userRecordID == participant.userIdentity.userRecordID
        }
        if !alreadyAdded {
            share.addParticipant(participant)
        } else {
            for existing in share.participants
                where existing.userIdentity.userRecordID == participant.userIdentity.userRecordID {
                existing.permission = permission
            }
        }

        guard let store = pc.privateStore else { throw ShareError.storeNotReady }
        try await container.persistUpdatedShare(share, in: store)

        guard let url = share.url else { throw ShareError.urlNotAvailable }
        return InvitationResult(share: share, url: url, participant: participant)
    }

    @MainActor
    func existingShare(for sheet: ExpenseSheet) -> CKShare? {
        let container = PersistenceController.shared.container
        return (try? container.fetchShares(matching: [sheet.objectID]))?[sheet.objectID]
    }

    /// CKShare を作成 (or 取得) して URL を返す。
    /// `publicPermission` は **必ず `.none`** にしてあり、参加できるのは
    /// `addParticipant` で明示的に招待された Apple ID のみ。
    /// 既存の share が誤って `.readWrite` 等になっていた場合もここで下げる。
    @MainActor
    func prepareShareLink(for sheet: ExpenseSheet) async throws -> (share: CKShare, url: URL) {
        let share = try await getOrCreateShare(for: sheet)
        if share.publicPermission != .none {
            share.publicPermission = .none
        }
        let pc = PersistenceController.shared
        guard let store = pc.privateStore else { throw ShareError.storeNotReady }
        try await pc.container.persistUpdatedShare(share, in: store)
        guard let url = share.url else { throw ShareError.urlNotAvailable }
        return (share, url)
    }

    @MainActor
    func remove(participant: CKShare.Participant, from share: CKShare) async throws {
        share.removeParticipant(participant)
        let pc = PersistenceController.shared
        guard let store = pc.privateStore else { throw ShareError.storeNotReady }
        try await pc.container.persistUpdatedShare(share, in: store)
    }

    /// 参加者として共有シートから退出する。CloudKit Sharing zone をローカルでだけ purge し、
    /// オーナーや他の参加者の側のデータには影響を与えない。
    /// (ctx.delete(record) を使うと共有レコードの削除としてオーナーにも伝搬してしまう)
    @MainActor
    func leaveSharedSheet(_ sheet: ExpenseSheet) async throws {
        let pc = PersistenceController.shared
        guard let sharedStore = pc.sharedStore else { throw ShareError.storeNotReady }

        // シートの CKShare から zoneID を取得
        let zoneID: CKRecordZone.ID? = {
            if let share = existingShare(for: sheet) {
                return share.recordID.zoneID
            }
            // CKShare がローカルに無い場合 (rare) は ObjectID から推測
            return nil
        }()

        guard let zoneID else { throw ShareError.storeNotReady }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.container.purgeObjectsAndRecordsInZone(with: zoneID, in: sharedStore) { _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
        // purgeObjectsAndRecordsInZone は持続ストアから記録を削除するが、viewContext に
        // キャッシュされた ExpenseSheet などの管理オブジェクトはそのまま残り、SheetListView
        // の @FetchRequest が再起動まで該当シートを表示し続けることがある。
        // 明示的にメモリキャッシュをリフレッシュして @FetchRequest を即時更新させる。
        pc.container.viewContext.refreshAllObjects()
    }

    /// 自分が所有する CKShare のうち、参加者がいる/公開リンクが有効なものが残っているか。
    /// Premium が切れているのに共有が生きている検知用。
    @MainActor
    func hasActiveOwnedShares() async -> Bool {
        let pc = PersistenceController.shared
        guard let store = pc.privateStore else { return false }
        guard let shares = try? pc.container.fetchShares(in: store) else { return false }
        return shares.contains { share in
            let hasOthers = share.participants.contains(where: { $0.role != .owner })
            let isPublic = share.publicPermission != .none
            return hasOthers || isPublic
        }
    }

    /// オーナーが課金を失った時に、Private ストアにある自分が所有する全 CKShare から
    /// 参加者全員を削除し、公開リンクも無効化して、共有を実質的に解除する。
    /// (CKShare レコード自体は CloudKit 側に残るが、参加者ゼロ + 公開権限無しで誰もアクセスできない)
    /// - Returns: 全 share の更新が成功したら `true`。1 つでも失敗したら `false`
    ///   (PurchaseManager がリトライするためのフラグを残す)
    private static let log = Logger(subsystem: "com.tento.Expenso", category: "share")

    @MainActor
    @discardableResult
    func revokeAllOwnedShares() async -> Bool {
        let pc = PersistenceController.shared
        guard let store = pc.privateStore else {
            Self.log.error("revokeAllOwnedShares: privateStore is nil")
            return false
        }
        let shares: [CKShare]
        do {
            shares = try pc.container.fetchShares(in: store)
        } catch {
            Self.log.error("revokeAllOwnedShares: fetchShares failed: \(error.localizedDescription)")
            return false
        }
        Self.log.debug("revokeAllOwnedShares: found \(shares.count) shares")

        var allSucceeded = true
        for share in shares {
            var didChange = false
            let nonOwners = share.participants.filter { $0.role != .owner }
            Self.log.debug("share \(share.recordID.recordName): \(nonOwners.count) non-owner participants, publicPermission=\(String(describing: share.publicPermission.rawValue))")

            for participant in nonOwners {
                share.removeParticipant(participant)
                didChange = true
            }
            if share.publicPermission != .none {
                share.publicPermission = .none
                didChange = true
            }
            guard didChange else {
                Self.log.debug("share \(share.recordID.recordName): no change, skip")
                continue
            }
            do {
                try await pc.container.persistUpdatedShare(share, in: store)
                Self.log.debug("share \(share.recordID.recordName): persistUpdatedShare ok")
            } catch {
                Self.log.error("share \(share.recordID.recordName): persistUpdatedShare failed: \(error.localizedDescription)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    @MainActor
    private func getOrCreateShare(for sheet: ExpenseSheet) async throws -> CKShare {
        let container = PersistenceController.shared.container
        if let existing = try? container.fetchShares(matching: [sheet.objectID])[sheet.objectID] {
            return existing
        }
        let result = try await container.share([sheet], to: nil)
        let share = result.1
        share[CKShare.SystemFieldKey.title] = "Budgety: \(sheet.displayName)" as CKRecordValue
        share.publicPermission = .none
        return share
    }

    private func fetchParticipant(email: String, container: CKContainer) async throws -> CKShare.Participant {
        let lookupInfo = CKUserIdentity.LookupInfo(emailAddress: email)
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [lookupInfo])
            operation.qualityOfService = .userInitiated
            var found: CKShare.Participant?
            var lastError: Error?
            operation.perShareParticipantResultBlock = { _, result in
                switch result {
                case .success(let p): found = p
                case .failure(let e): lastError = e
                }
            }
            operation.fetchShareParticipantsResultBlock = { result in
                if case .failure(let err) = result {
                    continuation.resume(throwing: err)
                    return
                }
                if let participant = found {
                    continuation.resume(returning: participant)
                } else {
                    continuation.resume(throwing: lastError ?? ShareError.userNotFound)
                }
            }
            container.add(operation)
        }
    }
}

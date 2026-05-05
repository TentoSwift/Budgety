//
//  UserProfileStore.swift
//  Expenso
//
//  ユーザーのアバター画像 (写真 or Memoji 合成) と表示名を端末/アカウント単位で保持する。
//  シートとは独立。CloudKit Public DB にも同期して、共有先からも見えるようにする。
//

import Foundation
import SwiftUI
import Combine
import CoreData
import CloudKit

@MainActor
final class UserProfileStore: ObservableObject {
    static let shared = UserProfileStore()

    private enum Keys {
        static let displayName       = "userProfile.displayName"
        static let avatarBgColorHex  = "userProfile.avatarBgColorHex"
        static let selfMemberID      = "userProfile.selfMemberID"
    }
    private static let photoFileName = "userProfile.photo.jpg"

    @Published var displayName: String {
        didSet {
            UserDefaults.standard.set(displayName, forKey: Keys.displayName)
            UserDefaults.standard.set(displayName, forKey: "displayName") // 後方互換
        }
    }

    /// Memoji エディタで選択した背景色 (Memoji 経路で使う)。
    @Published var avatarBgColorHex: String? {
        didSet { UserDefaults.standard.set(avatarBgColorHex, forKey: Keys.avatarBgColorHex) }
    }

    /// アバター画像 (JPEG)。写真選択 or Memoji 合成の結果。
    /// `Application Support/userProfile.photo.jpg` に保存。
    @Published var photoData: Data? {
        didSet { writePhotoToDisk() }
    }

    @Published private(set) var selfMemberID: UUID? {
        didSet {
            UserDefaults.standard.set(selfMemberID?.uuidString, forKey: Keys.selfMemberID)
        }
    }

    /// アバター背景色。SwiftUI から使うために Color 化。未設定時は青。
    var bgColor: Color { Color(hex: avatarBgColorHex ?? "#5B8DEF") ?? .blue }

    var resolvedDisplayName: String {
        displayName.isEmpty ? "自分" : displayName
    }

    private init() {
        let ud = UserDefaults.standard
        self.displayName = ud.string(forKey: Keys.displayName)
            ?? ud.string(forKey: "displayName")
            ?? ""
        self.avatarBgColorHex = ud.string(forKey: Keys.avatarBgColorHex)
        if let str = ud.string(forKey: Keys.selfMemberID), let id = UUID(uuidString: str) {
            self.selfMemberID = id
        } else {
            self.selfMemberID = nil
        }
        self.photoData = Self.readPhotoFromDisk()
    }

    // MARK: - Local file helpers

    private static var photoURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent(photoFileName)
    }

    private static func readPhotoFromDisk() -> Data? {
        try? Data(contentsOf: photoURL)
    }

    private func writePhotoToDisk() {
        let url = Self.photoURL
        if let data = photoData {
            try? data.write(to: url, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Self Member sync

    /// Settings 編集後に呼ぶ。selfMemberID に対応する Member エンティティを
    /// 作成または更新し、自分が払った Private ストアの過去支出の paidBy も新しい名前に追従させる
    /// (`Expense.paidBy` は文字列フリーズなので、ここで一括 rename しないと過去ログのアバターが
    /// プロフィール変更後に解決できなくなる)。
    func applyToSelfMember(in ctx: NSManagedObjectContext) {
        let resolvedID: UUID
        if let id = selfMemberID {
            resolvedID = id
        } else {
            resolvedID = UUID()
            selfMemberID = resolvedID
        }

        let req = NSFetchRequest<Member>(entityName: "Member")
        req.predicate = NSPredicate(format: "id == %@", resolvedID as CVarArg)
        req.fetchLimit = 1
        let member: Member
        let oldName: String?
        if let existing = (try? ctx.fetch(req))?.first {
            member = existing
            oldName = existing.name
        } else {
            // 旧スキーマからの移行: 名前一致の既存メンバーを再利用
            let nameReq = NSFetchRequest<Member>(entityName: "Member")
            nameReq.predicate = NSPredicate(format: "name == %@", resolvedDisplayName)
            nameReq.sortDescriptors = [NSSortDescriptor(keyPath: \Member.createdAt, ascending: true)]
            nameReq.fetchLimit = 1
            if let nameMatch = (try? ctx.fetch(nameReq))?.first {
                member = nameMatch
                member.id = resolvedID
                oldName = nameMatch.name
            } else {
                member = Member(context: ctx)
                member.id = resolvedID
                member.createdAt = .now
                member.sortOrder = 0
                oldName = nil
            }
        }

        let newName = resolvedDisplayName
        member.name      = newName
        member.colorHex  = avatarBgColorHex ?? "#5B8DEF"
        member.photoData = photoData

        // 名前が変わったら、自分が払った Private ストアの過去支出の paidBy を追従更新
        if let old = oldName, !old.isEmpty, old != newName {
            renamePaidByInPrivateStore(from: old, to: newName, in: ctx)
        }

        try? ctx.save()
    }

    /// `paidBy == old` の Expense のうち、Private ストアにあるもの (= 自分が所有するもの) だけを
    /// `paidBy = new` に書き換える。Shared ストアの支出は他アカウントが所有するため触らない。
    private func renamePaidByInPrivateStore(from old: String, to new: String, in ctx: NSManagedObjectContext) {
        let pc = PersistenceController.shared
        guard let coord = ctx.persistentStoreCoordinator,
              let privateStore = pc.privateStore else { return }

        let req = NSFetchRequest<Expense>(entityName: "Expense")
        req.predicate = NSPredicate(format: "paidBy == %@", old)
        guard let expenses = try? ctx.fetch(req), !expenses.isEmpty else { return }

        for e in expenses {
            guard let store = coord.persistentStore(for: e.objectID.uriRepresentation()),
                  store == privateStore else { continue }
            e.paidBy = new
        }
    }

    func ensureSelfMemberExists(in ctx: NSManagedObjectContext) {
        if selfMemberID != nil { return }
        applyToSelfMember(in: ctx)
    }

    // MARK: - CloudKit Public DB sync

    private static let containerID = "iCloud.com.tento.Expenso"
    private static let recordType = "UserProfile"

    /// 自分のプロフィールを CloudKit Public DB に保存する。
    /// recordName 形式: `profile_<userRecordName>` で他デバイスからフェッチ可能。
    func saveToCloudKit() async {
        let container = CKContainer(identifier: Self.containerID)
        do {
            let userID = try await container.userRecordID()
            let profileID = CKRecord.ID(recordName: "profile_\(userID.recordName)")
            let record: CKRecord
            if let existing = try? await container.publicCloudDatabase.record(for: profileID),
               existing.recordType == Self.recordType {
                record = existing
            } else {
                record = CKRecord(recordType: Self.recordType, recordID: profileID)
            }
            record["displayName"] = resolvedDisplayName as CKRecordValue
            record["avatarBgColorHex"] = (avatarBgColorHex ?? "#5B8DEF") as CKRecordValue

            // 写真は CKAsset として保存。一時ファイルにコピーしてから渡す
            if let data = photoData {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("expenso_profile_\(UUID().uuidString).jpg")
                try data.write(to: tmp, options: [.atomic])
                record["photo"] = CKAsset(fileURL: tmp)
            } else {
                record["photo"] = nil
            }
            _ = try await container.publicCloudDatabase.save(record)
        } catch {
            // 失敗時はサイレント (オフライン等)
        }
    }

    /// 起動時に Public DB から自分のプロフィールを取得して、ローカルが未設定の場合に反映する。
    func refreshFromCloudKit() async {
        let container = CKContainer(identifier: Self.containerID)
        do {
            let userID = try await container.userRecordID()
            let profileID = CKRecord.ID(recordName: "profile_\(userID.recordName)")
            guard let record = try? await container.publicCloudDatabase.record(for: profileID),
                  record.recordType == Self.recordType else { return }
            await MainActor.run {
                if displayName.isEmpty, let n = record["displayName"] as? String, !n.isEmpty {
                    displayName = n
                }
                if avatarBgColorHex == nil, let c = record["avatarBgColorHex"] as? String, !c.isEmpty {
                    avatarBgColorHex = c
                }
                if photoData == nil,
                   let asset = record["photo"] as? CKAsset,
                   let url = asset.fileURL,
                   let data = try? Data(contentsOf: url) {
                    photoData = data
                }
            }
        } catch {
            // 失敗時はローカルのまま続行
        }
    }
}

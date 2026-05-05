//
//  UserProfileStore.swift
//  Expenso
//
//  ユーザーのアバター画像 (写真 or Memoji 合成) と表示名をローカルに保持。
//  Public DB は使わず、共有相手への可視化は各 ExpenseSheet 配下の
//  ParticipantProfile レコード経由で行う (CloudKit Sharing 経由で同期)。
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
        static let userRecordName    = "userProfile.userRecordName"
    }
    private static let photoFileName = "userProfile.photo.jpg"
    private static let containerID = "iCloud.com.tento.Expenso"

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
    @Published var photoData: Data? {
        didSet { writePhotoToDisk() }
    }

    @Published private(set) var selfMemberID: UUID? {
        didSet {
            UserDefaults.standard.set(selfMemberID?.uuidString, forKey: Keys.selfMemberID)
        }
    }

    /// 自分の CKUserIdentity recordName をキャッシュ。ParticipantProfile の同一性キー。
    @Published private(set) var userRecordName: String? {
        didSet { UserDefaults.standard.set(userRecordName, forKey: Keys.userRecordName) }
    }

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
        self.userRecordName = ud.string(forKey: Keys.userRecordName)
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

    // MARK: - User record name fetch

    /// 自分の CKUserIdentity.recordName を取得しキャッシュ。初回起動時に必要。
    func ensureUserRecordNameLoaded() async {
        if let existing = userRecordName, !existing.isEmpty { return }
        let container = CKContainer(identifier: Self.containerID)
        if let id = try? await container.userRecordID() {
            userRecordName = id.recordName
        }
    }

    // MARK: - Self Member sync (for paidBy resolution in Private sheets)

    /// 自分の Member を CK userRecordName で検索する。同一アカウントの全デバイスで一致。
    /// recordName が無い場合は selfMemberID (UserDefaults) → name の順でフォールバック。
    private func findOrCreateSelfMember(in ctx: NSManagedObjectContext) -> Member? {
        // 1) recordName 一致 (cross-device 安定)
        if let rn = userRecordName, !rn.isEmpty {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "recordName == %@", rn)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first {
                return m
            }
        }
        // 2) selfMemberID 一致 (legacy / 同端末内で一意)
        if let id = selfMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first {
                return m
            }
        }
        // 3) name 一致 (旧スキーマからの移行)
        if !displayName.isEmpty {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "name == %@", resolvedDisplayName)
            req.sortDescriptors = [NSSortDescriptor(keyPath: \Member.createdAt, ascending: true)]
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first {
                return m
            }
        }
        return nil
    }

    /// Settings 編集後に呼ぶ。自分の Member を更新 (無ければ作成)し、
    /// 自分が払った Private ストアの過去支出の paidBy も追従更新する。
    /// 識別子: Member.recordName (= userRecordName) を主、id (UUID) を副。
    func applyToSelfMember(in ctx: NSManagedObjectContext) {
        let member: Member
        let oldName: String?

        if let existing = findOrCreateSelfMember(in: ctx) {
            member = existing
            oldName = existing.name
        } else {
            member = Member(context: ctx)
            member.id = UUID()
            member.createdAt = .now
            member.sortOrder = 0
            oldName = nil
        }

        // recordName を必ず埋める (cross-device 識別キー)
        if let rn = userRecordName, !rn.isEmpty {
            member.recordName = rn
        }
        // selfMemberID キャッシュも合わせる
        if let mid = member.id {
            selfMemberID = mid
        }

        let newName = resolvedDisplayName
        member.name      = newName
        member.colorHex  = avatarBgColorHex ?? "#5B8DEF"
        member.photoData = photoData

        if let old = oldName, !old.isEmpty, old != newName {
            renamePaidByInPrivateStore(from: old, to: newName, in: ctx)
        }

        try? ctx.save()
    }

    /// CloudKit 同期で来た自分の Member の値をローカルに取り込む。
    /// 同一アカウント別デバイス間でプロフィールを一致させるため、**常に Member を正** とし
    /// `UserProfileStore` のキャッシュを Member の値で上書きする。編集は必ず
    /// `applyToSelfMember` を通って Member に書き、その後 sync で他デバイスへ伝搬する設計。
    func syncFromSelfMember(in ctx: NSManagedObjectContext) {
        guard let member = findOrCreateSelfMember(in: ctx) else { return }

        if let mid = member.id, mid != selfMemberID {
            selfMemberID = mid
        }
        if let n = member.name, !n.isEmpty, displayName != n {
            displayName = n
        }
        if let c = member.colorHex, !c.isEmpty, avatarBgColorHex != c {
            avatarBgColorHex = c
        }
        if photoData != member.photoData {
            photoData = member.photoData
        }
        // recordName が未設定なら今のうちに埋める (旧 Member の救済)
        if (member.recordName ?? "").isEmpty,
           let rn = userRecordName, !rn.isEmpty {
            member.recordName = rn
            try? ctx.save()
        }
    }

    private func renamePaidByInPrivateStore(from old: String, to new: String, in ctx: NSManagedObjectContext) {
        let pc = PersistenceController.shared
        guard let privateStore = pc.privateStore else { return }

        let req = NSFetchRequest<Expense>(entityName: "Expense")
        req.predicate = NSPredicate(format: "paidBy == %@", old)
        guard let expenses = try? ctx.fetch(req), !expenses.isEmpty else { return }

        for e in expenses {
            guard let store = e.objectID.persistentStore, store == privateStore else { continue }
            e.paidBy = new
        }
    }

    func ensureSelfMemberExists(in ctx: NSManagedObjectContext) {
        if selfMemberID != nil { return }
        applyToSelfMember(in: ctx)
    }

    // MARK: - ParticipantProfile propagation (cross-account visibility)

    /// 自分のプロフィールを、参加している全シート (Private + Shared) の `participantProfiles` に
    /// ParticipantProfile レコードとして書き込む。CKShare 経由で他の参加者にも同期される。
    /// - Parameter context: 操作するコンテキスト (通常 viewContext)
    func propagateProfile(in ctx: NSManagedObjectContext) {
        guard let recordName = userRecordName, !recordName.isEmpty else { return }

        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        guard let sheets = try? ctx.fetch(sheetReq) else { return }

        let now = Date()
        let newName = resolvedDisplayName
        let newColor = avatarBgColorHex ?? "#5B8DEF"

        for sheet in sheets {
            // NSManagedObjectID.persistentStore で直接取る
            // (coord.persistentStore(for:) はファイル URL 用なので uriRepresentation を渡しても nil)
            guard let sheetStore = sheet.objectID.persistentStore else { continue }

            let existing: ParticipantProfile? = (sheet.participantProfiles as? Set<ParticipantProfile>)?
                .first(where: { $0.recordName == recordName })

            let profile: ParticipantProfile
            if let existing {
                profile = existing
            } else {
                profile = ParticipantProfile(context: ctx)
                ctx.assign(profile, to: sheetStore)
                profile.recordName = recordName
                profile.sheet = sheet
            }
            profile.displayName = newName
            profile.colorHex = newColor
            profile.photoData = photoData
            profile.updatedAt = now
        }

        try? ctx.save()
    }

    /// 1 シートだけプロフィールを書き込む (支出追加時など、特定シートだけ更新する用途)。
    func ensureProfile(in sheet: ExpenseSheet, ctx: NSManagedObjectContext) {
        guard let recordName = userRecordName, !recordName.isEmpty else { return }
        guard let sheetStore = sheet.objectID.persistentStore else { return }

        let existing = (sheet.participantProfiles as? Set<ParticipantProfile>)?
            .first(where: { $0.recordName == recordName })

        let profile: ParticipantProfile
        if let existing {
            profile = existing
        } else {
            profile = ParticipantProfile(context: ctx)
            ctx.assign(profile, to: sheetStore)
            profile.recordName = recordName
            profile.sheet = sheet
        }
        profile.displayName = resolvedDisplayName
        profile.colorHex = avatarBgColorHex ?? "#5B8DEF"
        profile.photoData = photoData
        profile.updatedAt = .now
    }
}

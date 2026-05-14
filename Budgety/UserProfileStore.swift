//
//  UserProfileStore.swift
//  Expenso
//
//  ユーザーのプロフィール (名前 / アバター画像 / 背景色) をローカルに保持するキャッシュ。
//  - 同一アカウント別端末との同期は **ParticipantProfile** (各シート配下) を経由する。
//    `propagateProfile` で全シートの PP に書き込み、CloudKit (Private DB / Shared)
//    自動同期で他端末に届く。
//  - 起動時 / 前面化時に `hydrateFromParticipantProfile` を呼び、新しい PP が来ていれば
//    ローカルキャッシュを更新する。
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
        static let displayName        = "userProfile.displayName"
        static let avatarBgColorHex   = "userProfile.avatarBgColorHex"
        static let selfMemberID       = "userProfile.selfMemberID"
        static let userRecordName     = "userProfile.userRecordName"
        /// ローカルプロフィールの最終更新時刻。ParticipantProfile.updatedAt との LWW 比較に使う。
        static let profileUpdatedAt   = "userProfile.profileUpdatedAt"
    }
    private static let photoFileName = "userProfile.photo.jpg"
    private static let containerID = "iCloud.com.tento.budgety"

    @Published var displayName: String {
        didSet {
            UserDefaults.standard.set(displayName, forKey: Keys.displayName)
            UserDefaults.standard.set(displayName, forKey: "displayName") // 後方互換
        }
    }

    /// Memoji 等で選択した背景色 (アバター JPEG が無い時の塗りつぶし色としても使う)。
    @Published var avatarBgColorHex: String? {
        didSet { UserDefaults.standard.set(avatarBgColorHex, forKey: Keys.avatarBgColorHex) }
    }

    /// アバター画像 (JPEG)。写真選択 or Memoji 合成の結果。
    @Published var photoData: Data? {
        didSet { writePhotoToDisk() }
    }

    /// MemberPicker で「自分」をハイライトする用のローカル Member.id キャッシュ。
    /// cross-device 同期キーではなく、単に同端末でどの Member を「自分」として表示するかの目印。
    @Published private(set) var selfMemberID: UUID? {
        didSet {
            UserDefaults.standard.set(selfMemberID?.uuidString, forKey: Keys.selfMemberID)
        }
    }

    /// 自分の CKUserIdentity recordName をキャッシュ。ParticipantProfile の同一性キー。
    @Published private(set) var userRecordName: String? {
        didSet { UserDefaults.standard.set(userRecordName, forKey: Keys.userRecordName) }
    }

    /// ローカルプロフィールの最終更新時刻。
    /// `propagateProfile` 成功時に更新し、`hydrateFromParticipantProfile` で PP の updatedAt と比較する。
    @Published private(set) var profileUpdatedAt: Date? {
        didSet { UserDefaults.standard.set(profileUpdatedAt, forKey: Keys.profileUpdatedAt) }
    }

    var bgColor: Color { Color(hex: avatarBgColorHex ?? "#5B8DEF") ?? .blue }

    var resolvedDisplayName: String {
        displayName.isEmpty ? "自分" : displayName
    }

    /// プロフィールが未入力の状態か (= 初回シート作成時にプロフィール設定 UI を出す判定に使う)。
    var isEmpty: Bool {
        displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && photoData == nil
            && (avatarBgColorHex ?? "").isEmpty
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
        self.profileUpdatedAt = ud.object(forKey: Keys.profileUpdatedAt) as? Date
        self.photoData = Self.readPhotoFromDisk()
    }

    /// 「全データ削除」用: UserProfileStore のローカル状態を完全リセットする。
    /// displayName / photoData / avatarBgColorHex / selfMemberID / userRecordName /
    /// profileUpdatedAt を空に戻し、保存済みの photo.jpg ファイルも削除する。
    func resetAll() {
        displayName = ""
        avatarBgColorHex = nil
        photoData = nil      // setter が JPEG ファイル削除も行う
        selfMemberID = nil
        userRecordName = nil
        profileUpdatedAt = nil
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

    // MARK: - Self Member (local-only convenience for member picker)

    /// MemberPicker で「自分」を表示できるよう、ローカル Member を 1 つ確保する。
    /// 表示用フィールド (name / colorHex / photoData) も最新の UserProfileStore 値で同期する。
    /// recordName / updatedAt は触らない (cross-device 同期は ParticipantProfile に集約)。
    func ensureSelfMemberExists(in ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.fetchLimit = 1
        if let id = selfMemberID {
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        }
        let existing: Member? = (selfMemberID != nil) ? (try? ctx.fetch(req))?.first : nil

        let member: Member
        if let existing {
            member = existing
        } else {
            member = Member(context: ctx)
            let id = UUID()
            member.id = id
            member.createdAt = .now
            member.sortOrder = 0
            selfMemberID = id
        }

        let newName = resolvedDisplayName
        if member.name != newName { member.name = newName }
        let newColor = avatarBgColorHex ?? "#5B8DEF"
        if member.colorHex != newColor { member.colorHex = newColor }
        if member.photoData != photoData { member.photoData = photoData }

        if ctx.hasChanges { try? ctx.save() }
    }

    // MARK: - Hydrate from ParticipantProfile (cross-device)

    /// 別端末から同期されてきた ParticipantProfile (recordName == userRecordName) から
    /// ローカル UserProfileStore を更新する。
    /// - ローカルがまだ空 (= 初回起動 + 既に他端末でシート作成済み) なら無条件で取り込む。
    /// - 既にローカル値があるなら、PP.updatedAt > profileUpdatedAt の時だけ取り込む (LWW)。
    @discardableResult
    func hydrateFromParticipantProfile(in ctx: NSManagedObjectContext) -> Bool {
        guard let rn = userRecordName, !rn.isEmpty else { return false }
        // 別端末の最新 PP を「このデバイスのデフォルト」として採用する。
        // (新規シート作成時の初期値に使うだけで、既存シートの PP には波及しない)
        let req = NSFetchRequest<ParticipantProfile>(entityName: "ParticipantProfile")
        req.predicate = NSPredicate(format: "recordName == %@", rn)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \ParticipantProfile.updatedAt, ascending: false)]
        req.fetchLimit = 1
        guard let latest = (try? ctx.fetch(req))?.first else { return false }

        let ppAt = latest.updatedAt ?? .distantPast
        let localAt = profileUpdatedAt ?? .distantPast

        let shouldAdopt = isEmpty || ppAt > localAt
        guard shouldAdopt else { return false }

        if let n = latest.displayName, !n.isEmpty, displayName != n {
            displayName = n
        }
        if let c = latest.colorHex, !c.isEmpty, avatarBgColorHex != c {
            avatarBgColorHex = c
        }
        if photoData != latest.photoData {
            photoData = latest.photoData
        }
        // ローカル更新時刻も PP の値に揃える (= 自分が編集していないので、PP に合わせる)
        profileUpdatedAt = ppAt > .distantPast ? ppAt : .now
        // selfMember の表示用フィールドも合わせて refresh
        ensureSelfMemberExists(in: ctx)
        return true
    }

    // MARK: - Per-sheet ParticipantProfile

    /// 1 シートに自分の ParticipantProfile が **無ければ** 直近の UserProfileStore 値で作成する。
    /// 既存 PP は触らない (シートごとに独立な per-sheet プロフィールを尊重するため)。
    /// 共有受諾後・新規シート作成直後の初期化に使う。
    func ensureProfile(in sheet: ExpenseSheet, ctx: NSManagedObjectContext) {
        guard let recordName = userRecordName, !recordName.isEmpty else { return }
        let existing = (sheet.participantProfiles as? Set<ParticipantProfile>)?
            .first(where: { $0.recordName == recordName })
        if existing != nil { return }
        writeParticipantProfile(
            into: sheet, recordName: recordName,
            displayName: resolvedDisplayName,
            colorHex: avatarBgColorHex ?? "#5B8DEF",
            photoData: photoData,
            ctx: ctx, now: Date()
        )
        if ctx.hasChanges { try? ctx.save() }
    }

    /// 自分の PP がまだ存在しないシートにだけ PP を作る (既存シートの値は上書きしない)。
    /// 共有受諾後・別端末から同期されてきた新シートの初期化に使う。
    func ensureProfileForAllSheets(in ctx: NSManagedObjectContext) {
        guard let recordName = userRecordName, !recordName.isEmpty else { return }
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        guard let sheets = try? ctx.fetch(sheetReq) else { return }
        let now = Date()
        var didChange = false
        for sheet in sheets {
            let existing = (sheet.participantProfiles as? Set<ParticipantProfile>)?
                .first(where: { $0.recordName == recordName })
            if existing == nil {
                writeParticipantProfile(
                    into: sheet, recordName: recordName,
                    displayName: resolvedDisplayName,
                    colorHex: avatarBgColorHex ?? "#5B8DEF",
                    photoData: photoData,
                    ctx: ctx, now: now
                )
                didChange = true
            }
        }
        if didChange, ctx.hasChanges { try? ctx.save() }
    }

    /// グローバルプロフィール (displayName / colorHex / photoData) を、override されていない
    /// 既存の ParticipantProfile に伝搬する。
    ///
    /// override 判定: `PP.updatedAt < profileUpdatedAt` (= シート単位編集で更新されていない)。
    /// シート単位編集された PP は `updatedAt` がグローバルより新しいため、ここでは触らない。
    ///
    /// 呼び出しタイミング:
    /// - グローバルプロフィール変更直後 (`applyDeviceLocalProfileEdit` 内)
    /// - アプリ起動時 (= 別端末で更新された profileUpdatedAt が hydrate で来た後)
    func propagateProfileToAllSheets(in ctx: NSManagedObjectContext) {
        guard let recordName = userRecordName, !recordName.isEmpty else { return }
        let globalUpdatedAt = profileUpdatedAt ?? .distantPast
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        guard let sheets = try? ctx.fetch(sheetReq) else { return }
        let now = Date()
        var didChange = false
        for sheet in sheets {
            let existing = (sheet.participantProfiles as? Set<ParticipantProfile>)?
                .first(where: { $0.recordName == recordName })
            if let existing {
                // override 保護: PP の updatedAt がグローバル profileUpdatedAt より新しいなら
                // シート単位で明示的に編集されている扱い → 触らない。
                if let ppUpdated = existing.updatedAt,
                   ppUpdated > globalUpdatedAt {
                    continue
                }
                // 差分があれば更新 (= 同じ値なら touch しない)
                let dn = resolvedDisplayName
                let cc = avatarBgColorHex ?? "#5B8DEF"
                let pd = photoData
                if existing.displayName != dn
                    || existing.colorHex != cc
                    || existing.photoData != pd {
                    existing.displayName = dn
                    existing.colorHex    = cc
                    existing.photoData   = pd
                    existing.updatedAt   = now
                    didChange = true
                }
            } else {
                // PP 未作成 → 新規作成
                writeParticipantProfile(
                    into: sheet, recordName: recordName,
                    displayName: resolvedDisplayName,
                    colorHex: avatarBgColorHex ?? "#5B8DEF",
                    photoData: photoData,
                    ctx: ctx, now: now
                )
                didChange = true
            }
        }
        if didChange, ctx.hasChanges { try? ctx.save() }
    }

    private func writeParticipantProfile(
        into sheet: ExpenseSheet,
        recordName: String,
        displayName: String,
        colorHex: String,
        photoData: Data?,
        ctx: NSManagedObjectContext,
        now: Date
    ) {
        guard let sheetStore = sheet.objectID.persistentStore else { return }
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
        profile.displayName  = displayName
        profile.colorHex     = colorHex
        profile.photoData    = photoData
        profile.updatedAt    = now
    }

    // MARK: - Apply edits

    /// 端末ローカルキャッシュ (UserProfileStore + Member) のみ更新する。
    /// 既存シートの PP には波及しない (= シートごと独立なプロフィール)。
    /// 主に「初回シート作成前のプロフィール下書き」(`AddSheetView`) で使う。
    /// 呼び出し側が先に `displayName` / `photoData` / `avatarBgColorHex` を更新済みである前提。
    func applyDeviceLocalProfileEdit(in ctx: NSManagedObjectContext) {
        ensureSelfMemberExists(in: ctx)
        profileUpdatedAt = .now
        // override されていない全シートの自分の PP にグローバルプロフィール変更を伝搬
        propagateProfileToAllSheets(in: ctx)
    }

    /// 1 シート単位のプロフィール編集を保存する。
    /// - そのシートの PP のみ書き換え。他シート / UserProfileStore / Member には影響しない。
    /// - 名前が変わっていればそのシート内の `paidBy` も置換。
    func applyPerSheetProfileEdit(
        in ctx: NSManagedObjectContext,
        sheet: ExpenseSheet,
        draftName: String,
        draftPhotoData: Data?,
        draftBgColorHex: String?
    ) {
        guard let recordName = userRecordName, !recordName.isEmpty else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        let newName = trimmed.isEmpty ? "自分" : trimmed
        let existing = (sheet.participantProfiles as? Set<ParticipantProfile>)?
            .first(where: { $0.recordName == recordName })
        let oldName = existing?.displayName ?? ""
        writeParticipantProfile(
            into: sheet, recordName: recordName,
            displayName: newName,
            colorHex: draftBgColorHex ?? "#5B8DEF",
            photoData: draftPhotoData,
            ctx: ctx, now: Date()
        )
        if !oldName.isEmpty, oldName != newName {
            renamePaidBy(in: sheet, from: oldName, to: newName, ctx: ctx)
        }
        if ctx.hasChanges { try? ctx.save() }
    }

    /// 1 シート内の旧 paidBy 文字列を新名に置き換える。
    private func renamePaidBy(in sheet: ExpenseSheet, from old: String, to new: String, ctx: NSManagedObjectContext) {
        let req = NSFetchRequest<Expense>(entityName: "Expense")
        req.predicate = NSPredicate(format: "sheet == %@ AND paidBy == %@", sheet, old)
        guard let expenses = try? ctx.fetch(req), !expenses.isEmpty else { return }
        for e in expenses { e.paidBy = new }
        if ctx.hasChanges { try? ctx.save() }
    }
}

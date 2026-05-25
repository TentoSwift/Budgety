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
        /// 自分の Apple ID メールアドレス (CKUserIdentity.lookupInfo.emailAddress 由来)。
        /// 旧 "email:..." canonical → URN 移行で「自分の email」判定に使う。
        static let selfEmail          = "userProfile.selfEmail"
        /// 最後に Public DB へ publish した自分のシート数。変化時のみ再 upload するため記録。
        static let lastPublishedSheetCount = "userProfile.lastPublishedSheetCount"
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

    /// 自分の Apple ID メールアドレス。`refreshAppleIDName` でキャッシュ。
    /// 旧 "email:..." canonical の自分ぶんを URN に書き換える migration で使う。
    @Published private(set) var selfEmail: String? {
        didSet { UserDefaults.standard.set(selfEmail, forKey: Keys.selfEmail) }
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
        self.selfEmail = ud.string(forKey: Keys.selfEmail)
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
        selfEmail = nil
        profileUpdatedAt = nil
        UserDefaults.standard.removeObject(forKey: Keys.lastPublishedSheetCount)
        PublicProfileSync.shared.clearCache()
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

    // MARK: - Profile update

    /// 自分のプロフィールを更新する。`profileUpdatedAt` を `.now` に進めて
    /// PP との LWW 比較に使えるようにする。
    /// 同時に Public DB (PublicProfileSync) にも背景で upload する。
    func updateProfile(displayName: String, photoData: Data?, avatarBgColorHex: String?) {
        self.displayName = displayName
        self.photoData = photoData
        self.avatarBgColorHex = avatarBgColorHex
        self.profileUpdatedAt = .now
        // 背景で Public DB に push (失敗してもローカル状態は更新済み)
        if let urn = userRecordName, !urn.isEmpty {
            let count = ownedSheetCount()
            Task { [resolvedDisplayName, photoData, count] in
                await PublicProfileSync.shared.uploadOwnProfile(
                    urn: urn,
                    displayName: resolvedDisplayName,
                    photoData: photoData,
                    sheetCount: count
                )
                UserDefaults.standard.set(count, forKey: Keys.lastPublishedSheetCount)
            }
        }
    }

    /// 自分が作成した (= オーナーの) シート数。Public プロフィールに publish する値。
    func ownedSheetCount() -> Int {
        let ctx = PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(req)) ?? []
        return sheets.filter { $0.isOwnedByCurrentUser }.count
    }

    /// 自分のシート数が前回 publish 時から変わっていれば Public DB に再 upload する。
    /// 起動時・前面化時に呼ぶ想定 (プロフィール編集が無くても件数を最新に保つ)。
    func publishSheetCountIfChanged() async {
        guard let urn = userRecordName, !urn.isEmpty else { return }
        let count = ownedSheetCount()
        let last = UserDefaults.standard.object(forKey: Keys.lastPublishedSheetCount) as? Int
        guard last != count else { return }
        await PublicProfileSync.shared.uploadOwnProfile(
            urn: urn,
            displayName: resolvedDisplayName,
            photoData: photoData,
            sheetCount: count
        )
        UserDefaults.standard.set(count, forKey: Keys.lastPublishedSheetCount)
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

    /// セッション内 1 回までガード (= ダイアログ多重表示防止)
    private var didAttemptDiscoverability = false

    /// 自分自身の Public DB プロフィール (= 別端末で編集したかもしれない値) を
    /// ローカルキャッシュに引いてくる。同じ Apple ID の他デバイスとの同期に使う。
    /// `profileUpdatedAt` よりも新しい場合のみ取り込む (LWW)。
    func refreshOwnPublicProfile() async {
        guard let urn = userRecordName, !urn.isEmpty else { return }
        await PublicProfileSync.shared.fetchProfiles(forURNs: [urn])
        guard let cached = PublicProfileSync.shared.cachedProfile(for: urn) else { return }
        let localUpdated = profileUpdatedAt ?? .distantPast
        // 別端末で新しく編集されていれば取り込む
        guard cached.updatedAt > localUpdated else { return }
        var changed = false
        if displayName != cached.displayName {
            displayName = cached.displayName
            changed = true
        }
        if photoData != cached.photoData {
            photoData = cached.photoData
            changed = true
        }
        if changed {
            profileUpdatedAt = cached.updatedAt
        }
    }

    /// 自分の Apple ID 名 (`CKUserIdentity.nameComponents`) を取得して必要なら
    /// `selfEmail` をキャッシュする。
    ///
    /// 重要:
    /// - displayName はカスタムプロフィール (ProfileEditView + Public DB) で管理する
    ///   方針なので、ここでは上書きしない。
    /// - userDiscoverability パーミッションは「未決定」の時だけ要求する。
    ///   `requestApplicationPermission` を毎回呼ぶと環境によってはダイアログが
    ///   何重にも開く事故が起きるため、必ず status を先に問い合わせる。
    /// - セッション内では 1 回だけ試行する (重複ガード)。
    func refreshAppleIDName() async {
        if didAttemptDiscoverability { return }
        didAttemptDiscoverability = true

        await ensureUserRecordNameLoaded()
        guard let urn = userRecordName, !urn.isEmpty else { return }

        let container = CKContainer(identifier: Self.containerID)

        // status を先に確認 → 未決定の時だけリクエスト
        let currentStatus = (try? await container.applicationPermissionStatus(for: .userDiscoverability))
            ?? .couldNotComplete
        let status: CKContainer.ApplicationPermissionStatus
        if currentStatus == .initialState {
            status = (try? await container.requestApplicationPermission(.userDiscoverability))
                ?? .couldNotComplete
        } else {
            status = currentStatus
        }
        guard status == .granted else { return }

        // self email だけキャッシュ (旧 "email:..." canonical の migration 用)
        do {
            let recID = CKRecord.ID(recordName: urn)
            guard let identity = try await container.userIdentity(forUserRecordID: recID) else { return }
            if let email = identity.lookupInfo?.emailAddress?.lowercased(),
               !email.isEmpty, selfEmail != email {
                selfEmail = email
            }
        } catch {
            // 取得失敗時は無視
        }
    }

    // MARK: - Canonical participant identity

    /// CKShare の「自分」エントリは userRecordID.recordName が `__defaultOwner__` に
    /// 匿名化される。これを判定するためのヘルパ。
    static func isSelfPlaceholderRecordName(_ recordName: String) -> Bool {
        recordName == "__defaultOwner__" || recordName == "_defaultOwner_"
    }

    /// バーチャルメンバー (アプリ未使用の相手を割り勘・精算に含める仮想メンバー) の
    /// recordName 接頭辞。実在の CloudKit ユーザーではないことを表す。
    /// CloudKit スキーマは既存の ParticipantProfile をそのまま使い、recordName の
    /// 接頭辞だけで区別する (スキーマ変更なし)。
    static let virtualRecordPrefix = "virtual:"
    /// recordName がバーチャルメンバーのものか。
    static func isVirtualRecordName(_ recordName: String) -> Bool {
        recordName.hasPrefix(virtualRecordPrefix)
    }

    /// 共有シート内で「自分」を identify するための canonical な ID。
    /// オーナー側と参加者側で別々の userRecordID 空間に居る場合があるため、
    /// recordName を直接使うと不整合になる。次のルールで揃える:
    /// - シートのオーナーが自分 → CKContainer.userRecordID().recordName
    /// - **常に `userRecordName` (URN) を返す**。
    ///   iCloud Extended Share Access エンタイトルメントで URN が全 viewer に
    ///   一致するため、旧 "email:..." canonical は不要になった。
    ///   SettlementCalculator / migrateLegacyPayerProfileIDs が旧データの
    ///   "email:..." → URN を自動正規化する。
    /// - share 引数は backward compat のために残置。
    func canonicalSelfID(forShare share: CKShare?) -> String? {
        return userRecordName
    }

    /// マッチング用: backward compat のため `userRecordName` (CKContainer.userRecordID 由来の
    /// 旧 ID) と canonical の両方を含む集合を返す。古い Expense.payerProfileID が
    /// 残っていても「自分」として検出できるようにする。
    /// 統合機能を廃止したため knownSelfIDs は使用しない (= デバイス間で不整合が起きるため)。
    func canonicalSelfIDs(forShare share: CKShare?) -> Set<String> {
        var ids: Set<String> = []
        if let urn = userRecordName, !urn.isEmpty { ids.insert(urn) }
        if let cid = canonicalSelfID(forShare: share), !cid.isEmpty { ids.insert(cid) }
        return ids
    }

    #if !os(watchOS)
    /// 過去の同名 PP 逆引き同期で self Member.recordName に他人の ID が紛れ込んで
    /// いる可能性があるので、self Member の recordName を canonical 経由で再正規化する。
    /// 共有シートが複数ある場合は判断不能なので、明らかに自分でない値 (他参加者の
    /// canonical / share.owner の recordName) であれば nil に戻す。
    func sanitizeSelfMemberRecordName(in ctx: NSManagedObjectContext) {
        guard let selfID = selfMemberID else { return }
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.predicate = NSPredicate(format: "id == %@", selfID as CVarArg)
        req.fetchLimit = 1
        guard let me = (try? ctx.fetch(req))?.first,
              let rn = me.recordName, !rn.isEmpty else { return }

        // self の正当な値: 全シートの canonical のいずれか or 旧 userRecordName
        var validIDs: Set<String> = []
        if let urn = userRecordName, !urn.isEmpty { validIDs.insert(urn) }
        let sheetReq = NSFetchRequest<NSManagedObject>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(sheetReq)) ?? []
        for s in sheets {
            guard let sheet = s as? ExpenseSheet else { continue }
            let share = ShareCoordinator.shared.existingShare(for: sheet)
            if let cid = canonicalSelfID(forShare: share), !cid.isEmpty {
                validIDs.insert(cid)
            }
        }
        if !validIDs.contains(rn) {
            me.recordName = nil
            try? ctx.save()
        }
    }

    /// 自分が過去に書いた Expense / RecurringRule / Template のうち、`payerProfileID` が
    /// 古い `userRecordName` (履歴を含む) または canonical 以外になっているものを
    /// 現在の canonical に書き換える。
    ///
    /// 識別ロジック:
    /// 1. `payerMemberID == selfMemberID` (UUID): デバイスローカルな最強の「自分」シグナル。
    ///    `selfMemberID` は UserDefaults に保持され、CloudKit には UUID として同期されるが
    ///    他端末では未知の値なので「自分」判定は本端末でのみ成立する。
    /// 2. (fallback) `payerProfileID == 現キャッシュ userRecordName`: payerMemberID が無い
    ///    旧データ用。
    ///
    /// CloudKit Sharing 経由で書き換えはオーナー側にも同期される。
    func migrateLegacyPayerProfileIDs(in ctx: NSManagedObjectContext) {
        let sheetReq = NSFetchRequest<NSManagedObject>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(sheetReq)) ?? []
        var totalChanged = 0
        for sheet in sheets {
            guard let s = sheet as? ExpenseSheet else { continue }
            let share = ShareCoordinator.shared.existingShare(for: s)
            // 非共有シートは migration 不要 (canonical == userRecordName)
            guard share != nil else { continue }
            guard let canonical = canonicalSelfID(forShare: share),
                  !canonical.isEmpty else { continue }

            // (1) payerMemberID == selfMemberID で「自分の行」を強く識別。
            if let mid = selfMemberID {
                totalChanged += rewriteByPayerMemberID(
                    in: ctx, sheet: s, selfMemberID: mid,
                    toID: canonical, toName: resolvedDisplayName
                )
            }
            // (2) 旧 userRecordName 一致もカバー (payerMemberID 無しの古いデータ)
            if let urn = userRecordName, !urn.isEmpty, urn != canonical {
                totalChanged += rewriteByPayerProfileID(
                    in: ctx, sheet: s, fromID: urn,
                    toID: canonical, toName: resolvedDisplayName,
                    toMemberID: selfMemberID
                )
            }
            // (3) beneficiaryProfileIDs (CSV) 内の自分の旧 ID を canonical に
            if let urn = userRecordName, !urn.isEmpty, urn != canonical {
                totalChanged += rewriteBeneficiaryCSV(in: ctx, sheet: s, fromID: urn, toID: canonical)
            }
            // (4) "email:..." canonical → URN 移行
            // 旧バージョンで自分や他人を email-based canonical で保存していた行を、
            // CKShare.participants から取れる URN にリライトする。
            if let share = ShareCoordinator.shared.existingShare(for: s) {
                var emailToURN: [String: String] = [:]
                for p in share.participants {
                    let urnRaw = p.userIdentity.userRecordID?.recordName ?? ""
                    let resolvedURN: String
                    if Self.isSelfPlaceholderRecordName(urnRaw) {
                        // self placeholder → 自分の URN に置き換え
                        guard let myURN = userRecordName, !myURN.isEmpty else { continue }
                        resolvedURN = myURN
                    } else {
                        guard !urnRaw.isEmpty else { continue }
                        resolvedURN = urnRaw
                    }
                    if let email = p.userIdentity.lookupInfo?.emailAddress?.lowercased(),
                       !email.isEmpty {
                        emailToURN["email:" + email] = resolvedURN
                    }
                }
                // selfEmail キャッシュからもフォールバック (userDiscoverability 経由)
                if let myEmail = selfEmail?.lowercased(), !myEmail.isEmpty,
                   let myURN = userRecordName, !myURN.isEmpty {
                    emailToURN["email:" + myEmail] = myURN
                }
                for (emailKey, urn) in emailToURN {
                    totalChanged += rewriteByPayerProfileID(
                        in: ctx, sheet: s, fromID: emailKey,
                        toID: urn, toName: "", toMemberID: nil
                    )
                    totalChanged += rewriteBeneficiaryCSV(in: ctx, sheet: s, fromID: emailKey, toID: urn)
                    totalChanged += mergeDuplicatePP(in: ctx, sheet: s, fromID: emailKey, toID: urn)
                }
            }
        }
        if totalChanged > 0 {
            try? ctx.save()
        }
    }

    /// 旧 canonical (email:xxx) で作られた PP と URN で作られた PP が両方存在する場合、
    /// 旧 PP を削除して URN PP に統一する。
    /// **自分の PP のみ対象**: 他人の PP を当端末から削除/書き換えると CloudKit
    /// 共有ゾーン経由で相手のレコードも更新してしまうため、`toID` が自分の URN
    /// と一致しない場合は何もしない。他人の重複 PP は本人の端末でだけクリーンアップする。
    private func mergeDuplicatePP(
        in ctx: NSManagedObjectContext,
        sheet: ExpenseSheet,
        fromID: String,
        toID: String
    ) -> Int {
        // 自分以外の PP は触らない (CloudKit 共有ゾーン経由で相手レコードを変更しないため)
        guard let myURN = userRecordName, !myURN.isEmpty, toID == myURN else { return 0 }
        guard let pps = sheet.participantProfiles as? Set<ParticipantProfile> else { return 0 }
        let oldPP = pps.first(where: { $0.recordName == fromID })
        guard let oldPP else { return 0 }
        let newPP = pps.first(where: { $0.recordName == toID })
        if let newPP {
            // 両方存在 → 旧 PP の値を新 PP にマージ (新 PP が空のフィールドのみ補完) して旧を削除
            if (newPP.displayName ?? "").isEmpty, let dn = oldPP.displayName, !dn.isEmpty {
                newPP.displayName = dn
            }
            if (newPP.colorHex ?? "").isEmpty, let ch = oldPP.colorHex, !ch.isEmpty {
                newPP.colorHex = ch
            }
            if newPP.photoData == nil, let pd = oldPP.photoData {
                newPP.photoData = pd
            }
            ctx.delete(oldPP)
        } else {
            // 旧 PP しかない → URN にリネーム
            oldPP.recordName = toID
            oldPP.updatedAt = .now
        }
        return 1
    }

    /// Expense.beneficiaryProfileIDs (CSV) の中に `fromID` があれば `toID` に置換。
    /// 重複削除は beneficiaryIDList の setter 側で行うのでここではしない。
    private func rewriteBeneficiaryCSV(
        in ctx: NSManagedObjectContext,
        sheet: ExpenseSheet,
        fromID: String,
        toID: String
    ) -> Int {
        var changed = 0
        let expReq = NSFetchRequest<Expense>(entityName: "Expense")
        // CSV 内検索なので CONTAINS で初期絞り込み (false-positive あり得るので
        // ループ内で正確に判定する)
        expReq.predicate = NSPredicate(format: "sheet == %@ AND beneficiaryProfileIDs CONTAINS %@", sheet, fromID)
        for e in (try? ctx.fetch(expReq)) ?? [] {
            let list = e.beneficiaryIDList
            guard list.contains(fromID) else { continue }
            e.beneficiaryIDList = list.map { $0 == fromID ? toID : $0 }
            changed += 1
        }
        return changed
    }

    /// `payerMemberID == selfMemberID` のものを canonical に揃える。
    /// 既に canonical の場合はスキップ。
    private func rewriteByPayerMemberID(
        in ctx: NSManagedObjectContext,
        sheet: ExpenseSheet,
        selfMemberID: UUID,
        toID: String,
        toName: String
    ) -> Int {
        var changed = 0
        let expReq = NSFetchRequest<Expense>(entityName: "Expense")
        expReq.predicate = NSPredicate(format: "sheet == %@ AND payerMemberID == %@", sheet, selfMemberID as CVarArg)
        for e in (try? ctx.fetch(expReq)) ?? [] {
            if (e.payerProfileID ?? "") != toID {
                e.payerProfileID = toID
                if (e.paidBy ?? "").isEmpty { e.paidBy = toName }
                changed += 1
            }
        }
        let tplReq = NSFetchRequest<ExpenseTemplate>(entityName: "ExpenseTemplate")
        tplReq.predicate = NSPredicate(format: "sheet == %@ AND payerMemberID == %@", sheet, selfMemberID as CVarArg)
        for t in (try? ctx.fetch(tplReq)) ?? [] {
            if (t.payerProfileID ?? "") != toID {
                t.payerProfileID = toID
                if (t.paidBy ?? "").isEmpty { t.paidBy = toName }
                changed += 1
            }
        }
        return changed
    }

    /// `sheet` 配下の Expense / RecurringRule / ExpenseTemplate のうち、
    /// `payerProfileID == fromID` のものを `toID` (canonical) に書き換える。
    /// 戻り値は変更件数。
    private func rewriteByPayerProfileID(
        in ctx: NSManagedObjectContext,
        sheet: ExpenseSheet,
        fromID: String,
        toID: String,
        toName: String,
        toMemberID: UUID?
    ) -> Int {
        var changed = 0
        let expReq = NSFetchRequest<Expense>(entityName: "Expense")
        expReq.predicate = NSPredicate(format: "sheet == %@ AND payerProfileID == %@", sheet, fromID)
        for e in (try? ctx.fetch(expReq)) ?? [] {
            e.payerProfileID = toID
            if let mid = toMemberID { e.payerMemberID = mid }
            if (e.paidBy ?? "").isEmpty { e.paidBy = toName }
            changed += 1
        }
        let ruleReq = NSFetchRequest<RecurringRule>(entityName: "RecurringRule")
        ruleReq.predicate = NSPredicate(format: "sheet == %@ AND payerProfileID == %@", sheet, fromID)
        for r in (try? ctx.fetch(ruleReq)) ?? [] {
            r.payerProfileID = toID
            if (r.paidBy ?? "").isEmpty { r.paidBy = toName }
            changed += 1
        }
        let tplReq = NSFetchRequest<ExpenseTemplate>(entityName: "ExpenseTemplate")
        tplReq.predicate = NSPredicate(format: "sheet == %@ AND payerProfileID == %@", sheet, fromID)
        for t in (try? ctx.fetch(tplReq)) ?? [] {
            t.payerProfileID = toID
            if let mid = toMemberID { t.payerMemberID = mid }
            if (t.paidBy ?? "").isEmpty { t.paidBy = toName }
            changed += 1
        }
        return changed
    }
    #endif

    /// Member エンティティを作らずに `selfMemberID` (UUID) だけを確保する。
    /// watchOS のように Core Data の Member 操作で cross-store 問題が起きる環境向け。
    /// payerMemberID として書き込めば iOS の auto-migration が canonical に正規化する。
    @discardableResult
    func ensureSelfMemberID() -> UUID {
        if let id = selfMemberID { return id }
        let new = UUID()
        selfMemberID = new
        return new
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

    #if !os(watchOS)
    /// 自分の PP 用 recordName 集合 (各シートの canonical + 旧 userRecordName)。
    /// PP は per-sheet なので、シートごとに異なる canonical で書かれ得る (= オーナーか
    /// 参加者かでスキームが変わる)。読みは集合に含まれるすべてを「自分の PP」と扱う。
    func selfPPRecordNames(in ctx: NSManagedObjectContext) -> Set<String> {
        var ids: Set<String> = []
        if let urn = userRecordName, !urn.isEmpty { ids.insert(urn) }
        let sheetReq = NSFetchRequest<NSManagedObject>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(sheetReq)) ?? []
        for s in sheets {
            guard let sheet = s as? ExpenseSheet else { continue }
            let share = ShareCoordinator.shared.existingShare(for: sheet)
            if let cid = canonicalSelfID(forShare: share), !cid.isEmpty {
                ids.insert(cid)
            }
        }
        return ids
    }
    #endif

    /// 別端末から同期されてきた ParticipantProfile (recordName == 自分の canonical / 旧 URN) から
    /// ローカル UserProfileStore を更新する。
    /// - ローカルがまだ空 (= 初回起動 + 既に他端末でシート作成済み) なら無条件で取り込む。
    /// - 既にローカル値があるなら、PP.updatedAt > profileUpdatedAt の時だけ取り込む (LWW)。
    @discardableResult
    func hydrateFromParticipantProfile(in ctx: NSManagedObjectContext) -> Bool {
        #if os(watchOS)
        guard let rn = userRecordName, !rn.isEmpty else { return false }
        let candidates: [String] = [rn]
        #else
        let candidates: [String] = Array(selfPPRecordNames(in: ctx))
        guard !candidates.isEmpty else { return false }
        #endif
        let req = NSFetchRequest<ParticipantProfile>(entityName: "ParticipantProfile")
        req.predicate = NSPredicate(format: "recordName IN %@", candidates)
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

    /// 指定シートの「自分の PP 用 recordName」を返す。共有シートでは canonical
     /// (オーナーなら userRecordName、参加者なら "email:..."、両端末で同じ値で見える)、
    /// 非共有シートでは userRecordName。
    private func selfRecordNameForPP(in sheet: ExpenseSheet) -> String? {
        #if !os(watchOS)
        let share = ShareCoordinator.shared.existingShare(for: sheet)
        if let cid = canonicalSelfID(forShare: share), !cid.isEmpty {
            return cid
        }
        #endif
        return userRecordName
    }

    /// 「自分の PP」を sheet 内で見つける。canonical で書かれた PP と、旧 userRecordName
    /// 由来の PP の両方をマッチさせる (migration 用)。
    private func findSelfPP(in sheet: ExpenseSheet) -> ParticipantProfile? {
        guard let pps = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        var candidates: Set<String> = []
        if let urn = userRecordName, !urn.isEmpty { candidates.insert(urn) }
        if let rn = selfRecordNameForPP(in: sheet), !rn.isEmpty { candidates.insert(rn) }
        return pps.first(where: {
            guard let rn = $0.recordName, !rn.isEmpty else { return false }
            return candidates.contains(rn)
        })
    }

    /// 1 シートに自分の ParticipantProfile が **無ければ** 直近の UserProfileStore 値で作成する。
    /// 既存 PP は触らない (シートごとに独立な per-sheet プロフィールを尊重するため)。
    /// 共有受諾後・新規シート作成直後の初期化に使う。
    func ensureProfile(in sheet: ExpenseSheet, ctx: NSManagedObjectContext) {
        guard let recordName = selfRecordNameForPP(in: sheet), !recordName.isEmpty else { return }
        if findSelfPP(in: sheet) != nil { return }
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
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        guard let sheets = try? ctx.fetch(sheetReq) else { return }
        let now = Date()
        var didChange = false
        for sheet in sheets {
            guard let recordName = selfRecordNameForPP(in: sheet), !recordName.isEmpty else { continue }
            if findSelfPP(in: sheet) == nil {
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
    /// PP.recordName はシートの canonical で書く (共有相手から見えるキーを揃えるため)。
    /// 旧 userRecordName で書かれた既存 PP が見つかれば、それを採用して更新する
    /// (= 二重 PP を作らない)。
    func propagateProfileToAllSheets(in ctx: NSManagedObjectContext) {
        let globalUpdatedAt = profileUpdatedAt ?? .distantPast
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        guard let sheets = try? ctx.fetch(sheetReq) else { return }
        let now = Date()
        var didChange = false
        for sheet in sheets {
            guard let recordName = selfRecordNameForPP(in: sheet), !recordName.isEmpty else { continue }
            let existing = findSelfPP(in: sheet)
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
                let needsContentUpdate = existing.displayName != dn
                    || existing.colorHex != cc
                    || existing.photoData != pd
                let needsRecordNameMigration = existing.recordName != recordName
                if needsContentUpdate || needsRecordNameMigration {
                    if needsContentUpdate {
                        existing.displayName = dn
                        existing.colorHex    = cc
                        existing.photoData   = pd
                    }
                    if needsRecordNameMigration {
                        existing.recordName = recordName
                    }
                    existing.updatedAt = now
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

    #if !os(watchOS)
    /// CKShare の各 participant の `userIdentity.nameComponents` を ParticipantProfile
    /// にハイドレートする。`iCloud Extended Share Access` エンタイトルメント有効化後は
    /// 他参加者の実名が CKShare 経由で取れるため、それを PP.displayName に反映して
    /// アプリ内でのプロフィール設定なしに Apple ID 名を表示できるようにする。
    ///
    /// - 自分 (`__defaultOwner__` placeholder) は対象外。
    /// - PP が無ければ作成、あれば差分があるときだけ updatedAt 更新。
    /// - 色は触らない (色は per-user / per-sheet で UserProfileStore 経由)。
    /// - 写真は触らない (Apple ID 写真は CKShare 経由でも取れないため)。
    func hydrateParticipantProfilesFromShares(in ctx: NSManagedObjectContext) {
        // ※ 過去版は CKShare の各 participant の nameComponents を、その participant の
        //    URN にあたる ParticipantProfile レコードに書き込んでいた (= 他人の PP を
        //    こちら側から更新)。CKShare zone は共有ストアで、ここから書くと
        //    相手側のレコードを上書きしてしまうため廃止。
        //
        // 名前/写真の表示は:
        //   - 自分: UserProfileStore (ローカル) + PublicProfileSync (Public DB upload)
        //   - 他人: PublicProfileSync (Public DB fetch) + CKShare.participants の
        //          nameComponents (live、ExpenseSheet.nameFromShare 経由)
        // で完結するので、PP を書き溜める必要は無い。
        _ = ctx  // no-op
    }

    /// 全シートの CKShare.participants と既存 PP レコードから URN を集めて
    /// PublicProfileSync の cache を埋める。他人のプロフィール写真表示用。
    /// hydrateParticipantProfilesFromShares が no-op になったので、こちらで
    /// CKShare 経由の URN も拾うようにする。
    @MainActor
    func prefetchAllProfileURNs(in ctx: NSManagedObjectContext) async {
        var urns: Set<String> = []
        // 自分の URN
        if let own = userRecordName, !own.isEmpty { urns.insert(own) }
        // 既存 PP レコード由来
        let ppReq = NSFetchRequest<ParticipantProfile>(entityName: "ParticipantProfile")
        let pps = (try? ctx.fetch(ppReq)) ?? []
        for pp in pps {
            guard let rn = pp.recordName, !rn.isEmpty,
                  !Self.isSelfPlaceholderRecordName(rn) else { continue }
            if rn.hasPrefix("email:") || rn.hasPrefix("phone:") { continue }
            urns.insert(rn)
        }
        // 全シートの CKShare.participants 由来 (= 主経路)
        let sheetReq = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        let sheets = (try? ctx.fetch(sheetReq)) ?? []
        for sheet in sheets {
            guard let share = ShareCoordinator.shared.existingShare(for: sheet) else { continue }
            for p in share.participants {
                guard let rn = p.userIdentity.userRecordID?.recordName,
                      !rn.isEmpty,
                      !Self.isSelfPlaceholderRecordName(rn) else { continue }
                urns.insert(rn)
            }
        }
        guard !urns.isEmpty else { return }
        await PublicProfileSync.shared.fetchProfiles(forURNs: Array(urns))
    }
    #endif

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

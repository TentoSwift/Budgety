//
//  PublicProfileSync.swift
//  Budgety
//
//  全ユーザーのプロフィール (displayName + photo + colorHex) を CloudKit Public DB
//  に保存する。ShareCalendarApp のプロフィール設計を参考にしている。
//
//  - レコードタイプ: `UserProfile`
//  - レコード ID: `profile_<userRecordName>` (CKShare 越しに他人の URN から逆引き可能)
//  - フィールド: displayName: String, profilePhoto: Asset, colorHex: String, updatedAt: Date
//  - プライバシー: Public DB は同 container 利用者全員から読み取り可能
//    (オンボーディングで合意取得済み)
//

import Foundation
import Combine
import CloudKit
import os.log

@MainActor
final class PublicProfileSync: ObservableObject {
    static let shared = PublicProfileSync()

    private static let log = Logger(subsystem: "com.tento.budgety", category: "PublicProfileSync")

    /// CloudKit Public DB の record type 名。Dashboard で同名のレコードを deploy する必要がある。
    static let recordType = "UserProfile"
    private static let fieldDisplayName = "displayName"
    private static let fieldPhoto = "profilePhoto"
    private static let fieldColorHex = "colorHex"
    private static let fieldUpdatedAt = "updatedAt"

    private let containerID = "iCloud.com.tento.budgety"
    private var container: CKContainer { CKContainer(identifier: containerID) }
    private var publicDB: CKDatabase { container.publicCloudDatabase }

    /// キャッシュ済みプロフィール。Published で View に変更通知する。
    @Published private(set) var cache: [String: CachedProfile] = [:]

    /// fetch / upload 中フラグ
    @Published private(set) var isBusy: Bool = false

    /// 直前のエラー (デバッグ表示用)
    @Published private(set) var lastError: String?

    /// キャッシュ TTL
    private static let cacheTTL: TimeInterval = 60 * 30   // 30 min

    /// キャッシュ persistence のための UserDefaults キー (スキーマ変更時は v2 に bump)
    private static let udCacheKey = "publicProfile.cache.v2"

    struct CachedProfile: Codable, Equatable {
        let displayName: String
        let photoData: Data?
        let colorHex: String?
        let updatedAt: Date
        let fetchedAt: Date
    }

    private init() {
        self.cache = Self.loadCacheFromDisk()
    }

    // MARK: - Record ID

    /// userRecordName から UserProfile レコード ID を生成。
    /// ShareCalendarApp と同じ命名規則 (`profile_<recordName>`)。
    private func profileRecordID(forURN urn: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "profile_\(urn)")
    }

    // MARK: - Disk-backed cache

    private static func loadCacheFromDisk() -> [String: CachedProfile] {
        guard let data = UserDefaults.standard.data(forKey: udCacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedProfile].self, from: data)) ?? [:]
    }

    private func saveCacheToDisk() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.udCacheKey)
        }
    }

    // MARK: - Lookup

    /// キャッシュからの即時参照 (fetch しない)。表示時の高頻度呼び出し用。
    func cachedProfile(for urn: String) -> CachedProfile? {
        guard !urn.isEmpty else { return nil }
        return cache[urn]
    }

    /// キャッシュにあれば即返し、無いか TTL 切れなら背景 fetch をキック。
    @discardableResult
    func profileOrPrefetch(for urn: String) -> CachedProfile? {
        guard !urn.isEmpty else { return nil }
        let existing = cache[urn]
        let needsRefresh: Bool = {
            guard let existing else { return true }
            return Date().timeIntervalSince(existing.fetchedAt) > Self.cacheTTL
        }()
        if needsRefresh {
            Task { await fetchProfiles(forURNs: [urn]) }
        }
        return existing
    }

    // MARK: - Fetch others

    /// 複数 URN のプロフィールをまとめて取得し、キャッシュに格納する。
    func fetchProfiles(forURNs urns: [String]) async {
        let cleaned = urns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let ids = cleaned.map { profileRecordID(forURN: $0) }
        do {
            isBusy = true
            defer { isBusy = false }
            let result = try await publicDB.records(for: ids)
            var anyChange = false
            let now = Date()
            for (rid, recordRes) in result {
                // recordName から元 URN を復元
                let recordName = rid.recordName
                let urn = recordName.hasPrefix("profile_")
                    ? String(recordName.dropFirst("profile_".count))
                    : recordName
                switch recordRes {
                case .success(let rec):
                    let dn = (rec[Self.fieldDisplayName] as? String) ?? ""
                    var photoData: Data? = nil
                    if let asset = rec[Self.fieldPhoto] as? CKAsset, let url = asset.fileURL {
                        photoData = try? Data(contentsOf: url)
                    }
                    let colorHex = rec[Self.fieldColorHex] as? String
                    let updatedAt = (rec[Self.fieldUpdatedAt] as? Date) ?? rec.modificationDate ?? now
                    let cached = CachedProfile(
                        displayName: dn,
                        photoData: photoData,
                        colorHex: colorHex,
                        updatedAt: updatedAt,
                        fetchedAt: now
                    )
                    if cache[urn] != cached {
                        cache[urn] = cached
                        anyChange = true
                    }
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .unknownItem {
                        // 相手がまだ Public profile を書いていない (正常)
                    } else {
                        Self.log.debug("fetch \(rid.recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            if anyChange { saveCacheToDisk() }
        } catch {
            lastError = error.localizedDescription
            Self.log.error("fetchProfiles failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Upload own

    /// 自分の URN + プロフィール (displayName / photoData / colorHex) を
    /// Public DB にupsert する。
    func uploadOwnProfile(urn: String, displayName: String, photoData: Data?, colorHex: String?) async {
        let trimmedURN = urn.trimmingCharacters(in: .whitespaces)
        guard !trimmedURN.isEmpty else { return }
        let recordID = profileRecordID(forURN: trimmedURN)
        do {
            isBusy = true
            defer { isBusy = false }

            let record: CKRecord
            do {
                record = try await publicDB.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: Self.recordType, recordID: recordID)
            }
            record[Self.fieldDisplayName] = displayName as CKRecordValue
            record[Self.fieldUpdatedAt]   = Date() as CKRecordValue
            if let colorHex, !colorHex.isEmpty {
                record[Self.fieldColorHex] = colorHex as CKRecordValue
            } else {
                record[Self.fieldColorHex] = nil
            }

            if let data = photoData, !data.isEmpty {
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("public-profile-\(UUID().uuidString).jpg")
                try data.write(to: tmpURL, options: .atomic)
                record[Self.fieldPhoto] = CKAsset(fileURL: tmpURL)
            } else {
                record[Self.fieldPhoto] = nil
            }

            _ = try await publicDB.save(record)

            let now = Date()
            cache[trimmedURN] = CachedProfile(
                displayName: displayName,
                photoData: photoData,
                colorHex: colorHex,
                updatedAt: now,
                fetchedAt: now
            )
            saveCacheToDisk()
        } catch {
            lastError = error.localizedDescription
            Self.log.error("uploadOwnProfile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 旧 API 互換 (colorHex 無し) — 既存コードの呼び出しを壊さないため残す。
    func uploadOwnProfile(urn: String, displayName: String, photoData: Data?) async {
        await uploadOwnProfile(urn: urn, displayName: displayName, photoData: photoData, colorHex: nil)
    }

    // MARK: - Convenience

    func clearCache() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.udCacheKey)
    }
}

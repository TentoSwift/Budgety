//
//  SheetLockManager.swift
//  Budgety
//
//  シート毎のパスワード/Face ID ロックを管理するシングルトン。
//
//  - パスワードハッシュ/ソルトは ExpenseSheet 自身のプロパティとして
//    Core Data + CloudKit に保存される (= 共有シートの参加者間で共有される)
//  - hash = SHA256( salt + password )
//  - 生体認証 ON/OFF もシートの設定として Core Data + CloudKit 同期される。
//    実際に生体認証が使えるかは解錠時に端末側で評価するため、非対応端末では
//    自動的にパスワード入力へフォールバックする (= 非対応端末で ON にしても安全)
//  - セッション解錠状態は in-memory (アプリ再起動でロック再要求)
//

import Foundation
import CryptoKit
import CoreData
#if canImport(LocalAuthentication) && !os(watchOS)
import LocalAuthentication
#endif
import Combine

@MainActor
final class SheetLockManager: ObservableObject {
    static let shared = SheetLockManager()

    /// 現セッションで解錠済みのシート (objectID URI)。アプリ再起動で空に。
    @Published private(set) var unlockedSheetURIs: Set<String> = []

    private let defaults: UserDefaults
    /// マイグレーション元の旧 key prefix (v0.x で UserDefaults にハッシュごと格納していたもの)。
    static let legacyPrefix = "BudgetySheetLock."

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Public API

    /// 指定シートにパスワードが設定されているか。
    func hasPassword(for sheet: ExpenseSheet) -> Bool {
        guard let h = sheet.lockPasswordHash, !h.isEmpty,
              let s = sheet.lockPasswordSalt, !s.isEmpty else { return false }
        return true
    }

    /// 解錠状態か (= セッション内で既に正しいパスワード/生体認証通過済み)。
    func isUnlocked(_ sheet: ExpenseSheet) -> Bool {
        guard hasPassword(for: sheet) else { return true }
        return unlockedSheetURIs.contains(uriString(for: sheet))
    }

    /// シートにパスワードを設定 (新規 or 変更)。
    /// `enableBiometric` が true なら Face ID / Touch ID も使えるようにする (デバイス毎)。
    func setPassword(_ password: String, for sheet: ExpenseSheet, enableBiometric: Bool) {
        guard !password.isEmpty else { return }
        let salt = Self.randomSaltBase64()
        let hash = Self.hash(password: password, salt: salt)
        sheet.lockPasswordSalt = salt
        sheet.lockPasswordHash = hash
        sheet.lockBiometricEnabled = enableBiometric
        saveContext(of: sheet)
        // 設定直後は当然解錠扱い
        unlockedSheetURIs.insert(uriString(for: sheet))
        objectWillChange.send()
    }

    /// パスワード削除 (= ロック解除)。
    func clearPassword(for sheet: ExpenseSheet) {
        sheet.lockPasswordHash = nil
        sheet.lockPasswordSalt = nil
        sheet.lockBiometricEnabled = false
        saveContext(of: sheet)
        unlockedSheetURIs.remove(uriString(for: sheet))
        objectWillChange.send()
    }

    /// パスワード検証 → 成功なら解錠。
    @discardableResult
    func unlock(_ sheet: ExpenseSheet, withPassword password: String) -> Bool {
        guard verify(sheet, password: password) else { return false }
        unlockedSheetURIs.insert(uriString(for: sheet))
        return true
    }

    /// パスワード検証のみ (= 解錠状態は変更しない)。
    /// 解錠アニメーションを見せた後に setUnlocked したい場合に使う。
    func verify(_ sheet: ExpenseSheet, password: String) -> Bool {
        guard let salt = sheet.lockPasswordSalt,
              let storedHash = sheet.lockPasswordHash,
              !salt.isEmpty, !storedHash.isEmpty
        else { return false }
        return Self.hash(password: password, salt: salt) == storedHash
    }

    /// 既に verify 済みのシートを明示的に解錠状態へ移行する。
    func setUnlocked(_ sheet: ExpenseSheet) {
        unlockedSheetURIs.insert(uriString(for: sheet))
    }

    #if !os(watchOS)
    /// 生体認証で解錠を試みる (検証 + 解錠状態セットを一気に行う)。
    /// - Returns: 成功 = true、失敗 / 生体認証無効 = false
    func unlockWithBiometric(_ sheet: ExpenseSheet) async -> Bool {
        let ok = await verifyBiometric(sheet)
        if ok { unlockedSheetURIs.insert(uriString(for: sheet)) }
        return ok
    }

    /// 生体認証で「検証のみ」行う (解錠状態は変更しない)。
    /// 解錠アニメーションを見せてから setUnlocked したい呼び出し側向け。
    func verifyBiometric(_ sheet: ExpenseSheet) async -> Bool {
        guard isBiometricEnabled(for: sheet) else { return false }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "パスワードを入力"
        var policyError: NSError?
        // 生体認証が失敗した場合に端末パスコードへフォールバックさせるため
        // `.deviceOwnerAuthentication` を使う (= 純粋な biometrics-only より親切)。
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard ctx.canEvaluatePolicy(policy, error: &policyError) else {
            #if DEBUG
            print("[SheetLockManager] canEvaluatePolicy failed: \(policyError?.localizedDescription ?? "nil") code=\((policyError as? LAError)?.code.rawValue ?? -1)")
            #endif
            return false
        }
        do {
            return try await ctx.evaluatePolicy(
                policy,
                localizedReason: "「\(sheet.displayName)」を開く"
            )
        } catch {
            #if DEBUG
            print("[SheetLockManager] evaluatePolicy failed: \(error.localizedDescription) code=\((error as? LAError)?.code.rawValue ?? -1)")
            #endif
            return false
        }
    }
    #endif

    /// 生体認証 ON/OFF (シート設定として CloudKit 同期)。
    func isBiometricEnabled(for sheet: ExpenseSheet) -> Bool {
        sheet.lockBiometricEnabled
    }

    func setBiometricEnabled(_ enabled: Bool, for sheet: ExpenseSheet) {
        sheet.lockBiometricEnabled = enabled
        saveContext(of: sheet)
        objectWillChange.send()
    }

    /// セッション中の解錠状態をクリア (= 強制再ロック)。
    func lockAll() {
        unlockedSheetURIs.removeAll()
    }

    /// 指定シートを再ロック。
    func lock(_ sheet: ExpenseSheet) {
        unlockedSheetURIs.remove(uriString(for: sheet))
    }

    // MARK: - Migration (v0.x の UserDefaults 保存 → Core Data へ書き戻し)

    /// 起動時に 1 度だけ呼ぶ想定。
    /// UserDefaults の旧キー `BudgetySheetLock.<uri>` を走査し、
    /// 対応する ExpenseSheet がまだロック未設定なら hash/salt を書き戻す。
    /// 完了したら旧キーは削除する (= 同期は Core Data 側に一本化)。
    func migrateLegacyEntriesIfNeeded(context: NSManagedObjectContext) {
        let allKeys = defaults.dictionaryRepresentation().keys
        let legacyKeys = allKeys.filter { $0.hasPrefix(Self.legacyPrefix) }
        guard !legacyKeys.isEmpty else { return }

        for key in legacyKeys {
            guard let entry = defaults.dictionary(forKey: key),
                  let salt = entry["salt"] as? String,
                  let hash = entry["hash"] as? String
            else {
                defaults.removeObject(forKey: key)
                continue
            }
            let uriStr = String(key.dropFirst(Self.legacyPrefix.count))
            guard let url = URL(string: uriStr),
                  let coord = context.persistentStoreCoordinator,
                  let objectID = coord.managedObjectID(forURIRepresentation: url),
                  let sheet = try? context.existingObject(with: objectID) as? ExpenseSheet
            else {
                // 対応 sheet が見つからない (= 削除済み or 別端末) → legacy key だけ削除
                defaults.removeObject(forKey: key)
                continue
            }
            // 既に Core Data 側にハッシュがある場合は上書きせず、legacy 側を捨てる
            if sheet.lockPasswordHash == nil || sheet.lockPasswordHash?.isEmpty == true {
                sheet.lockPasswordHash = hash
                sheet.lockPasswordSalt = salt
            }
            // 生体認証フラグはシート属性 (CloudKit 同期) に転記
            if let bio = entry["biometric"] as? Bool {
                sheet.lockBiometricEnabled = bio
            }
            defaults.removeObject(forKey: key)
        }

        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - Helpers

    private func uriString(for sheet: ExpenseSheet) -> String {
        sheet.objectID.uriRepresentation().absoluteString
    }

    private func saveContext(of sheet: ExpenseSheet) {
        guard let ctx = sheet.managedObjectContext, ctx.hasChanges else { return }
        do {
            try ctx.save()
        } catch {
            // 保存失敗時は in-memory に変更は残ってしまうが、UI 側にエラー伝搬する手段が無いので
            // ベストエフォート (= 次回 save 機会に持ち越す)。
            #if DEBUG
            print("[SheetLockManager] save failed: \(error)")
            #endif
        }
    }

    private static func hash(password: String, salt: String) -> String {
        let data = Data((salt + password).utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSaltBase64() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

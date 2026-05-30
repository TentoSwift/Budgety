//
//  BuildInfo.swift
//  Budgety
//
//  ビルドの種別判定。DEBUG / TestFlight (= sandbox receipt) / App Store の 3 段階。
//  デバッグ用 UI を「TestFlight でも見せたいが App Store ではオフにしたい」場合に使う。
//

import Foundation

enum BuildInfo {
    /// TestFlight ビルドか (= sandbox receipt が App Store ではなく TestFlight 経由を示す)。
    /// Debug ビルドは含まない。判定は `appStoreReceiptURL.path` に "sandboxReceipt" を含むか。
    static var isTestFlight: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.path.contains("sandboxReceipt")
    }

    /// 内部配布ビルドか (= DEBUG または TestFlight)。
    /// App Store 配信版 (= production) では false。
    static var isInternalBuild: Bool {
        #if DEBUG
        return true
        #else
        return isTestFlight
        #endif
    }

    /// プロフィール機能 (UserProfileStore / ParticipantProfile / ProfileEditView 等) を有効化するか。
    /// PP は canonical ID (オーナーなら userRecordName、参加者なら "email:...") をキーに
    /// 共有相手に表示名・写真・色を伝搬する。
    static let profileFeatureEnabled: Bool = true

    /// 定期項目 (RecurringRule / RecurringListView / RecurringExpenseGenerator 等) を有効化するか。
    /// リリースに向けて一旦無効化している。Core Data モデル・CloudKit スキーマ・既存データは
    /// そのまま温存しているため、この値を true に戻すだけで機能を復活できる。
    /// false の間は UI 導線・自動生成・Intent の recurring op をすべて非表示/無効にする。
    static let recurringFeatureEnabled: Bool = false
}

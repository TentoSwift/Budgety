//
//  Member+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI
#if !os(watchOS)
import CloudKit
#endif

extension Member {
    var displayName: String { name?.isEmpty == false ? name! : String(localized: "メンバー") }
    var displayColorHex: String { colorHex ?? "#5B8DEF" }
    var tint: Color { Color(hex: displayColorHex) ?? .blue }

    /// 名前の先頭 1 文字。アバター画像が無い時のフォールバックとして表示する。
    var initial: String {
        guard let first = displayName.first else { return "?" }
        return String(first)
    }

    /// この Member を識別する安定 ID (= Expense.payerProfileID として保存される値)。
    /// 共有シート文脈では「自分」の canonical が share によって変わるため、
    /// 呼出側はそのシートの CKShare を渡すこと。非共有 sheet では nil を渡す。
    ///
    /// 解決順:
    /// 1. self Member かつ share がある → `canonicalSelfID(forShare:)`
    ///    (オーナーなら userRecordName、参加者なら "email:..." を返す)
    /// 2. それ以外 → `recordName` (CKShare.Participant 由来の canonical 等)
    /// 3. それでも空なら UUID 文字列
    #if !os(watchOS)
    @MainActor
    func resolvedProfileID(forShare share: CKShare?) -> String {
        let store = UserProfileStore.shared
        if let selfID = store.selfMemberID, id == selfID {
            if let cid = store.canonicalSelfID(forShare: share), !cid.isEmpty {
                return cid
            }
        }
        if let rn = recordName, !rn.isEmpty,
           rn != "_defaultOwner_", rn != "__defaultOwner__" {
            return rn
        }
        return id?.uuidString ?? ""
    }
    #endif

    /// 非共有 (= 単独シート) 向けの簡易版。呼出側が share を持っていない場合用。
    @MainActor
    var profileID: String {
        let store = UserProfileStore.shared
        if let selfID = store.selfMemberID, id == selfID,
           let rn = store.userRecordName, !rn.isEmpty {
            return rn
        }
        if let rn = recordName, !rn.isEmpty,
           rn != "_defaultOwner_", rn != "__defaultOwner__" {
            return rn
        }
        return id?.uuidString ?? ""
    }
}

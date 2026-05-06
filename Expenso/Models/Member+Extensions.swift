//
//  Member+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI

extension Member {
    var displayName: String { name?.isEmpty == false ? name! : "メンバー" }
    var displayColorHex: String { colorHex ?? "#5B8DEF" }
    var tint: Color { Color(hex: displayColorHex) ?? .blue }

    /// 名前の先頭 1 文字。アバター画像が無い時のフォールバックとして表示する。
    var initial: String {
        guard let first = displayName.first else { return "?" }
        return String(first)
    }

    /// この Member を識別する安定 ID。Expense.payerProfileID として保存される。
    /// 1. 自分の Member なら CK userRecordName (cross-account 一致)
    /// 2. CKShare 参加者に対応する Member なら自身の `recordName` (= ParticipantProfile と一致)
    /// 3. それ以外のローカル Member なら id (UUID) の文字列
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

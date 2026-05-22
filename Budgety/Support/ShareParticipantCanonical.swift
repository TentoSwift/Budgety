//
//  ShareParticipantCanonical.swift
//  Budgety
//
//  CKShare.Participant の canonical ID (= Expense.payerProfileID として使う安定文字列)
//  を計算する extension。ターゲット間共有のため UI から分離。
//

import Foundation
import CloudKit

extension CKShare.Participant {
    /// 共有相手を全端末で一意に識別するための文字列 (= URN)。
    /// `Expense.payerProfileID` や `Member.recordName` に保存し、シート参加者間で
    /// 「払った相手」が解決できるようにする。
    /// iCloud Extended Share Access エンタイトルメントで URN が全 viewer に
    /// 一致するようになったので、**常に URN (userIdentity.userRecordID.recordName)**
    /// を使う。`__defaultOwner__` placeholder の場合は nil を返し、呼び出し側で
    /// `CKContainer.userRecordID().recordName` (= 自分の URN) を使う想定。
    /// 旧 "email:..." / "phone:..." スキームは廃止 (旧データは migration で URN に
    /// 正規化される)。
    var budgetyCanonicalID: String? {
        let rn = userIdentity.userRecordID?.recordName ?? ""
        if rn.isEmpty || UserProfileStore.isSelfPlaceholderRecordName(rn) { return nil }
        return rn
    }
}

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
    /// 共有相手を全端末で一意に識別するための文字列。
    /// `Expense.payerProfileID` や `Member.recordName` に保存し、シート参加者間で
    /// 「払った相手」が解決できるようにする。
    /// - role == .owner: userIdentity.userRecordID.recordName をそのまま使う。
    ///   CKShare ではオーナー自身の view では `__defaultOwner__` placeholder になるため、
    ///   その場合は呼び出し側 (UserProfileStore.canonicalSelfID) で
    ///   CKContainer.userRecordID().recordName を使う想定で nil を返す。
    /// - role != .owner: lookupInfo.emailAddress (= 招待時の Apple ID) を使う。
    ///   CKShare 内で参加者の userRecordID は viewer ごとに別空間になるが、
    ///   email は全 viewer から同一値で見える唯一の安定キー。
    var budgetyCanonicalID: String? {
        let rn = userIdentity.userRecordID?.recordName ?? ""
        if role == .owner {
            if UserProfileStore.isSelfPlaceholderRecordName(rn) { return nil }
            return rn.isEmpty ? nil : rn
        }
        if let email = userIdentity.lookupInfo?.emailAddress, !email.isEmpty {
            return "email:" + email.lowercased()
        }
        if let phone = userIdentity.lookupInfo?.phoneNumber, !phone.isEmpty {
            return "phone:" + phone
        }
        if !rn.isEmpty, !UserProfileStore.isSelfPlaceholderRecordName(rn) {
            return rn
        }
        return nil
    }
}

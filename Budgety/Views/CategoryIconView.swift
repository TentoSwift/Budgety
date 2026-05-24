//
//  CategoryIconView.swift
//  Expenso
//
//  カテゴリのアイコン表示の共通コンポーネント。
//  シート詳細 (`ExpenseRowView`) のスタイル: 単色グラデーション円 + 白アイコン。
//

import SwiftUI
#if !os(watchOS)
import CloudKit
#endif

struct CategoryIconView: View {
    let symbol: String
    let tint: Color
    /// 引数で渡された原寸サイズ。スケール上限の計算に使う。
    private let baseSize: CGFloat
    /// `@ScaledMetric` で Dynamic Type に追従するが、`.body` だと AX5 で 3.5x
    /// まで伸びてアイコンが巨大化するので、`displaySize` で上限を掛ける。
    @ScaledMetric private var scaledSize: CGFloat

    /// 表示用サイズ。base の 1.5 倍で頭打ち。
    private var displaySize: CGFloat {
        min(scaledSize, baseSize * 1.5)
    }

    init(symbol: String, tint: Color, size: CGFloat = 36) {
        self.symbol = symbol
        self.tint = tint
        self.baseSize = size
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    init(category: ExpenseCategory, size: CGFloat = 36) {
        self.symbol = category.displaySymbol
        self.tint = category.tint
        self.baseSize = size
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    /// `Expense.categoryTint` / `categorySymbol` (ParticipantProfile 解決対応版) を表示する。
    init(expense: Expense, size: CGFloat = 36) {
        self.symbol = expense.categorySymbol
        self.tint = expense.categoryTint
        self.baseSize = size
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        ZStack {
            Circle().fill(tint.gradient)
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .font(.system(size: displaySize * 0.42, weight: .semibold))
        }
        .frame(width: displaySize, height: displaySize)
    }
}

/// カテゴリアイコン + 支払い者/受取者アバター (右下に重ね) の共通コンポーネント。
/// シート詳細の支出行と検索結果の両方で使う。
/// 個人専用シート (= 参加済の他メンバーが居ない) で自分払いの場合はアバターを出さない。
struct CategoryPayerIconView: View {
    @ObservedObject var expense: Expense
    @ObservedObject private var pub = PublicProfileSync.shared
    var size: CGFloat = 38
    var avatarSize: CGFloat = 18

    var body: some View {
        let payerName = expense.displayPaidBy
        // 名前が解決できているかではなく「支払い者が居るか」で出し分ける。
        let hasPayer = !(expense.payerProfileID ?? "").isEmpty
            || expense.payerMemberID != nil
            || !(expense.paidBy ?? "").isEmpty
        let showAvatar = hasPayer && !(isSoloSheet && expense.isPayerSelf)
        ZStack(alignment: .bottomTrailing) {
            CategoryIconView(expense: expense, size: size)
            if showAvatar {
                PayerAvatar(
                    member: expense.resolvedPayer,
                    participantProfile: expense.resolvedParticipantProfile,
                    fallbackName: payerName,
                    fallbackColorHex: "#8E8E93",
                    fallbackPhoto: expense.payerPhotoData,
                    size: avatarSize
                )
                .overlay(Circle().stroke(Color.platformSystemBackground, lineWidth: 2))
                .offset(x: 5, y: 5)
            }
        }
    }

    /// 個人専用シート (= 参加済の他メンバーが居ない) かどうか。
    private var isSoloSheet: Bool {
        guard let sheet = expense.sheet else { return true }
        #if !os(watchOS)
        if let share = ShareCoordinator.shared.existingShare(for: sheet) {
            // 「自分」以外で受諾済みの参加者が居るか。オーナーも自分でなければ
            // 他メンバーとして数える（参加者デバイスでオーナーを除外しないため）。
            // 自分の participant は recordName が __defaultOwner__ に匿名化される
            // か、URN (canonicalSelfIDs) と一致するので、それで除外する。
            let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
            let hasAcceptedOthers = share.participants.contains { p in
                guard p.acceptanceStatus == .accepted else { return false }
                let rn = p.userIdentity.userRecordID?.recordName ?? ""
                guard !rn.isEmpty, !UserProfileStore.isSelfPlaceholderRecordName(rn) else { return false }
                return !selfIDs.contains(rn)
            }
            return !hasAcceptedOthers
        }
        #endif
        guard let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return true }
        let myRN = UserProfileStore.shared.userRecordName ?? ""
        return !profiles.contains { p in
            let rn = p.recordName ?? ""
            return !rn.isEmpty && rn != myRN
        }
    }
}

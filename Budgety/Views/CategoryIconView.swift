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
                // カテゴリアイコンと重なる部分を分けるため、アバターの背後に
                // 背景色で塗った Circle を一回り大きく敷いて「枠」にする。
                .background(
                    Circle()
                        .fill(Color.platformSystemBackground)
                        .padding(-2)
                )
                .offset(x: 5, y: 5)
            }
        }
    }

    /// 個人専用シート (= 参加済の他メンバーが居ない) かどうか。
    /// バーチャルメンバーが居れば solo ではない。CKShare の有無に関係なく
    /// バーチャルを優先チェックするのが重要 (= 過去にシェアして参加者が
    /// 全員未承諾/退室した状態でバーチャルだけ居る場合、participants は
    /// 空でも solo 扱いにしてはいけない)。
    private var isSoloSheet: Bool {
        guard let sheet = expense.sheet else { return true }
        return !sheet.hasAcceptedOtherMembers()
    }
}

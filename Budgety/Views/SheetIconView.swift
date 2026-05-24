//
//  SheetIconView.swift
//  Expenso
//
//  シートのアイコン表示。`CategoryIconView` と同じくグラデ円 + 白アイコン。
//  共有中の時 (オーナーで参加者あり / 公開リンク有効 / 自分が参加者) は
//  右下に小さい共有マークを重ねる。
//

import SwiftUI
import CoreData
import CloudKit

struct SheetIconView: View {
    @ObservedObject var record: ExpenseSheet
    var size: CGFloat = 44

    private enum ShareStatus { case none, ownerSharing, participant }
    @State private var status: ShareStatus = .none

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SheetIconView.baseIcon(symbol: record.displaySymbol, tint: record.tint, size: size)
            if status != .none {
                shareBadge
                    .offset(x: size * 0.10, y: size * 0.10)
            }
        }
        .task(id: record.objectID) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            Task { await refresh() }
        }
    }

    /// シート用のベースアイコン (角丸正方形 + 白いシンボル)。
    /// AddSheetView / EditSheetView のプレビューからも使えるよう static にする。
    static func baseIcon(symbol: String, tint: Color, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(tint.gradient)
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .font(.system(size: size * 0.46, weight: .semibold))
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var shareBadge: some View {
        // オーナー / 参加者を区別せず「共有中」共通のマーク
        let badgeSize = size * 0.5
        ZStack {
            Circle()
                .fill(Color.primary)
            // primary 背景は light=黒 / dark=白 と反転するので、アイコンは背景色
            // (反転色) の抜き文字にして両モードで視認できるようにする。
            Image(systemName: "person.2.fill")
                .foregroundStyle(Color.platformSystemBackground)
                .font(.system(size: badgeSize * 0.55, weight: .bold))
        }
        .frame(width: badgeSize, height: badgeSize)
        .overlay(Circle().stroke(Color.platformSystemBackground, lineWidth: 2))
    }

    @MainActor
    private func refresh() async {
        guard let share = ShareCoordinator.shared.existingShare(for: record) else {
            status = .none
            return
        }
        guard let myRole = share.currentUserParticipant?.role else {
            status = .none
            return
        }
        if myRole == .owner {
            let hasAccepted = share.participants.contains { p in
                p.role != .owner && p.acceptanceStatus == .accepted
            }
            let isPublic = share.publicPermission != .none
            status = (hasAccepted || isPublic) ? .ownerSharing : .none
        } else {
            status = .participant
        }
    }
}

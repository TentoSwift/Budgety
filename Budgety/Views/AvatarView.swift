//
//  AvatarView.swift
//  Expenso
//
//  プロフィール画像 (写真 or Memoji 合成 JPEG) を表示する共通コンポーネント。
//  画像が無ければ名前のイニシャル文字を彩色グラデ円で描画する。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct AvatarView: View {
    let photoData: Data?
    let displayName: String
    let colorHex: String
    private let baseSize: CGFloat
    @ScaledMetric private var scaledSize: CGFloat

    /// AX5 で 3.5x まで伸びると顔写真が画面の半分を占めてしまうので、
    /// base の 1.5 倍で頭打ち。
    private var size: CGFloat {
        min(scaledSize, baseSize * 1.5)
    }

    init(photoData: Data?, displayName: String, colorHex: String, size: CGFloat = 40) {
        self.photoData = photoData
        self.displayName = displayName
        self.colorHex = colorHex
        self.baseSize = size
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var initial: String {
        guard let first = displayName.first else { return "?" }
        return String(first).uppercased()
    }

    /// 背景色: 指定された colorHex が空/既定なら名前から決定的に生成。
    /// "プロフィールは写真のみ" 方針 — ユーザーは色を選べず、名前から自動。
    private var tint: Color {
        let trimmed = colorHex.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "#8E8E93" {
            return Color.deterministic(from: displayName)
        }
        return Color(hex: trimmed) ?? Color.deterministic(from: displayName)
    }

    var body: some View {
        if let data = photoData, let image = makePlatformImage(from: data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        } else {
            ZStack {
                Circle().fill(tint.gradient)
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }

    private func makePlatformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}

extension AvatarView {
    /// Member から生成するヘルパー (静的)。
    /// Member が後から更新された時に自動で再描画したい場合は `ObservedMemberAvatar` を使う。
    init(member: Member, size: CGFloat = 40) {
        self.init(
            photoData: member.photoData,
            displayName: member.displayName,
            colorHex: member.displayColorHex,
            size: size
        )
    }

    /// 名前 + 16 進カラー + 任意 photoData から生成するヘルパー (CKShare participant 用)。
    init(name: String, colorHex: String, photoData: Data? = nil, size: CGFloat = 40) {
        self.init(
            photoData: photoData,
            displayName: name,
            colorHex: colorHex,
            size: size
        )
    }
}

/// Member を `@ObservedObject` で監視し、プロフィール更新 (photoData / colorHex / name) に
/// 自動で追従するアバター。Member が無い (= shared store の Expense 等) ケースでは
/// 受け取った fallback で `AvatarView` を描く。
/// 自分 Member は UserProfileStore の写真も併用、他人の Member は recordName が
/// URN ならば PublicProfileSync cache の写真も併用。
struct ObservedMemberAvatar: View {
    @ObservedObject var member: Member
    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pub = PublicProfileSync.shared
    /// AvatarView 側で `@ScaledMetric` 制御するので、ここは plain CGFloat。
    var size: CGFloat = 40

    var body: some View {
        AvatarView(
            photoData: resolvedPhoto,
            displayName: member.displayName,
            colorHex: member.displayColorHex,
            size: size
        )
    }

    private var resolvedPhoto: Data? {
        if let p = member.photoData { return p }
        if member.id == profile.selfMemberID { return profile.photoData }
        if let rn = member.recordName, !rn.isEmpty {
            return pub.profileOrPrefetch(for: rn)?.photoData
        }
        return nil
    }
}

/// `ParticipantProfile` を `@ObservedObject` で監視するアバター。
/// Shared ストアでオーナー / 他参加者のプロフィールが更新された時に自動で再描画する。
/// PP 側に photoData が無くても PublicProfileSync cache (= Public DB から取得した
/// 写真) があればそれを使う。
struct ObservedParticipantProfileAvatar: View {
    @ObservedObject var profile: ParticipantProfile
    @StateObject private var pub = PublicProfileSync.shared
    /// AvatarView 側で `@ScaledMetric` 制御するので、ここは plain CGFloat。
    var size: CGFloat = 40

    var body: some View {
        let urn = profile.recordName ?? ""
        let cached = pub.profileOrPrefetch(for: urn)
        let photo = profile.photoData ?? cached?.photoData
        let name = (cached?.displayName.isEmpty == false ? cached!.displayName
                    : (profile.displayName ?? ""))
        AvatarView(
            photoData: photo,
            displayName: name,
            colorHex: profile.colorHex ?? "#8E8E93",
            size: size
        )
    }
}

/// 支払者アバター用ラッパー。解決順:
/// 1. シート配下の `ParticipantProfile` (per-sheet 値 = override 含む)。これが
///    シート単位プロフィールの正)。
/// 2. ローカル `Member` (Private ストアのアカウント全体プロフィール)。シート外の
///    リスト等で PP が無い時のみ使う。
/// 3. 名前+色のフォールバック。
struct PayerAvatar: View {
    let member: Member?
    let participantProfile: ParticipantProfile?
    let fallbackName: String
    let fallbackColorHex: String
    let fallbackPhoto: Data?
    /// AvatarView 側で `@ScaledMetric` 制御するので、ここは plain CGFloat。
    var size: CGFloat = 40

    var body: some View {
        if let participantProfile {
            ObservedParticipantProfileAvatar(profile: participantProfile, size: size)
        } else if let member {
            ObservedMemberAvatar(member: member, size: size)
        } else {
            AvatarView(name: fallbackName, colorHex: fallbackColorHex, photoData: fallbackPhoto, size: size)
        }
    }
}

/// 「未選択」を表す破線サークル + person アイコン。
/// AvatarView と同じ @ScaledMetric (body 基準・最大 1.5x) でスケールするので、
/// アクセシビリティ文字サイズ拡大時も他のアバターと同じ大きさになる。
struct UnspecifiedAvatarView: View {
    private let baseSize: CGFloat
    @ScaledMetric private var scaledSize: CGFloat

    init(size: CGFloat = 40) {
        self.baseSize = size
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var size: CGFloat { min(scaledSize, baseSize * 1.5) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: size, height: size)
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
    }
}

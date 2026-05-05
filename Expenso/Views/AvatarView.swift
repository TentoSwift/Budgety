//
//  AvatarView.swift
//  Expenso
//
//  プロフィール画像 (写真 or Memoji 合成 JPEG) を表示する共通コンポーネント。
//  画像が無ければ名前のイニシャル文字を彩色グラデ円で描画する。
//

import SwiftUI
import UIKit

struct AvatarView: View {
    let photoData: Data?
    let displayName: String
    let colorHex: String
    var size: CGFloat = 40

    private var initial: String {
        guard let first = displayName.first else { return "?" }
        return String(first).uppercased()
    }

    private var tint: Color { Color(hex: colorHex) ?? .blue }

    var body: some View {
        if let data = photoData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
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
}

extension AvatarView {
    /// Member から生成するヘルパー。
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

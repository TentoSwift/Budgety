//
//  ProfileEditView.swift
//  Budgety
//
//  ローカルの自分プロフィール (表示名 / アバター色) を編集する最小 UI。
//  CKShare 経由で共有相手に届くのは iCloud アカウント名で、ここで設定する displayName は
//  自端末で「自分」を表示するときのプリファレンスとして使われる。
//
//  写真機能は撤廃 (常にイニシャル + 背景色のアバター)。
//

import SwiftUI
import CoreData

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @State private var draftName: String = ""
    @State private var draftColor: String = "#5B8DEF"
    @State private var didLoad: Bool = false

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                nameSection
                colorSection
            }
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityLabel("キャンセル")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Image(systemName: "checkmark")
                            .accessibilityLabel("保存")
                    }
                }
            }
            .onAppear { loadIfNeeded() }
        }
    }

    private var avatarSection: some View {
        Section {
            HStack {
                Spacer()
                AvatarView(
                    photoData: nil,
                    displayName: draftName.isEmpty ? "自分" : draftName,
                    colorHex: draftColor,
                    size: 96
                )
                .padding(.vertical, 8)
                Spacer()
            }
        }
    }

    private var nameSection: some View {
        Section("表示名") {
            TextField("自分の名前", text: $draftName)
                .textInputAutocapitalization(.never)
        }
    }

    private var colorSection: some View {
        Section("アバターの背景色") {
            HStack(spacing: 12) {
                ForEach(palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .blue)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if hex == draftColor {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .onTapGesture { draftColor = hex }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftName = profile.displayName
        draftColor = profile.avatarBgColorHex ?? "#5B8DEF"
    }

    private func save() {
        profile.updateProfile(
            displayName: draftName.trimmingCharacters(in: .whitespaces),
            photoData: nil,
            avatarBgColorHex: draftColor
        )
        // Self Member の denormalized キャッシュも揃え、override されていない全シートの
        // 自分の PP に変更を伝搬 (= 共有相手の端末にも CloudKit 経由で届く)。
        profile.applyDeviceLocalProfileEdit(in: viewContext)
        Haptics.success()
        dismiss()
    }
}

//
//  ProfileEditView.swift
//  Budgety
//
//  ローカルの自分プロフィール (表示名 / アバター色 / 写真) を編集する最小 UI。
//  CKShare 経由で共有相手に届くのは iCloud アカウント名で、ここで設定する displayName は
//  自端末で「自分」を表示するときのプリファレンスとして使われる。
//

import SwiftUI
import CoreData
import PhotosUI

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @State private var draftName: String = ""
    @State private var draftColor: String = "#5B8DEF"
    @State private var draftPhoto: Data? = nil
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var isLoadingPhoto: Bool = false
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
                // 写真が設定されているときは背景色は塗りに使われないので picker を隠す
                if draftPhoto == nil {
                    colorSection
                }
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
            .onChange(of: pickerItem) { _, _ in loadPhotoFromPicker() }
        }
    }

    private var avatarSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    AvatarView(
                        photoData: draftPhoto,
                        displayName: draftName.isEmpty ? "自分" : draftName,
                        colorHex: draftColor,
                        size: 96
                    )
                    if isLoadingPhoto {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label("写真を選択", systemImage: "photo")
                                    .font(.callout)
                            }
                            if draftPhoto != nil {
                                Button(role: .destructive) {
                                    draftPhoto = nil
                                    pickerItem = nil
                                } label: {
                                    Label("削除", systemImage: "trash")
                                        .font(.callout)
                                }
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
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
        draftPhoto = profile.photoData
    }

    private func loadPhotoFromPicker() {
        guard let item = pickerItem else { return }
        isLoadingPhoto = true
        Task { @MainActor in
            defer { isLoadingPhoto = false }
            if let data = try? await item.loadTransferable(type: Data.self) {
                draftPhoto = downsize(data, maxDimension: 512)
            }
        }
    }

    /// 巨大な画像を 512px 程度に縮小して JPEG にする。CKAsset に乗せる前提でサイズを抑える。
    private func downsize(_ data: Data, maxDimension: CGFloat) -> Data {
        #if canImport(UIKit)
        guard let img = UIImage(data: data) else { return data }
        let w = img.size.width, h = img.size.height
        let maxSide = max(w, h)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.82) ?? data
        #else
        return data
        #endif
    }

    private func save() {
        profile.updateProfile(
            displayName: draftName.trimmingCharacters(in: .whitespaces),
            photoData: draftPhoto,
            avatarBgColorHex: draftColor
        )
        // Self Member の denormalized キャッシュも揃え、override されていない全シートの
        // 自分の PP に変更を伝搬 (= 共有相手の端末にも CloudKit 経由で届く)。
        profile.applyDeviceLocalProfileEdit(in: viewContext)
        Haptics.success()
        dismiss()
    }
}

//
//  ProfileEditView.swift
//  Budgety
//
//  カスタムプロフィール (名前 + 写真 + 背景色) を編集する画面。
//  保存は UserProfileStore のローカル + CloudKit Public DB の UserProfile レコード。
//  優先順位: カスタム > Apple ID 名 > "メンバー"。
//
//  ShareCalendarApp の UserProfileView を参考にしたミニマル版。
//  Memoji 編集は iOS 専用 (MemojiView がパッケージ未リンク)。
//

import SwiftUI
import CoreData
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @State private var draftName: String = ""
    @State private var draftColor: String = "#5B8DEF"
    @State private var draftPhoto: Data? = nil
    @State private var didLoad: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    #if canImport(PhotosUI)
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var isLoadingPhoto: Bool = false
    #endif

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00",
        "#FF6B6B", "#1DD1A1", "#7D3C98", "#636E72"
    ]

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                nameSection
                colorSection
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 600)
            #endif
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("完了") { Task { await save() } }
                            .keyboardShortcut(.return)
                    }
                }
            }
            .onAppear { loadIfNeeded() }
            #if canImport(PhotosUI)
            .onChange(of: pickerItem) { _, _ in loadPhotoFromPicker() }
            #endif
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var avatarSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    avatarPreview
                    #if canImport(PhotosUI)
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
                    #endif
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        let initial = String(draftName.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased()
        let color = Color(hex: draftColor) ?? .blue
        if let photo = draftPhoto, let image = platformImage(from: photo) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
        } else {
            ZStack {
                Circle().fill(color.gradient)
                Text(initial.isEmpty ? "?" : initial)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 120, height: 120)
        }
    }

    @ViewBuilder
    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { Image(uiImage: ui) }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) { Image(nsImage: ns) }
        #endif
    }

    private var nameSection: some View {
        Section("ニックネーム") {
            TextField("自分の名前", text: $draftName)
                .autocorrectionDisabled()
        }
    }

    private var colorSection: some View {
        Section("背景色") {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(palette, id: \.self) { hex in
                    Button {
                        draftColor = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .blue)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if hex == draftColor {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Load / Save

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftName = profile.displayName
        draftColor = profile.avatarBgColorHex ?? "#5B8DEF"
        draftPhoto = profile.photoData
    }

    #if canImport(PhotosUI)
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

    /// 巨大な画像を 512px 程度に縮小して JPEG にする。CKAsset サイズを抑える。
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
        #elseif canImport(AppKit)
        guard let img = NSImage(data: data) else { return data }
        let w = img.size.width, h = img.size.height
        let maxSide = max(w, h)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let newSize = NSSize(width: w * scale, height: h * scale)
        let target = NSImage(size: newSize)
        target.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: newSize))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return data
        }
        return jpeg
        #else
        return data
        #endif
    }
    #endif

    private func save() async {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        // ローカル更新
        profile.updateProfile(displayName: name, photoData: draftPhoto, avatarBgColorHex: draftColor)
        profile.applyDeviceLocalProfileEdit(in: viewContext)

        // CloudKit Public DB upload
        if let urn = profile.userRecordName, !urn.isEmpty {
            await PublicProfileSync.shared.uploadOwnProfile(
                urn: urn,
                displayName: name,
                photoData: draftPhoto,
                colorHex: draftColor
            )
        }
        Haptics.success()
        dismiss()
    }
}

//
//  VirtualMemberEditView.swift
//  Budgety
//
//  バーチャルメンバー (ParticipantProfile) の編集画面。
//  自分のプロフィール編集 (ProfileEditView) と同じ UI: 名前 + 写真 +
//  Memoji / 絵文字 + 背景色。保存はシート配下の ParticipantProfile に
//  書き込む (CloudKit で同期)。Public DB へのアップロードはしない。
//
//  MemojiView パッケージは iOS ターゲットのみリンクのため、Memoji ボタンは
//  `#if canImport(MemojiView)` でガード (= iOS でのみ表示)。
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

struct VirtualMemberEditView: View {
    @ObservedObject var profile: ParticipantProfile

    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String = ""
    @State private var draftPhoto: Data? = nil
    @State private var draftBgHex: String = "#FF9500"
    @State private var didLoad: Bool = false

    #if canImport(PhotosUI)
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var isLoadingPhoto: Bool = false
    #endif

    #if canImport(MemojiView)
    @State private var showingMemojiEditor: Bool = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                nameSection
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 560)
            #endif
            .navigationTitle("メンバー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { save() }
                        .keyboardShortcut(.return)
                }
            }
            .onAppear { loadIfNeeded() }
            #if canImport(PhotosUI)
            .onChange(of: pickerItem) { _, _ in loadPhotoFromPicker() }
            #endif
            #if canImport(MemojiView)
            .sheet(isPresented: $showingMemojiEditor) {
                MemojiEditorView { data, hex in
                    draftPhoto = data
                    draftBgHex = hex
                    pickerItem = nil
                }
            }
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
                        VStack(spacing: 10) {
                            HStack(spacing: 16) {
                                PhotosPicker(selection: $pickerItem, matching: .images) {
                                    Label("写真を選択", systemImage: "photo")
                                        .font(.callout)
                                }
                                #if canImport(MemojiView)
                                Button {
                                    showingMemojiEditor = true
                                } label: {
                                    Label("Memoji・絵文字", systemImage: "face.smiling")
                                        .font(.callout)
                                }
                                .buttonStyle(.borderless)
                                #endif
                            }
                            if draftPhoto != nil {
                                Button(role: .destructive) {
                                    draftPhoto = nil
                                    pickerItem = nil
                                } label: {
                                    Label("削除", systemImage: "trash")
                                        .font(.callout)
                                }
                                .buttonStyle(.borderless)
                                #if os(macOS)
                                .tint(.red)
                                #endif
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
        let trimmedName = draftName.trimmingCharacters(in: .whitespaces)
        let initial = String(trimmedName.first ?? "?").uppercased()
        let color = Color(hex: draftBgHex)
            ?? Color.deterministic(from: trimmedName.isEmpty ? "?" : trimmedName)
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

    private func platformImage(from data: Data) -> Image? {
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

    private var nameSection: some View {
        Section("名前") {
            TextField("名前", text: $draftName, prompt: Text("メンバーの名前"))
                .labelsHidden()
                .autocorrectionDisabled()
        }
    }

    // MARK: - Load / Save

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftName = profile.displayName ?? ""
        draftPhoto = profile.photoData
        if let c = profile.colorHex, !c.isEmpty { draftBgHex = c }
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        profile.displayName = name.isEmpty ? (profile.displayName ?? "メンバー") : name
        profile.photoData = draftPhoto
        profile.colorHex = draftBgHex
        profile.updatedAt = .now
        PersistenceController.shared.save()
        Haptics.success()
        dismiss()
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

    /// 画像を maxDimension 程度に縮小して JPEG にする (CKAsset サイズを抑える)。
    private func downsize(_ data: Data, maxDimension: CGFloat) -> Data {
        #if canImport(UIKit)
        guard let img = UIImage(data: data) else { return data }
        let maxSide = max(img.size.width, img.size.height)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.82) ?? data
        #elseif canImport(AppKit)
        guard let img = NSImage(data: data) else { return data }
        let maxSide = max(img.size.width, img.size.height)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let newSize = NSSize(width: img.size.width * scale, height: img.size.height * scale)
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
}

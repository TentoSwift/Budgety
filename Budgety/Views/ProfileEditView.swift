//
//  ProfileEditView.swift
//  Budgety
//
//  カスタムプロフィール (名前 + 写真 + 背景色) を編集する画面。
//  保存は UserProfileStore のローカル + CloudKit Public DB の UserProfile レコード。
//  優先順位: カスタム > Apple ID 名 > "メンバー"。
//
//  ShareCalendarApp の UserProfileView を参考にしたミニマル版。
//  写真のほかに Memoji / 絵文字 + 背景色でアバターを作成できる
//  (MemojiEditorView。MemojiView パッケージは iOS ターゲットのみリンク)。
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
#if canImport(ImagePlayground)
import ImagePlayground
#endif

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @State private var draftName: String = ""
    @State private var draftPhoto: Data? = nil
    /// アバター背景色 (Memoji 作成時に選んだ色)。写真未設定時のフォールバックにも使う。
    @State private var draftBgHex: String? = nil
    @State private var didLoad: Bool = false
    @State private var saveError: String? = nil

    #if canImport(PhotosUI)
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var isLoadingPhoto: Bool = false
    /// アバターのメニューから「写真を選択」した時に PhotosPicker を開く。
    @State private var showPhotoPicker: Bool = false
    #endif

    #if canImport(MemojiView)
    @State private var showingMemojiEditor: Bool = false
    #endif

    /// Image Playground (iOS 18.2+ / macOS 15.2+) で画像生成を行うシート表示用。
    @State private var showingImagePlayground: Bool = false

    #if canImport(UIKit)
    /// クロップ対象の画像。新規選択直後や「切り取り」でセットするとシートが開く。
    @State private var cropImage: CroppableImage? = nil
    #endif

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                nameSection
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
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "checkmark") { save() }
                        .keyboardShortcut(.return)
                }
            }
            .onAppear { loadIfNeeded() }
            #if canImport(PhotosUI)
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
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
            #if canImport(UIKit)
            // 写真を選んだ / 「切り取り」を選んだ時に円形クロップシートを挟む。
            .sheet(item: $cropImage) { item in
                ImageCropView(
                    image: item.image,
                    onCancel: { cropImage = nil },
                    onCrop: { data in
                        draftPhoto = data
                        // 写真を採用したら背景色フォールバックは不要。
                        draftBgHex = nil
                        #if canImport(PhotosUI)
                        pickerItem = nil
                        #endif
                        cropImage = nil
                    }
                )
            }
            #endif
            // concept は渡さない (= 人物 / テキスト / テーマ何からでも生成可能に)。
            .imagePlaygroundSheet(
                isPresented: $showingImagePlayground,
                onCompletion: { url in
                    Task { @MainActor in
                        if let data = try? Data(contentsOf: url) {
                            draftPhoto = downsize(data, maxDimension: 512)
                            #if canImport(PhotosUI)
                            pickerItem = nil
                            #endif
                        }
                    }
                }
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var avatarSection: some View {
        Section {
            HStack {
                Spacer()
                #if canImport(PhotosUI)
                if isLoadingPhoto {
                    VStack(spacing: 12) {
                        avatarPreview
                        ProgressView().controlSize(.small)
                    }
                } else {
                    // アバターをタップすると写真選択 / Memoji / 削除を選べるメニューを開く。
                    Menu {
                        avatarMenuContent
                    } label: {
                        avatarPreviewWithBadge
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
                #else
                avatarPreview
                #endif
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    /// アバターのメニュー項目 (写真を選択 / Memoji・絵文字 / 削除)。
    @ViewBuilder
    private var avatarMenuContent: some View {
        #if canImport(PhotosUI)
        Button {
            showPhotoPicker = true
        } label: {
            Label("写真を選択", systemImage: "photo")
        }
        #endif
        #if canImport(MemojiView)
        Button {
            showingMemojiEditor = true
        } label: {
            Label("Memoji・絵文字", systemImage: "face.smiling")
        }
        #endif
        Button {
            showingImagePlayground = true
        } label: {
            Label("Image Playground で生成", systemImage: "sparkles")
        }
        if draftPhoto != nil {
            #if canImport(UIKit)
            // 既存写真を選び直さずに再度クロップする導線。
            if let data = draftPhoto, let ui = UIImage(data: data) {
                Button {
                    cropImage = CroppableImage(image: ui)
                } label: {
                    Label("切り取り", systemImage: "crop")
                }
            }
            #endif
            Divider()
            Button(role: .destructive) {
                draftPhoto = nil
                draftBgHex = nil
                #if canImport(PhotosUI)
                pickerItem = nil
                #endif
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    /// プレビュー + 右下に編集を示すカメラバッジ。
    private var avatarPreviewWithBadge: some View {
        avatarPreview
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().stroke(Color.platformSystemBackground, lineWidth: 2))
            }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        let trimmedName = draftName.trimmingCharacters(in: .whitespaces)
        let initial = String(trimmedName.first ?? "?").uppercased()
        // 写真未設定時は名前から決定的に背景色生成
        let color = Color.deterministic(from: trimmedName.isEmpty ? "?" : trimmedName)
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
        Section("ニックネーム") {
            // macOS Form は第1引数を LabeledContent のラベルにしてしまうため
            // .labelsHidden() で潰し、placeholder は prompt: で出す。
            TextField("ニックネーム", text: $draftName, prompt: Text("自分の名前"))
                .labelsHidden()
                .autocorrectionDisabled()
        }
    }

    // MARK: - Load / Save

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftName = profile.displayName
        draftPhoto = profile.photoData
        draftBgHex = profile.avatarBgColorHex
    }

    #if canImport(PhotosUI)
    private func loadPhotoFromPicker() {
        guard let item = pickerItem else { return }
        isLoadingPhoto = true
        Task { @MainActor in
            defer { isLoadingPhoto = false }
            if let data = try? await item.loadTransferable(type: Data.self) {
                #if canImport(UIKit)
                // 選択直後にクロップシートを挟む (円形アバター用の正方形切り取り)。
                if let ui = UIImage(data: data) {
                    cropImage = CroppableImage(image: ui)
                } else {
                    draftPhoto = downsize(data, maxDimension: 512)
                }
                #else
                draftPhoto = downsize(data, maxDimension: 512)
                #endif
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

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        saveError = nil

        // ローカル更新 + Public DB upload (updateProfile が背景で upload。
        // シート数も含めて publish される)。
        profile.updateProfile(displayName: name, photoData: draftPhoto, avatarBgColorHex: draftBgHex)
        profile.applyDeviceLocalProfileEdit(in: viewContext)

        Haptics.success()
        dismiss()
    }
}

#if canImport(UIKit)
/// `.sheet(item:)` でクロップ対象を渡すための Identifiable ラッパー。
private struct CroppableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
#endif

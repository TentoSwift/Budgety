//
//  UserProfileEditView.swift
//  Expenso
//
//  ShareCalendarApp の UserProfileView を参考にした、写真選択 / Memoji 合成によるアバター編集 UI。
//

import SwiftUI
import CoreData
import PhotosUI
import UIKit
import MemojiView

struct UserProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @State private var draftName: String = ""
    @State private var draftPhotoData: Data? = nil
    @State private var draftBgColorHex: String? = nil
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var isLoadingPhoto: Bool = false
    @State private var showMemojiEditor: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var didLoad: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                nameSection
            }
            .navigationTitle("プロフィール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadIfNeeded() }
            .onChange(of: pickerItem) { _, _ in loadPhotoFromPicker() }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
            .sheet(isPresented: $showMemojiEditor) {
                MemojiEditorSheet(draftPhotoData: $draftPhotoData, draftBgColorHex: $draftBgColorHex)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var avatarSection: some View {
        Section {
            HStack {
                Spacer()
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("写真を選択", systemImage: "photo")
                    }
                    Button {
                        showMemojiEditor = true
                    } label: {
                        Label("ミー文字や絵文字から作成", systemImage: "face.smiling")
                    }
                    if draftPhotoData != nil {
                        Divider()
                        Button(role: .destructive) {
                            draftPhotoData = nil
                        } label: {
                            Label("画像を削除", systemImage: "trash")
                        }
                    }
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        avatarPreview
                            .frame(width: 120, height: 120)
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Circle().fill(Color.accentColor))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 12)
        } footer: {
            Text("アカウント全体で使うアバターです。共有シートの相手にも表示されます。")
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if isLoadingPhoto {
            ProgressView().frame(width: 120, height: 120)
        } else {
            AvatarView(
                photoData: draftPhotoData,
                displayName: draftName,
                colorHex: draftBgColorHex ?? "#5B8DEF",
                size: 120
            )
        }
    }

    @ViewBuilder
    private var nameSection: some View {
        Section("名前") {
            TextField("自分", text: $draftName)
                .autocorrectionDisabled()
        }
    }

    // MARK: - Logic

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftName       = profile.displayName
        draftPhotoData  = profile.photoData
        draftBgColorHex = profile.avatarBgColorHex
    }

    private func loadPhotoFromPicker() {
        guard let item = pickerItem else { return }
        isLoadingPhoto = true
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let compressed = UIImage(data: data)?.jpegData(compressionQuality: 0.8) ?? data
                await MainActor.run {
                    draftPhotoData = compressed
                    // 写真を選んだら背景色は不要 (画像が直接出るため)
                    isLoadingPhoto = false
                }
            } else {
                await MainActor.run { isLoadingPhoto = false }
            }
        }
    }

    private func save() {
        profile.displayName      = draftName.trimmingCharacters(in: .whitespaces)
        profile.photoData        = draftPhotoData
        profile.avatarBgColorHex = draftBgColorHex
        profile.applyToSelfMember(in: viewContext)
        Haptics.success()
        Task {
            await profile.saveToCloudKit()
        }
        dismiss()
    }
}

// MARK: - MemojiEditorSheet

private struct MemojiEditorSheet: View {
    @Binding var draftPhotoData: Data?
    @Binding var draftBgColorHex: String?
    @Environment(\.dismiss) private var dismiss

    @State private var bgColor: Color = .yellow
    @State private var memojiImage: UIImage? = nil
    @State private var memojiType: MemojiImageType? = nil
    @State private var animationTrigger: Int = 0
    @State private var keyboardFocusTrigger: Bool = false

    private let baseImageSize: CGFloat = 180
    private let presetColors: [Color] = [
        Color(hex: "#FF6B6B")!, Color(hex: "#FF9F43")!,
        Color(hex: "#FECA57")!, Color(hex: "#48DBFB")!,
        Color(hex: "#1DD1A1")!, Color(hex: "#54A0FF")!,
        Color(hex: "#5F27CD")!, Color(hex: "#FF9FF3")!,
        Color(hex: "#576574")!, Color(hex: "#222F3E")!
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    avatarPreview
                        .padding(.top, 20)
                    Text(memojiImage == nil ? "中央をタップしてミー文字を選択" : "背景色を選んでください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    colorPickerRow
                    Spacer()
                }
            }
            .navigationTitle("Memoji を作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { confirm() }
                        .disabled(memojiImage == nil)
                }
            }
            .onAppear {
                if let hex = draftBgColorHex, let c = Color(hex: hex) {
                    bgColor = c
                }
            }
        }
    }

    private var avatarPreview: some View {
        ZStack {
            Circle()
                .fill(bgColor.gradient)
                .frame(width: 260, height: 260)
            if let img = memojiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: baseImageSize, height: baseImageSize)
                    .id(animationTrigger)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.6), value: animationTrigger)
            }
            TransparentMemojiRepresentable(
                image: $memojiImage,
                memojiType: $memojiType,
                autoFocus: memojiImage == nil,
                focusTrigger: keyboardFocusTrigger
            ) { _, _ in
                animationTrigger += 1
            }
            .frame(width: 260, height: 260)
            .clipShape(Circle())
            .allowsHitTesting(memojiImage == nil)
            .contentShape(Circle())
            .onTapGesture { keyboardFocusTrigger.toggle() }
        }
    }

    private var colorPickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(presetColors.indices, id: \.self) { i in
                    let c = presetColors[i]
                    let isSelected = UIColor(bgColor).isEqual(UIColor(c))
                    Button { bgColor = c } label: {
                        Circle()
                            .fill(c)
                            .frame(width: 50, height: 50)
                            .overlay(
                                Circle()
                                    .stroke(isSelected ? Color.primary : .clear, lineWidth: 3)
                                    .padding(-4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private func confirm() {
        guard let src = memojiImage else { return }
        let snapshot = ZStack {
            Circle().fill(bgColor.gradient)
                .frame(width: 300, height: 300)
            Image(uiImage: src)
                .resizable()
                .scaledToFit()
                .frame(width: baseImageSize, height: baseImageSize)
        }
        .frame(width: 300, height: 300)
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 3.0
        guard let uiImage = renderer.uiImage else { return }
        draftPhotoData = uiImage.jpegData(compressionQuality: 0.85)
        draftBgColorHex = bgColor.toHex()
        dismiss()
    }
}

// MARK: - TransparentMemojiRepresentable

/// MemojiView の imageView サブビューを非表示にした透明ラッパー。
/// MemojiView 自体の表示はカスタム描画 (avatarPreview) に任せ、入力だけを担う。
private struct TransparentMemojiRepresentable: UIViewRepresentable {
    @Binding var image: UIImage?
    @Binding var memojiType: MemojiImageType?
    var autoFocus: Bool = false
    var focusTrigger: Bool = false
    var onChange: ((UIImage?, MemojiImageType) -> Void)?

    func makeUIView(context: Context) -> MemojiView {
        let view = MemojiView()
        view.delegate = context.coordinator
        view.isEditable = true
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            view.subviews.compactMap { $0 as? UIImageView }.forEach { $0.isHidden = true }
            if autoFocus {
                _ = Self.firstUITextView(in: view)?.becomeFirstResponder()
            }
        }
        return view
    }

    func updateUIView(_ uiView: MemojiView, context: Context) {
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async {
                _ = Self.firstUITextView(in: uiView)?.becomeFirstResponder()
            }
        }
    }

    private static func firstUITextView(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView { return tv }
        for sub in view.subviews {
            if let found = firstUITextView(in: sub) { return found }
        }
        return nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, MemojiViewDelegate {
        var parent: TransparentMemojiRepresentable
        var lastFocusTrigger: Bool = false
        init(parent: TransparentMemojiRepresentable) { self.parent = parent }

        func didUpdateImage(image: UIImage?, type: MemojiImageType) {
            DispatchQueue.main.async {
                self.parent.image = image
                self.parent.memojiType = type
                self.parent.onChange?(image, type)
            }
        }
    }
}

// MARK: - Color hex helper

private extension Color {
    func toHex() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

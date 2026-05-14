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

    /// 編集対象シート。`nil` の場合はローカルキャッシュのみ更新 (= 初回シート作成前のテンプレ入力)
    let sheet: ExpenseSheet?

    @State private var draftName: String = ""
    @State private var draftPhotoData: Data? = nil
    @State private var draftBgColorHex: String? = nil
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var isLoadingPhoto: Bool = false
    @State private var showMemojiEditor: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var didLoad: Bool = false

    init(sheet: ExpenseSheet? = nil) {
        self.sheet = sheet
    }

    var body: some View {
        NavigationStack {
            if !BuildInfo.profileFeatureEnabled {
                Form {
                    Section {
                        Label("プロフィール機能は一時的に無効化されています。", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("シート上の参加者は iCloud アカウント名で自動的に表示されます。")
                            .font(.caption)
                    }
                }
                .navigationTitle("プロフィール")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
            } else {
            Form {
                avatarSection
                nameSection
            }
            .navigationTitle(sheet == nil ? "プロフィール" : "このシートでのプロフィール")
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
            if sheet == nil {
                Text("このシートで使うアバターです。共有相手にもこの表示が見えます。")
            } else {
                Text("このシート専用のアバターです。共有相手にもこのシート内でこの表示が見えます。")
            }
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
        // シートが指定されていればそのシートの ParticipantProfile を優先 (per-sheet 値を編集)、
        // 無ければローカルキャッシュ (= UserProfileStore = 直近の入力) から下書きする。
        if let sheet,
           let rn = profile.userRecordName, !rn.isEmpty,
           let pp = (sheet.participantProfiles as? Set<ParticipantProfile>)?
                .first(where: { $0.recordName == rn }) {
            draftName       = pp.displayName ?? ""
            draftPhotoData  = pp.photoData
            draftBgColorHex = pp.colorHex
        } else {
            draftName       = profile.displayName
            draftPhotoData  = profile.photoData
            draftBgColorHex = profile.avatarBgColorHex
        }
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
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if let sheet {
            // シート単位の編集: そのシートの PP のみに書き込み (`isOverridden=true`)。
            // UserProfileStore globals / Member には触らない (= 他シートには波及しない)。
            Task { @MainActor in
                await profile.ensureUserRecordNameLoaded()
                profile.applyPerSheetProfileEdit(
                    in: viewContext,
                    sheet: sheet,
                    draftName: trimmed,
                    draftPhotoData: draftPhotoData,
                    draftBgColorHex: draftBgColorHex
                )
            }
        } else {
            // 端末ローカルキャッシュのみ更新 (= 新規シート作成前のプロフィール下書き)。
            // 既存シートの PP には波及させない (シートごと独立)。
            profile.displayName      = trimmed
            profile.photoData        = draftPhotoData
            profile.avatarBgColorHex = draftBgColorHex
            Task { @MainActor in
                await profile.ensureUserRecordNameLoaded()
                profile.applyDeviceLocalProfileEdit(in: viewContext)
            }
        }
        Haptics.success()
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

    // Memoji の拡大/移動: 確定値 (state) と進行中値 (gesture) を分けて持つ
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureDrag: CGSize = .zero

    private let baseImageSize: CGFloat = 180
    private let minScale: CGFloat = 0.4
    private let maxScale: CGFloat = 4.0
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
                VStack(spacing: 16) {
                    avatarPreview
                        .padding(.top, 20)
                    instructionText
                    if memojiImage != nil {
                        resetButton
                    }
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

    private var instructionText: some View {
        Text(memojiImage == nil
             ? "中央をタップしてミー文字を選択"
             : "ピンチで拡大、ドラッグで位置調整できます")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var resetButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                imageScale = 1.0
                imageOffset = .zero
            }
        } label: {
            Label("位置とサイズをリセット", systemImage: "arrow.counterclockwise")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var avatarPreview: some View {
        ZStack {
            Circle()
                .fill(bgColor.gradient)
                .frame(width: 260, height: 260)
            if let img = memojiImage {
                let currentScale = imageScale * gestureScale
                let currentOffset = CGSize(
                    width: imageOffset.width + gestureDrag.width,
                    height: imageOffset.height + gestureDrag.height
                )
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: baseImageSize * currentScale, height: baseImageSize * currentScale)
                    .offset(currentOffset)
                    .id(animationTrigger)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.6), value: animationTrigger)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in state = value }
                            .onEnded { value in
                                imageScale = max(minScale, min(imageScale * value, maxScale))
                            }
                            .simultaneously(with:
                                DragGesture(minimumDistance: 4)
                                    .updating($gestureDrag) { value, state, _ in state = value.translation }
                                    .onEnded { value in
                                        imageOffset = CGSize(
                                            width: imageOffset.width + value.translation.width,
                                            height: imageOffset.height + value.translation.height
                                        )
                                    }
                            )
                    )
            }
            TransparentMemojiRepresentable(
                image: $memojiImage,
                memojiType: $memojiType,
                autoFocus: memojiImage == nil,
                focusTrigger: keyboardFocusTrigger
            ) { _, _ in
                // 新しい Memoji が来たら拡大/位置をリセット
                imageScale = 1.0
                imageOffset = .zero
                animationTrigger += 1
            }
            .frame(width: 260, height: 260)
            .clipShape(Circle())
            // 画像未選択 (= まだ Memoji が無い) 間だけ MemojiView 側のヒットを許可。
            // 選択後はジェスチャを画像側に通す。
            .allowsHitTesting(memojiImage == nil)
            .contentShape(Circle())
            .onTapGesture {
                if memojiImage == nil {
                    keyboardFocusTrigger.toggle()
                }
            }
        }
        .clipShape(Circle())
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
        // ユーザーのジェスチャ確定値 (imageScale / imageOffset) を反映して描画 → JPEG 化
        let snapshot = ZStack {
            Circle().fill(bgColor.gradient)
                .frame(width: 300, height: 300)
            Image(uiImage: src)
                .resizable()
                .scaledToFit()
                .frame(width: baseImageSize * imageScale, height: baseImageSize * imageScale)
                .offset(imageOffset)
        }
        .frame(width: 300, height: 300)
        .clipShape(Circle())
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

//
//  EditSheetView.swift
//  Expenso
//

import SwiftUI
import CoreData
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct EditSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @ObservedObject var record: ExpenseSheet

    @StateObject private var profile = UserProfileStore.shared

    @State private var name: String = ""
    @State private var note: String = ""
    @State private var selectedColor: String = "#5B8DEF"
    @State private var selectedSymbol: String = "person.2.fill"
    @State private var defaultCurrencyCode: String = CurrencyCatalog.defaultCode
    @State private var budgetText: String = ""
    @State private var archivedDraft: Bool = false
    @State private var didLoad: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var showingPaywall: Bool = false
    @State private var showingMoreIcons: Bool = false
    // バーチャルメンバー管理 (Premium)
    @State private var showMemberPrompt = false
    @State private var newMemberName = ""
    /// 名前変更対象の recordName。nil = 新規追加。
    @State private var editingMemberID: String?
    /// 編集中のバーチャルメンバー (プロフィール編集シート提示用)。
    @State private var editingVirtualMember: EditingVirtualMember?
    /// 削除確認アラート対象のバーチャルメンバー。
    @State private var pendingVirtualDelete: PendingVirtualDelete?

    /// `.sheet(item:)` 用の recordName ラッパー。
    private struct EditingVirtualMember: Identifiable { let id: String }
    /// 削除確認用 (recordName + 表示名スナップショット)。
    private struct PendingVirtualDelete: Identifiable {
        let id: String  // recordName
        let displayName: String
    }

    /// このシート配下の自分の ParticipantProfile (= 「このシートでの自分」)
    private var selfParticipantProfile: ParticipantProfile? {
        guard let rn = profile.userRecordName, !rn.isEmpty,
              let profiles = record.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == rn })
    }

    // CRDT 用スナップショット (差分のみ書き戻し)
    @State private var origName: String = ""
    @State private var origNote: String = ""
    @State private var origColor: String = ""
    @State private var origSymbol: String = ""
    @State private var origCurrencyCode: String = ""
    @State private var origBudgetText: String = ""
    @State private var origArchived: Bool = false

    /// JPY/KRW など最小単位のない通貨は decimalPad 不要
    private var decimalKeypadNeeded: Bool {
        !["JPY", "KRW", "VND", "IDR"].contains(defaultCurrencyCode)
    }

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        SheetIconView.baseIcon(symbol: selectedSymbol,
                                               tint: Color(hex: selectedColor) ?? .blue,
                                               size: 72)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section("シート名") {
                    TextField("家族の家計、旅行など", text: $name)
                }

                Section("カラー") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 40), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if hex == selectedColor {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { selectedColor = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("アイコン") {
                    sheetIconGrid
                }

                Section {
                    currencyPicker
                } header: {
                    Text("既定通貨")
                } footer: {
                    Text("変更後に追加した支出に適用されます。既存の支出の通貨は変わりません。")
                }

                Section {
                    HStack(spacing: 6) {
                        Text(CurrencyCatalog.option(for: defaultCurrencyCode).symbol)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .leading)
                        TextField("0 (未設定)", text: $budgetText)
                            .keyboardType(decimalKeypadNeeded ? .decimalPad : .numberPad)
                            .monospacedDigit()
                            .onChange(of: budgetText) { _, new in
                                let allowed = decimalKeypadNeeded
                                    ? new.filter { $0.isNumber || $0 == "." }
                                    : new.filter { $0.isNumber }
                                if allowed != new { budgetText = allowed }
                            }
                    }
                } header: {
                    Text("月予算 (任意)")
                } footer: {
                    Text("「今月」表示時に進捗バーで残額を可視化します。0 のまま保存すると予算なし扱い。")
                }

                Section("メモ (任意)") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                memberSection

                Section {
                    Toggle(isOn: $archivedDraft) {
                        Label("このシートをアーカイブ",
                              systemImage: archivedDraft ? "archivebox.fill" : "archivebox")
                    }
                } footer: {
                    Text("アーカイブしたシートはシート一覧の下部の「アーカイブ済み」セクションにまとまります。データは削除されず、トグルでいつでも戻せます。変更は「保存」で反映されます。")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(deleteButtonTitle, systemImage: deleteButtonIcon)
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text(deleteFooterMessage)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("シートを編集")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    #if os(macOS)
                    Button("完了") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    #else
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    #endif
                }
            }
            .onAppear { loadIfNeeded() }
            .confirmationDialog(
                record.isOwnedByCurrentUser
                    ? "「\(record.displayName)」を削除しますか?"
                    : "「\(record.displayName)」から退出しますか?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(record.isOwnedByCurrentUser ? "削除" : "退出", role: .destructive) {
                    Task { await deleteOrLeave() }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(record.isOwnedByCurrentUser
                     ? "このシートとすべての支出が削除されます。元には戻せません。"
                     : "あなたの端末からこのシートが消えます。オーナーや他の参加者のデータは残ります。")
            }
            .alert(editingMemberID == nil ? "バーチャルメンバーを追加" : "名前を変更",
                   isPresented: $showMemberPrompt) {
                TextField("名前", text: $newMemberName)
                Button("保存") {
                    let trimmed = newMemberName.trimmingCharacters(in: .whitespaces)
                    if let rn = editingMemberID {
                        if !trimmed.isEmpty,
                           let pp = record.virtualMemberProfiles.first(where: { $0.recordName == rn }) {
                            pp.displayName = trimmed
                            pp.updatedAt = .now
                            PersistenceController.shared.save()
                        }
                    } else {
                        record.addVirtualMember(name: trimmed)
                    }
                    newMemberName = ""
                    editingMemberID = nil
                }
                Button("キャンセル", role: .cancel) { newMemberName = ""; editingMemberID = nil }
            }
            .sheet(item: $editingVirtualMember) { item in
                if let pp = record.virtualMemberProfiles.first(where: { $0.recordName == item.id }) {
                    VirtualMemberEditView(profile: pp)
                }
            }
            .alert(
                "「\(pendingVirtualDelete?.displayName ?? "")」を削除しますか?",
                isPresented: Binding(
                    get: { pendingVirtualDelete != nil },
                    set: { if !$0 { pendingVirtualDelete = nil } }
                ),
                presenting: pendingVirtualDelete
            ) { target in
                Button("削除", role: .destructive) {
                    record.deleteVirtualMember(profileID: target.id)
                }
                Button("キャンセル", role: .cancel) { }
            } message: { _ in
                Text("過去の支出で使われている場合、履歴を保つためアーカイブされ、新規の割り勘候補から外れます。使われていなければ完全に削除されます。")
            }
        }
    }

    private var sheetIconGrid: some View {
        // AX サイズで列が詰まらないよう、最小幅 50pt の adaptive grid
        let columns = [GridItem(.adaptive(minimum: 50), spacing: 12)]
        let tint = Color(hex: selectedColor) ?? .blue
        return VStack(alignment: .leading, spacing: 12) {
            // 基本セクションのみインライン表示 (Free)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(SheetSymbols.freeOptions, id: \.self) { sym in
                    sheetIconButton(sym, tint: tint)
                }
            }
            // その他カテゴリは別画面で選択。Form 内の NavigationLink は行に
            // 自動でシェブロンが付き、カード内の手動シェブロンと二重になるため、
            // Button + navigationDestination でカスタムカードのまま遷移する。
            Button {
                showingMoreIcons = true
            } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Text("その他のアイコン")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.platformTertiarySystemBackground)
                )
            }
            .buttonStyle(.plain)
            .navigationDestination(isPresented: $showingMoreIcons) {
                SheetIconPickerView(selectedSymbol: $selectedSymbol, tint: tint,
                                    premiumUnlocked: PurchaseManager.hasPremiumAccess(to: record))
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }

    @ViewBuilder
    private func sheetIconButton(_ sym: String, tint: Color) -> some View {
        let isSelected = selectedSymbol == sym
        // 既に保存済みの symbol は救済 (= 後で Premium が切れても再選択できる)
        let isLocked = SheetSymbols.isPremiumSymbol(sym)
            && !PurchaseManager.hasPremiumAccess(to: record)
            && sym != origSymbol
        Button {
            if isLocked {
                showingPaywall = true
                Haptics.warning()
            } else {
                selectedSymbol = sym
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 3)
                        .frame(width: 46, height: 46)
                }
                Circle()
                    .fill(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: 38, height: 38)
                // 固定サイズで Dynamic Type に追従させない (AX で circle を突き抜けないように)
                Image(systemName: sym)
                    .foregroundStyle(isSelected ? .white : Color.primary)
                    .font(.system(size: 17, weight: .medium))
                    .opacity(isLocked ? 0.45 : 1)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 13, y: 13)
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
    }

    private var currencyPicker: some View {
        Picker("通貨", selection: $defaultCurrencyCode) {
            ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                Text(opt.symbol + "  " + opt.code + " — " + opt.displayName).tag(opt.code)
            }
        }
        #if os(macOS)
        .pickerStyle(.menu)
        #else
        .pickerStyle(.navigationLink)
        #endif
    }

    /// バーチャルメンバー (アプリ未使用の相手を割り勘・支払者に含める) の管理セクション。
    @ViewBuilder
    private var memberSection: some View {
        Section {
            ForEach(record.virtualMemberProfiles, id: \.objectID) { pp in
                // 行タップでプロフィール編集 (名前 + 写真 + Memoji + 背景色)。
                Button {
                    if let rn = pp.recordName {
                        editingVirtualMember = EditingVirtualMember(id: rn)
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(photoData: pp.photoData,
                                   displayName: pp.displayNameOrEmpty,
                                   colorHex: pp.displayColorHex, size: 32)
                        Text(pp.displayNameOrEmpty.isEmpty ? "メンバー" : pp.displayNameOrEmpty)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        if let rn = pp.recordName {
                            pendingVirtualDelete = PendingVirtualDelete(
                                id: rn,
                                displayName: pp.displayNameOrEmpty.isEmpty ? "メンバー" : pp.displayNameOrEmpty
                            )
                        }
                    } label: { Label("削除", systemImage: "trash") }
                }
            }
            Button {
                if PurchaseManager.hasPremiumAccess(to: record) {
                    editingMemberID = nil
                    newMemberName = ""
                    showMemberPrompt = true
                } else {
                    showingPaywall = true
                }
            } label: {
                Label("バーチャルメンバーを追加", systemImage: "person.badge.plus")
            }
        } header: {
            Text("バーチャルメンバー")
        } footer: {
            Text("アプリを使っていない相手を割り勘・支払者に追加できます。行をタップで名前・写真を編集、スワイプで削除。")
        }
    }

    private var deleteButtonTitle: String {
        record.isOwnedByCurrentUser ? "シートを削除" : "シートから退出"
    }

    private var deleteButtonIcon: String {
        record.isOwnedByCurrentUser ? "trash" : "rectangle.portrait.and.arrow.right"
    }

    private var deleteFooterMessage: String {
        record.isOwnedByCurrentUser
            ? "シートを削除するとすべての支出も削除されます。共有中のメンバーからもアクセスできなくなります。"
            : "退出するとあなたの端末からこのシートが消えます。オーナーや他の参加者のデータは残ります。"
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        name = record.displayName
        note = record.note ?? ""
        selectedColor = record.displayColorHex
        selectedSymbol = record.displaySymbol
        defaultCurrencyCode = record.resolvedDefaultCurrencyCode
        if let budget = record.monthlyBudgetDecimal {
            budgetText = NSDecimalNumber(decimal: budget).stringValue
        } else {
            budgetText = ""
        }
        archivedDraft = record.archived

        origName = name
        origNote = note
        origColor = selectedColor
        origSymbol = selectedSymbol
        origCurrencyCode = defaultCurrencyCode
        origBudgetText = budgetText
        origArchived = archivedDraft
    }

    /// オーナー = ローカル削除 + CloudKit 伝搬で全員から消える。
    /// 参加者 = CloudKit Sharing zone の purge でローカルだけ消す (オーナーや他参加者は影響なし)。
    @MainActor
    private func deleteOrLeave() async {
        if record.isOwnedByCurrentUser {
            viewContext.delete(record)
            PersistenceController.shared.save()
            Haptics.warning()
            dismiss()
        } else {
            do {
                try await ShareCoordinator.shared.leaveSharedSheet(record)
                Haptics.warning()
                dismiss()
            } catch {
                // 失敗しても dismiss はしない。エラー表示は今後追加できる
                #if DEBUG
                print("⚠️ leaveSharedSheet failed: \(error)")
                #endif
            }
        }
    }

    private func save() {
        // 差分のみ書き戻し (= ユーザーが変更したフィールドのみ)
        viewContext.refresh(record, mergeChanges: true)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != origName { record.name = trimmed }
        if note != origNote { record.note = note }
        if selectedColor != origColor { record.colorHex = selectedColor }
        if selectedSymbol != origSymbol { record.symbol = selectedSymbol }
        if defaultCurrencyCode != origCurrencyCode { record.defaultCurrencyCode = defaultCurrencyCode }
        if budgetText != origBudgetText { record.monthlyBudgetDecimal = Decimal(string: budgetText) }
        if archivedDraft != origArchived { record.archived = archivedDraft }
        PersistenceController.shared.save()
        Haptics.success()
        dismiss()
    }
}

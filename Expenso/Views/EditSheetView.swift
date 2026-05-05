//
//  EditSheetView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct EditSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @ObservedObject var record: ExpenseSheet

    @State private var name: String = ""
    @State private var note: String = ""
    @State private var selectedColor: String = "#5B8DEF"
    @State private var defaultCurrencyCode: String = "JPY"
    @State private var didLoad: Bool = false
    @State private var showDeleteConfirm: Bool = false

    // CRDT 用スナップショット (差分のみ書き戻し)
    @State private var origName: String = ""
    @State private var origNote: String = ""
    @State private var origColor: String = ""
    @State private var origCurrencyCode: String = ""

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("シート名") {
                    TextField("家族の家計、旅行など", text: $name)
                }

                Section("カラー") {
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if hex == selectedColor {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { selectedColor = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    currencyPicker
                } header: {
                    Text("既定通貨")
                } footer: {
                    Text("変更後に追加した支出に適用されます。既存の支出の通貨は変わりません。")
                }

                Section("メモ (任意)") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
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
            .navigationTitle("シートを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
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
                    viewContext.delete(record)
                    PersistenceController.shared.save()
                    Haptics.warning()
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(record.isOwnedByCurrentUser
                     ? "このシートとすべての支出が削除されます。元には戻せません。"
                     : "あなたの端末からこのシートが消えます。オーナーや他の参加者のデータは残ります。")
            }
        }
    }

    private var currencyPicker: some View {
        Picker("通貨", selection: $defaultCurrencyCode) {
            ForEach(CurrencyCatalog.all) { opt in
                Text(opt.symbol + "  " + opt.code + " — " + opt.displayName).tag(opt.code)
            }
        }
        .pickerStyle(.navigationLink)
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
        defaultCurrencyCode = record.resolvedDefaultCurrencyCode

        origName = name
        origNote = note
        origColor = selectedColor
        origCurrencyCode = defaultCurrencyCode
    }

    private func save() {
        // 差分のみ書き戻し (= ユーザーが変更したフィールドのみ)
        viewContext.refresh(record, mergeChanges: true)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != origName { record.name = trimmed }
        if note != origNote { record.note = note }
        if selectedColor != origColor { record.colorHex = selectedColor }
        if defaultCurrencyCode != origCurrencyCode { record.defaultCurrencyCode = defaultCurrencyCode }
        PersistenceController.shared.save()
        Haptics.success()
        dismiss()
    }
}

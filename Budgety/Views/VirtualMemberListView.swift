//
//  VirtualMemberListView.swift
//  Budgety
//
//  バーチャルメンバー (アプリ未使用の相手を割り勘・支払者に含める) を一覧・追加・
//  編集・削除する独立画面。SheetDetailView の ellipsis メニューから開く。
//  シート編集 (EditSheetView) 内のメンバーセクションと同じ操作を、単独画面で行える。
//

import SwiftUI
import CoreData

struct VirtualMemberListView: View {
    @ObservedObject var record: ExpenseSheet

    /// 名前変更/追加の入力アラート用。
    @State private var showAddPrompt = false
    @State private var newMemberName = ""
    /// プロフィール編集シート (名前 + 写真 + Memoji + 背景色) 対象。
    @State private var editingMember: EditingMember?
    @State private var showingPaywall = false
    /// 削除確認アラート対象のバーチャルメンバー。
    @State private var pendingDelete: PendingDelete?

    /// `.sheet(item:)` 用の recordName ラッパー。
    private struct EditingMember: Identifiable { let id: String }
    /// 削除確認用 (recordName + 表示名スナップショット)。
    private struct PendingDelete: Identifiable {
        let id: String  // recordName
        let displayName: String
    }

    var body: some View {
        List {
            Section {
                ForEach(record.virtualMemberProfiles, id: \.objectID) { pp in
                    Button {
                        if let rn = pp.recordName {
                            editingMember = EditingMember(id: rn)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(photoData: pp.photoData,
                                       displayName: pp.displayNameOrEmpty,
                                       colorHex: pp.displayColorHex, size: 32)
                            Text(pp.displayNameOrEmpty.isEmpty ? String(localized: "メンバー") : pp.displayNameOrEmpty)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if let rn = pp.recordName {
                                pendingDelete = PendingDelete(
                                    id: rn,
                                    displayName: pp.displayNameOrEmpty.isEmpty ? String(localized: "メンバー") : pp.displayNameOrEmpty
                                )
                            }
                        } label: { Label("削除", systemImage: "trash") }
                    }
                }
                Button {
                    if PurchaseManager.hasPremiumAccess(to: record) {
                        newMemberName = ""
                        showAddPrompt = true
                    } else {
                        showingPaywall = true
                    }
                } label: {
                    Label("バーチャルメンバーを追加", systemImage: "person.badge.plus")
                }
            } footer: {
                Text("アプリを使っていない相手を割り勘・支払者に追加できます。行をタップで名前・写真を編集、スワイプで削除。")
            }
        }
        .navigationTitle("バーチャルメンバー")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("バーチャルメンバーを追加", isPresented: $showAddPrompt) {
            TextField("名前", text: $newMemberName)
            Button("追加") {
                record.addVirtualMember(name: newMemberName.trimmingCharacters(in: .whitespaces))
                newMemberName = ""
            }
            Button("キャンセル", role: .cancel) { newMemberName = "" }
        }
        .alert(
            "「\(pendingDelete?.displayName ?? "")」を削除しますか?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { target in
            Button("削除", role: .destructive) {
                record.deleteVirtualMember(profileID: target.id)
            }
            Button("キャンセル", role: .cancel) { }
        } message: { _ in
            Text("過去の支出で使われている場合、履歴を保つためアーカイブされ、新規の割り勘候補から外れます。使われていなければ完全に削除されます。")
        }
        .sheet(item: $editingMember) { item in
            if let pp = record.virtualMemberProfiles.first(where: { $0.recordName == item.id }) {
                VirtualMemberEditView(profile: pp)
            }
        }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }
}

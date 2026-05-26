//
//  VirtualMemberListView.swift
//  Budgety
//
//  バーチャルメンバー (アプリ未使用の相手を割り勘・支払者に含める) を一覧・追加・
//  編集・削除する独立画面。SheetDetailView の ellipsis メニューから開く。
//  シート編集 (EditSheetView) 内のメンバーセクションと同じ操作を、単独画面で行える。
//

import SwiftUI

struct VirtualMemberListView: View {
    @ObservedObject var record: ExpenseSheet

    /// 名前変更/追加の入力アラート用。
    @State private var showAddPrompt = false
    @State private var newMemberName = ""
    /// プロフィール編集シート (名前 + 写真 + Memoji + 背景色) 対象。
    @State private var editingMember: EditingMember?
    @State private var showingPaywall = false

    /// `.sheet(item:)` 用の recordName ラッパー。
    private struct EditingMember: Identifiable { let id: String }

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
                            Text(pp.displayNameOrEmpty.isEmpty ? "メンバー" : pp.displayNameOrEmpty)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if let rn = pp.recordName { record.deleteVirtualMember(profileID: rn) }
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
        .sheet(item: $editingMember) { item in
            if let pp = record.virtualMemberProfiles.first(where: { $0.recordName == item.id }) {
                VirtualMemberEditView(profile: pp)
            }
        }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }
}

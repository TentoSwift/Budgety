//
//  ExpenseDetailView.swift
//  Budgety
//
//  支出/収入をタップした時に表示する詳細画面 (読み取り専用)。
//  右上の「編集」ボタンで編集画面 (AddExpenseView) をシート表示する。
//

import SwiftUI

struct ExpenseDetailView: View {
    @ObservedObject var expense: Expense
    /// 支払者名 (Public DB カスタム名) / 自分の名前変更で再描画させる。
    @ObservedObject private var pub = PublicProfileSync.shared
    @ObservedObject private var profileStore = UserProfileStore.shared
    @State private var showingEdit = false

    var body: some View {
        List {
            header
            detailsSection
            if showsParticipants {
                participantsSection
            }
            if let note = expense.note,
               !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("メモ") {
                    Text(note)
                        .foregroundStyle(.primary)
                }
            }
            if expense.generatedFromRuleID != nil {
                Section {
                    Label("定期項目から作成されました", systemImage: "repeat")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("編集") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AddExpenseView(expense: expense)
        }
    }

    // MARK: - Header

    private var header: some View {
        Section {
            VStack(spacing: 12) {
                CategoryPayerIconView(expense: expense, size: 64, avatarSize: 26)
                Text(expense.formattedSignedAmount)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(expense.kind == .income ? Color.green : Color.primary)
                let title = expense.displayTitle.isEmpty
                    ? expense.categoryDisplayName : expense.displayTitle
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            detailRow("日付", expense.date.map { $0.formatted(date: .long, time: .omitted) } ?? "—")
            detailRow("カテゴリ", expense.categoryDisplayName)
            if !expense.displayTitle.isEmpty {
                detailRow("タイトル", expense.displayTitle)
            }
            if expense.resolvedCurrencyCode != (expense.sheet?.resolvedDefaultCurrencyCode ?? "JPY") {
                detailRow("通貨", expense.resolvedCurrencyCode)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Participants (payer / beneficiaries)

    /// 共有シート (自分以外の参加者が居る) でのみ支払者/受益者を出す。
    private var showsParticipants: Bool {
        expense.sheet?.hasAcceptedOtherMembers() ?? false
    }

    @ViewBuilder
    private var participantsSection: some View {
        Section {
            HStack(spacing: 12) {
                Text(expense.kind == .income ? "受け取った人" : "支払った人")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                PayerAvatar(
                    member: expense.resolvedPayer,
                    participantProfile: expense.resolvedParticipantProfile,
                    fallbackName: expense.displayPaidBy,
                    fallbackColorHex: "#8E8E93",
                    fallbackPhoto: expense.payerPhotoData,
                    size: 22
                )
                Text(expense.displayPaidBy).foregroundStyle(.primary)
            }
            if let sheet = expense.sheet {
                detailRow(expense.kind == .income ? "受け取り対象" : "受益者",
                          beneficiaryText(in: sheet))
            }
        }
    }

    private func beneficiaryText(in sheet: ExpenseSheet) -> String {
        let ids = expense.resolvedBeneficiaryIDs()
        let all = sheet.allMemberProfileIDs()
        if ids.isEmpty || Set(ids) == Set(all) {
            return "全員均等"
        }
        let names = ids.map { sheet.memberDisplayInfo(for: $0).name }
        return names.joined(separator: ", ")
    }
}

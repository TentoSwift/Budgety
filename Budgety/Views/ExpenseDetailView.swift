//
//  ExpenseDetailView.swift
//  Budgety
//
//  支出/収入をタップした時に表示する詳細画面 (読み取り専用)。
//  右上の「編集」ボタンで編集画面 (AddExpenseView) をシート表示する。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ExpenseDetailView: View {
    @ObservedObject var expense: Expense
    /// 支払者名 (Public DB カスタム名) / 自分の名前変更で再描画させる。
    @ObservedObject private var pub = PublicProfileSync.shared
    @ObservedObject private var profileStore = UserProfileStore.shared
    @State private var showingEdit = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            header
            detailsSection
            if showsParticipants {
                participantsSection
            }
            settlementSection
            photoSection
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
        // 親シートが再ロックされたら詳細画面にロックを重ねる。overlay 方式なので
        // 編集シート表示中でも再ホストせず、編集内容を壊さない。
        .lockOverlay(expense.sheet)
    }

    // MARK: - Header

    private var header: some View {
        Section {
            VStack(spacing: 12) {
                CategoryPayerIconView(expense: expense, size: 64, avatarSize: 26)
                Text(expense.formattedSignedAmount)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
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
            if let created = expense.createdAt {
                detailRow("追加日", created.formatted(date: .long, time: .shortened))
            }
        }
    }

    /// ラベル/値の行。AX サイズでは横に収まらないので AnyLayout で縦積みに切替
    /// (WWDC24「Get started with Dynamic Type」推奨パターン)。縦積み時は左寄せ。
    private func detailRow(_ label: String, _ value: String) -> some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(label).foregroundStyle(.secondary)
            if !isAX { Spacer(minLength: 8) }
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(isAX ? .leading : .trailing)
                .frame(maxWidth: isAX ? .infinity : nil, alignment: isAX ? .leading : .trailing)
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
            payerRow
            beneficiaryRow
        }
    }

    /// 受益者をアバター + 名前のチップで表示する (全員均等ならその旨も併記)。
    /// 受益者が空 (= 割り勘オフ / 支払者単独負担) なら表示しない。
    @ViewBuilder
    private var beneficiaryRow: some View {
        if let sheet = expense.sheet {
            let ids = expense.resolvedBeneficiaryIDs()
            if !ids.isEmpty {
                let all = sheet.allMemberProfileIDs()
                let isEveryone = Set(ids) == Set(all)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(expense.kind == .income ? "受け取り対象" : "受益者")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isEveryone {
                            Text("全員均等").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(ids, id: \.self) { id in
                                let info = sheet.memberDisplayInfo(for: id)
                                VStack(spacing: 4) {
                                    AvatarView(photoData: info.photoData,
                                               displayName: info.name,
                                               colorHex: info.colorHex, size: 36)
                                    Text(info.name)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .frame(maxWidth: 56)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 支払った人/受け取った人の行。AX サイズではラベルの下にアバター+名前を縦積み。
    @ViewBuilder
    private var payerRow: some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Text(expense.kind == .income ? "受け取った人" : "支払った人")
                .foregroundStyle(.secondary)
            if !isAX { Spacer(minLength: 8) }
            HStack(spacing: 8) {
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
        }
    }


    // MARK: - 精算 (相手ごと)

    /// 割り勘の相手ごとに「精算済み」を切り替えるセクション (支出のみ)。
    /// 精算済みにした相手のぶんは精算計算 (誰が誰に) から外れる。
    @ViewBuilder
    private var settlementSection: some View {
        if expense.kind == .expense, let sheet = expense.sheet {
            let allIDs = expense.resolvedBeneficiaryIDs()
            let share = expense.amountDecimal / Decimal(max(allIDs.count, 1))
            let code = expense.resolvedCurrencyCode
            let payerID = expense.payerProfileID ?? ""
            // 支払者自身は「自分に返す」対象外なので除外。
            let ids = allIDs.filter { $0 != payerID }
            if !ids.isEmpty {
                Section {
                    ForEach(ids, id: \.self) { id in
                        settleRow(id: id, sheet: sheet, share: share, code: code)
                    }
                } header: {
                    Text("精算")
                } footer: {
                    Text("返してもらった相手をタップして精算済みにします。精算済みのぶんは「誰が誰に」の精算計算から外れます。")
                }
            }
        }
    }

    @ViewBuilder
    private func settleRow(id: String, sheet: ExpenseSheet, share: Decimal, code: String) -> some View {
        let info = sheet.memberDisplayInfo(for: id)
        let settled = expense.isBeneficiarySettled(id)
        // AX サイズでは横に収まらないので縦積みに切り替える。
        let isAX = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return Button {
            expense.setBeneficiarySettled(!settled, for: id)
            PersistenceController.shared.save()
            Haptics.success()
        } label: {
            layout {
                HStack(spacing: 12) {
                    AvatarView(photoData: info.photoData, displayName: info.name,
                               colorHex: info.colorHex, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.name).foregroundStyle(.primary)
                        Text(CurrencyCatalog.format(share, code: code))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !isAX { Spacer(minLength: 8) }
                if settled {
                    Label("精算済み", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sheet.tint)
                } else {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Photo

    @ViewBuilder
    private var photoSection: some View {
        #if canImport(UIKit)
        if let data = expense.photoData, let ui = UIImage(data: data) {
            Section("写真") {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        #endif
    }
}

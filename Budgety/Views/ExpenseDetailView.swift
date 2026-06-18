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
    /// 仮想 occurrence を materialize して詳細表示している場合に、編集が実際に保存(commit)
    /// されたことを親へ伝えるコールバック。未 commit で戻ったら親が未保存行を破棄する。
    var onCommit: (() -> Void)? = nil
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("編集") { showingEdit = true }
                    #if os(macOS)
                    // macOS の編集ボタンをシートの色で塗る (iOS は従来の nav tint のまま)。
                    .tint(expense.sheet?.tint)
                    #endif
            }
        }
        .sheet(isPresented: $showingEdit) {
            #if os(macOS)
            if let sheet = expense.sheet {
                MacAddExpenseView(sheet: sheet, expense: expense, onCommit: onCommit)
            }
            #else
            AddExpenseView(expense: expense, onCommit: onCommit)
            #endif
        }
        #if os(iOS)
        // 親シートが再ロックされたら詳細画面にロックを重ねる。overlay 方式なので
        // 編集シート表示中でも再ホストせず、編集内容を壊さない。
        .lockOverlay(expense.sheet)
        #endif
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
        #if os(macOS)
        // ヘッダー (金額・タイトル) 下の区切り線を消す。
        .listRowSeparator(.hidden)
        #endif
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            detailRow(String(localized: "日付"), expense.date.map { $0.formatted(date: .long, time: .omitted) } ?? "—")
            detailRow(String(localized: "カテゴリ"), expense.categoryDisplayName)
            if !expense.displayTitle.isEmpty {
                detailRow(String(localized: "タイトル"), expense.displayTitle)
            }
            if expense.resolvedCurrencyCode != (expense.sheet?.resolvedDefaultCurrencyCode ?? "JPY") {
                detailRow(String(localized: "通貨"), expense.resolvedCurrencyCode)
            }
            if let created = expense.createdAt {
                detailRow(String(localized: "追加日"), created.formatted(date: .long, time: .shortened))
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
                        Text(expense.kind == .income ? "受け取り対象" : "割り勘")
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

    /// 支払者が指定されているか。3 フィールドのどれかが入っていれば「指定あり」とみなす。
    private var hasPayer: Bool {
        !(expense.payerProfileID ?? "").isEmpty
            || expense.payerMemberID != nil
            || !(expense.paidBy ?? "").isEmpty
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
                if hasPayer {
                    PayerAvatar(
                        member: expense.resolvedPayer,
                        participantProfile: expense.resolvedParticipantProfile,
                        fallbackName: expense.displayPaidBy,
                        fallbackColorHex: "#8E8E93",
                        fallbackPhoto: expense.payerPhotoData,
                        size: 22
                    )
                    Text(expense.displayPaidBy).foregroundStyle(.primary)
                } else {
                    // 未選択時は破線サークル + 「未選択」テキスト。
                    // AvatarView は displayName 空文字で "?" を出してしまうのでここで分岐。
                    ZStack {
                        Circle()
                            .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: 22, height: 22)
                        Image(systemName: "person.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text("未選択").foregroundStyle(.secondary)
                }
            }
        }
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

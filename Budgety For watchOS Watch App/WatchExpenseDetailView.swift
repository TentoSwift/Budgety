//
//  WatchExpenseDetailView.swift
//  Budgety Watch
//
//  支出 1 件の詳細 (= タイトル / 金額 / 日時 / カテゴリ) + 削除アクション。
//

import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct WatchExpenseDetailView: View {
    @ObservedObject var expense: Expense
    let sheet: ExpenseSheet
    /// 他メンバーのプロフィール写真が Public DB からロードされたら再描画する。
    @ObservedObject private var pub = PublicProfileSync.shared

    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm: Bool = false

    // 割り勘 (受益者) の表示・編集用。
    @State private var splitEnabled: Bool = false
    @State private var selectedBeneficiaries: Set<String> = []
    @State private var showingSplitPicker: Bool = false
    @State private var didLoadSplit: Bool = false

    /// 共有シート (他メンバーあり) か。割り勘 UI はこの時だけ出す。
    private var isShared: Bool { sheet.hasAcceptedOtherMembers() }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                categoryBadge
                amountText
                metaRow
                splitSection
                if let note = expense.note, !note.isEmpty {
                    noteCard(note)
                }
                deleteButton
            }
            .padding(.horizontal, 6)
        }
        .containerBackground(sheet.tint.gradient, for: .navigation)
        .navigationTitle {
            Text("詳細")
                .foregroundStyle(sheet.tint)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSplit(); prefetchMemberPhotos() }
        .sheet(isPresented: $showingSplitPicker, onDismiss: applySplit) {
            WatchSplitPicker(
                sheet: sheet,
                splitEnabled: $splitEnabled,
                selected: $selectedBeneficiaries
            )
        }
        .alert("削除しますか?", isPresented: $showDeleteConfirm) {
            Button("削除", role: .destructive) { delete() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この支出を削除します。元に戻せません。")
        }
    }

    // MARK: - 割り勘 (受益者) 表示・編集

    @ViewBuilder
    private var splitSection: some View {
        // 割り勘オフ (受益者が空 or 支払者ただ 1 人) のときはセクション全体を非表示。
        // iOS / macOS の挙動に揃えた。
        if isShared {
            let payer = expense.payerProfileID ?? ""
            // 空 id / 重複を除いた安全なリスト。ForEach(id: \.self) の id 重複は
            // watchOS でクラッシュするため必ず一意化する。
            let beneficiaries: [String] = {
                var seen = Set<String>()
                return expense.resolvedBeneficiaryIDs().filter {
                    !$0.isEmpty && seen.insert($0).inserted
                }
            }()
            let isSplit = !beneficiaries.isEmpty
                && !(!payer.isEmpty && Set(beneficiaries) == Set([payer]))
            if isSplit {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("割り勘", systemImage: "person.2.fill")
                            .font(.caption2.weight(.semibold))
                        Spacer()
                        Button { showingSplitPicker = true } label: {
                            Text("編集").font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white)

                    ForEach(Array(beneficiaries.enumerated()), id: \.offset) { _, id in
                        let info = sheet.memberDisplayInfo(for: id)
                        HStack(spacing: 6) {
                            avatar(info)
                            Text(info.name)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)))
            }
        }
    }

    /// メンバーアバター。写真があれば写真、無ければ配色 + 頭文字。
    @ViewBuilder
    private func avatar(_ info: (name: String, colorHex: String, photoData: Data?)) -> some View {
        let color = Color(hex: info.colorHex) ?? .blue
        #if canImport(UIKit)
        if let data = info.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: 20, height: 20)
                .clipShape(Circle())
        } else {
            initialAvatar(name: info.name, color: color)
        }
        #else
        initialAvatar(name: info.name, color: color)
        #endif
    }

    private func initialAvatar(name: String, color: Color) -> some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 20, height: 20)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    /// 支払者・受益者のプロフィール写真を Public DB からまとめて取得する。
    /// (email:/phone:/virtual: は Public DB のキーにならないので除外)
    private func prefetchMemberPhotos() {
        var ids = Set(expense.resolvedBeneficiaryIDs())
        if let p = expense.payerProfileID, !p.isEmpty { ids.insert(p) }
        let urns = ids.filter {
            !$0.isEmpty
            && !$0.hasPrefix("email:")
            && !$0.hasPrefix("phone:")
            && !UserProfileStore.isVirtualRecordName($0)
        }
        guard !urns.isEmpty else { return }
        Task { await PublicProfileSync.shared.fetchProfiles(forURNs: Array(urns)) }
    }

    /// 現在の expense から割り勘 state を 1 度だけ読み込む。
    private func loadSplit() {
        guard !didLoadSplit else { return }
        didLoadSplit = true
        let list = expense.beneficiaryIDList
        let payer = expense.payerProfileID ?? ""
        if !payer.isEmpty, Set(list) == Set([payer]) {
            splitEnabled = false
            selectedBeneficiaries = []
        } else {
            splitEnabled = true
            // 空 (= 全員) の時は全メンバーを選択状態にして UI に反映。
            selectedBeneficiaries = list.isEmpty ? Set(sheet.acceptedMemberProfileIDs()) : Set(list)
        }
    }

    /// ピッカーを閉じた時に割り勘の変更を expense へ保存する。
    private func applySplit() {
        let csv: String
        if splitEnabled {
            // 空 = 全員均等は禁止 (後から追加した人が遡って含まれるため)。
            // 未選択なら現メンバー全員を明示保存する。
            let ids = selectedBeneficiaries.isEmpty
                ? Set(sheet.acceptedMemberProfileIDs())
                : selectedBeneficiaries
            csv = ids.sorted().joined(separator: ",")
        } else {
            // 自分のみ負担 = 支払者を受益者にする。
            csv = expense.payerProfileID ?? (UserProfileStore.shared.userRecordName ?? "")
        }
        guard expense.beneficiaryProfileIDs != csv else { return }
        expense.beneficiaryProfileIDs = csv
        // 受益者から外した人の精算済みフラグを掃除する。
        expense.pruneSettledBeneficiaries()
        do {
            try ctx.save()
            WKInterfaceDevice.current().play(.success)
        } catch {
            WKInterfaceDevice.current().play(.failure)
        }
    }

    @ViewBuilder
    private var categoryBadge: some View {
        if let cat = expense.category {
            HStack(spacing: 6) {
                Image(systemName: cat.symbol ?? "tag.fill")
                    .font(.caption.weight(.semibold))
                Text(cat.name ?? "")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.20)))
        }
    }

    private var amountText: some View {
        Text(formatAmount(expense.amountDecimal))
            .font(.system(size: 38, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var metaRow: some View {
        VStack(spacing: 4) {
            if let title = expense.title, !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            Text(formatDate(expense.date ?? Date()))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
            payerRow
        }
        .frame(maxWidth: .infinity)
    }

    /// 支払い者 (支出) / 受取者 (収入) を 1 行で表示する。共有シートで他メンバー
    /// がいない (ソロ + 自分払い) 時は冗長なので隠す。
    @ViewBuilder
    private var payerRow: some View {
        let pid = expense.payerProfileID ?? ""
        if !pid.isEmpty {
            let info = sheet.memberDisplayInfo(for: pid)
            let label = expense.kind == .income ? String(localized: "受取者") : String(localized: "支払い者")
            // ソロかつ自分払いの時は省略 (= シート詳細と同じ判定)
            let hideForSoloSelf = !isShared && pid == (UserProfileStore.shared.userRecordName ?? "")
            if !hideForSoloSelf {
                HStack(spacing: 6) {
                    avatar(info)
                    Text("\(label): \(info.name)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
        }
    }

    private func noteCard(_ note: String) -> some View {
        Text(note)
            .font(.caption2)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.12))
            )
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("削除", systemImage: "trash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.red.opacity(0.85))
                )
        }
        .buttonStyle(.plain)
    }

    private func delete() {
        ctx.delete(expense)
        try? ctx.save()
        WKInterfaceDevice.current().play(.success)
        dismiss()
    }

    private func formatAmount(_ d: Decimal) -> String {
        CurrencyCatalog.format(d, code: expense.resolvedCurrencyCode)
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d (EEE) HH:mm"
        return f.string(from: d)
    }
}

//
//  SettlementView.swift
//  Expenso
//
//  シート単位で精算結果 (各メンバー残高 + 最少回数送金提案) を表示する。
//

import SwiftUI
import CoreData
import CloudKit

struct SettlementView: View {
    @ObservedObject var record: ExpenseSheet
    @ObservedObject private var fx = FXRatesService.shared
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared
    @State private var result: SettlementResult?

    /// 「送金済みにする」シートの表示状態。
    @State private var loggingPrefill: LoggingPrefill?
    /// 編集対象の SettlementRecord (= シート再表示)
    @State private var editingRecord: SettlementRecord?
    /// 削除確認用
    @State private var deletingRecord: SettlementRecord?

    /// 新規 SettlementRecord 入力時のプリフィル。
    private struct LoggingPrefill: Identifiable {
        let id = UUID()
        let from: String
        let to: String
        let amount: Decimal
        let currencyCode: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let result {
                    if result.includedExpenseCount == 0 {
                        emptySection
                    } else {
                        summarySection(result: result)
                        // 共有していない (= 自分しかいない) シートでは
                        // 残高 / 送金プラン / 送金履歴を出しても意味がないので隠す。
                        if result.balances.count > 1 {
                            balancesSection(result: result)
                            transfersSection(result: result)
                            perExpenseSettleSection
                            settlementHistorySection
                        } else {
                            notSharedSection
                        }
                        if !result.missingRateCurrencies.isEmpty {
                            missingRatesSection(currencies: result.missingRateCurrencies)
                        }
                        notesSection
                    }
                } else {
                    card {
                        HStack {
                            ProgressView()
                            Text("計算中...").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color.platformSystemBackground.ignoresSafeArea())
        .navigationTitle("精算")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: record.objectID) { recompute() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            recompute()
        }
        .onChange(of: fx.lastUpdated) { _, _ in recompute() }
        .sheet(item: $loggingPrefill) { prefill in
            LogSettlementView(
                sheet: record,
                prefillFrom: prefill.from,
                prefillTo: prefill.to,
                prefillAmount: prefill.amount,
                prefillCurrencyCode: prefill.currencyCode
            )
        }
        .sheet(item: $editingRecord) { rec in
            LogSettlementView(sheet: record, record: rec)
        }
        .confirmationDialog(
            "この送金記録を削除しますか？",
            isPresented: Binding(
                get: { deletingRecord != nil },
                set: { if !$0 { deletingRecord = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let r = deletingRecord {
                    viewContext.delete(r)
                    PersistenceController.shared.save()
                    deletingRecord = nil
                    recompute()
                }
            }
            Button("キャンセル", role: .cancel) { deletingRecord = nil }
        } message: {
            Text("この記録を取り消すと、精算残高が元に戻ります。")
        }
    }

    // MARK: - Card

    /// 共通カードラッパー。section に相当する見た目をグリッド配置用に。
    @ViewBuilder
    private func card<Content: View>(
        title: String? = nil,
        trailing: (() -> AnyView)? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let trailing {
                        trailing()
                    }
                }
            }
            content()
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func recompute() {
        result = SettlementCalculator.calculate(for: record, in: nil)
    }

    // MARK: - 支出ごとの精算 (相手ごと)

    /// 割り勘した支出 (= 支払者以外の受益者がいる支出) を新しい順で。
    private var splitExpenses: [Expense] {
        ((record.expenses as? Set<Expense>) ?? [])
            .filter { e in
                guard e.kind == .expense else { return false }
                let payer = e.payerProfileID ?? ""
                return !e.resolvedBeneficiaryIDs().filter { $0 != payer }.isEmpty
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// 支出ごとに、割り勘の相手単位で「精算済み」を切り替えるセクション。
    @ViewBuilder
    private var perExpenseSettleSection: some View {
        let expenses = splitExpenses
        if !expenses.isEmpty {
            card(title: "支出ごとの精算",
                 footer: "返してもらった相手をタップして精算済みに。精算済みのぶんは上の残高・送金プランから外れます。") {
                VStack(spacing: 2) {
                    ForEach(expenses, id: \.objectID) { e in
                        expenseSettleDisclosure(e)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func expenseSettleDisclosure(_ e: Expense) -> some View {
        let allIDs = e.resolvedBeneficiaryIDs()
        let share = e.amountDecimal / Decimal(max(allIDs.count, 1))
        let code = e.resolvedCurrencyCode
        let payerID = e.payerProfileID ?? ""
        let ids = allIDs.filter { $0 != payerID }
        let settledCount = ids.filter { e.isBeneficiarySettled($0) }.count
        DisclosureGroup {
            ForEach(ids, id: \.self) { id in
                expenseSettleRow(e: e, id: id, share: share, code: code)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.displayTitle.isEmpty ? e.categoryDisplayName : e.displayTitle)
                        .foregroundStyle(.primary)
                    Text(e.formattedSignedAmount)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(settledCount)/\(ids.count) 精算")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(settledCount == ids.count && !ids.isEmpty ? .green : .secondary)
            }
        }
    }

    private func expenseSettleRow(e: Expense, id: String, share: Decimal, code: String) -> some View {
        let info = record.memberDisplayInfo(for: id)
        let settled = e.isBeneficiarySettled(id)
        return Button {
            e.setBeneficiarySettled(!settled, for: id)
            PersistenceController.shared.save()
            Haptics.success()
            recompute()
        } label: {
            HStack(spacing: 10) {
                AvatarView(photoData: info.photoData, displayName: info.name,
                           colorHex: info.colorHex, size: 24)
                Text(info.name).foregroundStyle(.primary)
                Spacer()
                Text(CurrencyCatalog.format(share, code: code))
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: settled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(settled ? .green : .secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    private var emptySection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label("精算対象の支出がありません", systemImage: "checkmark.seal")
                    .font(.headline)
                Text("支出を追加すると、各メンバーの残高と最少回数の精算プランがここに表示されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// シートが共有されていない (= 自分しかいない) 時の説明。
    private var notSharedSection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label("このシートは共有されていません", systemImage: "person.fill")
                    .font(.headline)
                Text("シートを誰かと共有すると、各メンバーの残高や送金プランがここに表示されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func summarySection(result: SettlementResult) -> some View {
        card(
            title: "サマリ",
            footer: "収入は精算対象外です。受益者が指定されていない支出はシート全員で均等割りとして扱います。"
        ) {
            HStack(alignment: .firstTextBaseline) {
                Text("通貨")
                Spacer()
                Text(result.currencyCode).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("対象支出")
                Spacer()
                Text("\(result.includedExpenseCount) 件").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func balancesSection(result: SettlementResult) -> some View {
        card(title: "各メンバーの残高") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 12)],
                spacing: 12
            ) {
                ForEach(result.balances, id: \.profileID) { bal in
                    balanceTile(bal: bal, currencyCode: result.currencyCode)
                }
            }
        }
    }

    /// 連絡先ウィジェット風の縦長タイル: アバター + 名前 + 残高。
    /// 背景はプロフィール写真の平均色 (なければ colorHex) を薄く敷く。
    @ViewBuilder
    private func balanceTile(bal: MemberBalance, currencyCode: String) -> some View {
        let info = record.memberDisplayInfo(for: bal.profileID)
        let share = ShareCoordinator.shared.existingShare(for: record)
        let selfIDs = profile.canonicalSelfIDs(forShare: share)
        let isMe = selfIDs.contains(bal.profileID)
        // 写真からドミナント色を抽出 (キャッシュ済)。未設定なら colorHex フォールバック。
        let tileTint: Color = AverageColorCache.color(for: info.photoData)
            ?? Color(hex: info.colorHex)
            ?? .gray
        VStack(spacing: 8) {
            AvatarView(
                photoData: info.photoData,
                displayName: info.name,
                colorHex: info.colorHex,
                size: 64
            )
            // 「自分」の有無で背丈が変わらないよう、常に subtitle 行のスペースを確保。
            VStack(spacing: 2) {
                Text(info.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(isMe ? "自分" : " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            balanceLabel(amount: bal.amount, currencyCode: currencyCode)
                .monospacedDigit()
        }
        // 全タイルが同じ高さになるよう minHeight を固定。
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tileTint.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tileTint.opacity(0.35), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func balanceLabel(amount: Decimal, currencyCode: String) -> some View {
        if amount > 0 {
            VStack(spacing: 1) {
                Text("+ \(CurrencyCatalog.format(amount, code: currencyCode))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("受け取る")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if amount < 0 {
            VStack(spacing: 1) {
                Text("- \(CurrencyCatalog.format(-amount, code: currencyCode))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("支払う")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("精算済み")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func transfersSection(result: SettlementResult) -> some View {
        if result.transfers.isEmpty {
            card(title: "送金プラン") {
                Label("既に精算済みです", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            card(
                title: "送金プラン (\(result.transfers.count) 回で精算)",
                footer: ""
            ) {
                VStack(spacing: 10) {
                    ForEach(Array(result.transfers.enumerated()), id: \.element.id) { idx, transfer in
                        transferRow(transfer: transfer, currencyCode: result.currencyCode)
                        if idx < result.transfers.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transferRow(transfer: SettlementTransfer, currencyCode: String) -> some View {
        let from = record.memberDisplayInfo(for: transfer.fromProfileID)
        let to = record.memberDisplayInfo(for: transfer.toProfileID)
        // 横幅がない端末で名前 / 金額が文字単位に折り返してしまうため、
        // アバター行と情報を縦に積む。情報は full-width で line limit 1 + scale。
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(
                    photoData: from.photoData,
                    displayName: from.name,
                    colorHex: from.colorHex,
                    size: 32
                )
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AvatarView(
                    photoData: to.photoData,
                    displayName: to.name,
                    colorHex: to.colorHex,
                    size: 32
                )
                Spacer()
                Button {
                    loggingPrefill = LoggingPrefill(
                        from: transfer.fromProfileID,
                        to: transfer.toProfileID,
                        amount: transfer.amount,
                        currencyCode: currencyCode
                    )
                } label: {
                    Text("送金済み")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text(from.name).font(.subheadline.weight(.medium))
                Text("→").foregroundStyle(.secondary)
                Text(to.name).font(.subheadline.weight(.medium))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(CurrencyCatalog.format(transfer.amount, code: currencyCode))
                .font(.headline.monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 2)
    }

    /// 期間内に記録された送金履歴。新規記録ボタンも出す。
    @ViewBuilder
    private var settlementHistorySection: some View {
        let records = settlementsInCurrentRange
        card(
            title: "送金履歴",
            footer: "送金プランから「送金済み」をタップすると、ここに記録されて残高に反映されます。"
        ) {
            VStack(spacing: 12) {
                if records.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                        Text("送金記録はまだありません")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Spacer()
                    }
                } else {
                    ForEach(Array(records.enumerated()), id: \.element.objectID) { idx, r in
                        HStack(spacing: 0) {
                            settlementRecordRow(r)
                                .contentShape(Rectangle())
                                .onTapGesture { editingRecord = r }
                            Button(role: .destructive) {
                                deletingRecord = r
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                    .padding(.leading, 6)
                            }
                            .buttonStyle(.plain)
                        }
                        .contextMenu {
                            Button {
                                editingRecord = r
                            } label: {
                                Label("編集", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingRecord = r
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                        if idx < records.count - 1 {
                            Divider()
                        }
                    }
                }
                Divider()
                Button {
                    loggingPrefill = LoggingPrefill(
                        from: profile.canonicalSelfID(forShare: ShareCoordinator.shared.existingShare(for: record))
                            ?? profile.userRecordName
                            ?? "",
                        to: "",
                        amount: 0,
                        currencyCode: record.resolvedDefaultCurrencyCode
                    )
                } label: {
                    Label("送金を手動で記録", systemImage: "plus.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func settlementRecordRow(_ r: SettlementRecord) -> some View {
        let fromInfo = record.memberDisplayInfo(for: r.fromProfileID ?? "")
        let toInfo = record.memberDisplayInfo(for: r.toProfileID ?? "")
        // 横幅がない端末で名前 / 金額が文字単位に折り返してしまうため、
        // アバター行と情報を縦に積む。
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AvatarView(
                    photoData: fromInfo.photoData,
                    displayName: fromInfo.name,
                    colorHex: fromInfo.colorHex,
                    size: 28
                )
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                AvatarView(
                    photoData: toInfo.photoData,
                    displayName: toInfo.name,
                    colorHex: toInfo.colorHex,
                    size: 28
                )
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(fromInfo.name).font(.caption.weight(.medium))
                Text("→").font(.caption).foregroundStyle(.secondary)
                Text(toInfo.name).font(.caption.weight(.medium))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                Text(r.formattedAmount)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let d = r.date {
                    Text(d, format: .dateTime.year().month().day())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = r.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// シート配下の全 SettlementRecord (date 降順)。
    private var settlementsInCurrentRange: [SettlementRecord] {
        let all = (record.settlements as? Set<SettlementRecord>) ?? []
        return all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    @ViewBuilder
    private func missingRatesSection(currencies: Set<String>) -> some View {
        card {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("レートが見つからず除外された通貨")
                        .font(.subheadline)
                    Text(currencies.sorted().joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var notesSection: some View {
        card {
            Label {
                Text("精算金額は支出時点の金額を既定通貨に換算したものです。実際の送金時の為替差は反映されません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

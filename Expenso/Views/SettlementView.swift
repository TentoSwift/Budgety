//
//  SettlementView.swift
//  Expenso
//
//  シート単位で精算結果 (各メンバー残高 + 最少回数送金提案) を表示する。
//

import SwiftUI
import CoreData

/// 集計対象の期間プリセット。
enum SettlementPeriod: String, CaseIterable, Identifiable {
    case all
    case thisMonth
    case lastMonth
    case custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "全期間"
        case .thisMonth: "今月"
        case .lastMonth: "先月"
        case .custom: "カスタム"
        }
    }
}

struct SettlementView: View {
    @ObservedObject var record: ExpenseSheet
    @ObservedObject private var fx = FXRatesService.shared
    @StateObject private var profile = UserProfileStore.shared
    @State private var result: SettlementResult?

    @State private var period: SettlementPeriod = .all
    /// custom 用。デフォルトは「今月」相当。
    @State private var customStart: Date = SettlementView.startOfMonth(.now)
    @State private var customEnd: Date = SettlementView.endOfMonth(.now)

    var body: some View {
        List {
            periodSection
            if let result {
                if result.includedExpenseCount == 0 {
                    emptySection
                } else {
                    summarySection(result: result)
                    balancesSection(result: result)
                    transfersSection(result: result)
                    if !result.missingRateCurrencies.isEmpty {
                        missingRatesSection(currencies: result.missingRateCurrencies)
                    }
                    notesSection
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("計算中...").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("精算")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("期間", selection: $period) {
                    ForEach(SettlementPeriod.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .task(id: record.objectID) { recompute() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            recompute()
        }
        .onChange(of: fx.lastUpdated) { _, _ in recompute() }
        .onChange(of: period) { _, _ in recompute() }
        .onChange(of: customStart) { _, _ in if period == .custom { recompute() } }
        .onChange(of: customEnd) { _, _ in if period == .custom { recompute() } }
    }

    @ViewBuilder
    private var periodSection: some View {
        if period == .custom {
            Section {
                DatePicker("開始", selection: $customStart, displayedComponents: .date)
                DatePicker("終了", selection: $customEnd, in: customStart..., displayedComponents: .date)
            } header: {
                Text("期間")
            } footer: {
                if let label = currentPeriodSummary {
                    Text(label).font(.caption2)
                }
            }
        }
    }

    /// フッター表示用: 現在の期間プリセットの実日付範囲。
    private var currentPeriodSummary: String? {
        guard let range = currentDateRange else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "\(f.string(from: range.lowerBound)) 〜 \(f.string(from: range.upperBound))"
    }

    /// 現在のピッカー選択に対応する日付範囲 (`.all` のみ nil)。
    private var currentDateRange: ClosedRange<Date>? {
        switch period {
        case .all:
            return nil
        case .thisMonth:
            return Self.startOfMonth(.now)...Self.endOfMonth(.now)
        case .lastMonth:
            let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
            return Self.startOfMonth(lastMonth)...Self.endOfMonth(lastMonth)
        case .custom:
            // 終了日は当日 23:59:59 まで含める
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: customEnd) ?? customEnd
            return Calendar.current.startOfDay(for: customStart)...endOfDay
        }
    }

    private static func startOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private static func endOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let start = startOfMonth(date)
        let next = cal.date(byAdding: DateComponents(month: 1, second: -1), to: start) ?? date
        return next
    }

    @MainActor
    private func recompute() {
        result = SettlementCalculator.calculate(for: record, in: currentDateRange)
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("精算対象の支出がありません", systemImage: "checkmark.seal")
                    .font(.headline)
                Text("支出を追加すると、各メンバーの残高と最少回数の精算プランがここに表示されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func summarySection(result: SettlementResult) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("通貨")
                Spacer()
                Text(result.currencyCode).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("対象支出")
                Spacer()
                Text("\(result.includedExpenseCount) 件").foregroundStyle(.secondary)
            }
        } header: {
            Text("サマリ")
        } footer: {
            Text("収入は精算対象外です。受益者が指定されていない支出はシート全員で均等割りとして扱います。")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func balancesSection(result: SettlementResult) -> some View {
        Section("各メンバーの残高") {
            ForEach(result.balances) { bal in
                balanceRow(bal: bal, currencyCode: result.currencyCode)
            }
        }
    }

    @ViewBuilder
    private func balanceRow(bal: MemberBalance, currencyCode: String) -> some View {
        let info = record.memberDisplayInfo(for: bal.profileID)
        let isMe = profile.userRecordName == bal.profileID
        HStack(spacing: 12) {
            AvatarView(
                photoData: info.photoData,
                displayName: info.name,
                colorHex: info.colorHex,
                size: 36
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                if isMe {
                    Text("自分").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            balanceLabel(amount: bal.amount, currencyCode: currencyCode)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func balanceLabel(amount: Decimal, currencyCode: String) -> some View {
        if amount > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text("+ \(CurrencyCatalog.format(amount, code: currencyCode))")
                    .foregroundStyle(.green)
                    .fontWeight(.semibold)
                Text("受け取る").font(.caption2).foregroundStyle(.green)
            }
        } else if amount < 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text("- \(CurrencyCatalog.format(-amount, code: currencyCode))")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
                Text("支払う").font(.caption2).foregroundStyle(.red)
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
            Section("送金プラン") {
                Label("既に精算済みです", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Section {
                ForEach(result.transfers) { transfer in
                    transferRow(transfer: transfer, currencyCode: result.currencyCode)
                }
            } header: {
                Text("送金プラン (\(result.transfers.count) 回で精算)")
            } footer: {
                Text("最少回数で精算するための送金提案です。実際の送金方法は当事者間で決めてください。")
                    .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func transferRow(transfer: SettlementTransfer, currencyCode: String) -> some View {
        let from = record.memberDisplayInfo(for: transfer.fromProfileID)
        let to = record.memberDisplayInfo(for: transfer.toProfileID)
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(from.name).font(.subheadline.weight(.medium))
                    Text("→").foregroundStyle(.secondary)
                    Text(to.name).font(.subheadline.weight(.medium))
                }
                Text(CurrencyCatalog.format(transfer.amount, code: currencyCode))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func missingRatesSection(currencies: Set<String>) -> some View {
        Section {
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
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("精算金額は支出時点の金額を既定通貨に換算したものです。実際の送金時の為替差は反映されません。")
                        .font(.caption2)
                }
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

import CoreData
import SwiftUI

struct WatchSettlementView: View {
    @ObservedObject var sheet: ExpenseSheet
    @ObservedObject private var rates = FXRatesService.shared
    @Environment(\.managedObjectContext) private var context
    @State private var result: SettlementResult?

    var body: some View {
        List {
            if let result {
                Section(sheet.displayName) {
                    if result.transfers.isEmpty {
                        if !result.missingRateCurrencies.isEmpty {
                            Label("判定できません", systemImage: "exclamationmark.triangle")
                        } else if result.includedExpenseCount == 0 && history.isEmpty {
                            Label("精算対象の支出がありません", systemImage: "checkmark.seal")
                        } else {
                            Label("既に精算済みです", systemImage: "checkmark.seal")
                        }
                    } else {
                        ForEach(result.transfers) { transfer in
                            transferRow(from: transfer.fromProfileID, to: transfer.toProfileID,
                                        amount: CurrencyCatalog.format(transfer.amount, code: result.currencyCode))
                        }
                    }
                }
                if !result.missingRateCurrencies.isEmpty {
                    Section("レートが見つからず除外された通貨") {
                        Text(result.missingRateCurrencies.sorted().joined(separator: ", "))
                    }
                }
                if !result.balances.isEmpty {
                    Section("各メンバーの残高") {
                        ForEach(result.balances) { balance in
                            VStack(alignment: .leading) {
                                Text(verbatim: sheet.memberDisplayInfo(for: balance.profileID).name)
                                Text(CurrencyCatalog.format(balance.amount, code: result.currencyCode))
                                    .font(.headline.monospacedDigit())
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if !history.isEmpty {
                    Section("送金履歴") {
                        ForEach(history, id: \.objectID) { payment in
                            transferRow(from: payment.fromProfileID ?? "", to: payment.toProfileID ?? "",
                                        amount: payment.formattedAmount, date: payment.date)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("精算")
        .task(id: sheet.objectID) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: context)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidMergeChangesObjectIDs, object: context)) { _ in refresh() }
        .onChange(of: rates.lastUpdated) { _, _ in refresh() }
    }

    private var history: [SettlementRecord] {
        let records = sheet.settlements as? Set<SettlementRecord> ?? []
        return records.filter { !$0.isDeleted }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private func transferRow(from: String, to: String, amount: String, date: Date? = nil) -> some View {
        VStack(alignment: .leading) {
            Text(verbatim: "\(sheet.memberDisplayInfo(for: from).name) → \(sheet.memberDisplayInfo(for: to).name)")
            Text(verbatim: amount).font(.headline.monospacedDigit())
            if let date {
                Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        guard !sheet.isDeleted, sheet.managedObjectContext != nil else { return }
        result = SettlementCalculator.calculate(for: sheet)
    }
}

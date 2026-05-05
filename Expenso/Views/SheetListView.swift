//
//  SheetListView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct SheetListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var showingAddSheet = false
    @State private var path: [NSManagedObjectID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sheets.isEmpty {
                    ContentUnavailableView {
                        Label("シートがありません", systemImage: "person.2")
                    } description: {
                        Text("シートを作成して、家族や友人と支出を共有しましょう。")
                    } actions: {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("シートを作成", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(sheets) { sheet in
                            NavigationLink(value: sheet.objectID) {
                                SheetRowView(record: sheet)
                            }
                        }
                        .onDelete(perform: deleteGroups)
                    }
                }
            }
            .navigationTitle("Expenso")
            .navigationDestination(for: NSManagedObjectID.self) { id in
                if let sheet = try? viewContext.existingObject(with: id) as? ExpenseSheet {
                    SheetDetailView(record: sheet)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddSheetView()
            }
            .onAppear { applyDemoLaunch() }
        }
    }

    private func applyDemoLaunch() {
        let demo = ProcessInfo.processInfo.environment["EXPENSO_DEMO"]
        switch demo {
        case "addGroup":
            showingAddSheet = true
        case "detail", "addExpense", "share", "editGroup", "editExpense":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let first = sheets.first { path = [first.objectID] }
            }
        default:
            break
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        let targets = offsets.map { sheets[$0] }
        Task { @MainActor in
            for sheet in targets {
                if sheet.isOwnedByCurrentUser {
                    viewContext.delete(sheet)
                } else {
                    // 参加シートはローカルだけ purge。オーナー側を削除しない。
                    try? await ShareCoordinator.shared.leaveSharedSheet(sheet)
                }
            }
            PersistenceController.shared.save()
            Haptics.warning()
        }
    }
}

private struct SheetRowView: View {
    @ObservedObject var record: ExpenseSheet
    @ObservedObject private var fx = FXRatesService.shared

    private var color: Color { Color(hex: record.displayColorHex) ?? .blue }
    private var expenseCount: Int { (record.expenses as? Set<Expense>)?.count ?? 0 }

    /// 全通貨を既定通貨に換算した今月の支出/収入合計
    private var monthlyTotals: (expense: Decimal, income: Decimal) {
        let totals = record.convertedMonthlyTotals()
        return (totals.expense, totals.income)
    }

    /// 全通貨を既定通貨に換算した今日の支出合計
    private var todayExpense: Decimal {
        let cal = Calendar.current
        return record.convertedTotals { e in
            cal.isDate(e.date ?? .distantPast, inSameDayAs: .now)
        }.expense
    }

    /// 全期間・全通貨換算の差額 (収入 - 支出)
    private var totalDiff: Decimal {
        let totals = record.convertedTotals()
        return totals.income - totals.expense
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.white)
                    .font(.callout)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.displayName)
                        .font(.headline)
                    ShareStatusBadge(record: record)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text(CurrencyCatalog.format(monthlyTotals.expense, code: code))
                        .foregroundStyle(.red)
                        .fontWeight(.semibold)
                    if monthlyTotals.income > 0 {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(CurrencyCatalog.format(monthlyTotals.income, code: code))
                            .foregroundStyle(.green)
                            .fontWeight(.semibold)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                if todayExpense > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "sun.max.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("今日 \(CurrencyCatalog.format(todayExpense, code: code))")
                            .foregroundStyle(.secondary)
                        if expenseCount > 0 {
                            Text("· \(expenseCount) 件").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption2)
                    .monospacedDigit()
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("差額")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(CurrencyCatalog.format(totalDiff, code: code))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(totalDiff >= 0 ? .green : .red)
            }
        }
        .padding(.vertical, 4)
    }

    private var code: String { record.resolvedDefaultCurrencyCode }
}

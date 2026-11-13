#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import Combine
import CoreData
import SwiftUI

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpandedSearch: Codable, Identifiable, Hashable {
    let sheetID: String
    let memberID: String?
    let name: String?
    let category: String?
    let kind: SiriTransactionSelection
    let interval: DateInterval?
    let period: String

    var id: Self { self }

    func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    @MainActor
    func load() throws -> (title: String, ledger: SiriTransactionLedger) {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try access.resolve(sheetID)
        if let memberID {
            let roster = try SiriSheetMemberRoster(sheet: sheet, access: access)
            guard let member = roster.members.first(where: { $0.id == memberID }) else { throw AppIntentError.missingPayer }
            return (member.name + " · " + sheet.displayName,
                    try SiriMemberTransactionLookup.ledger(in: sheet, access: access, member: member, roster: roster,
                                                          interval: interval, includeExpenses: kind.includesExpenses,
                                                          includeIncome: kind.includesIncome, previewOnly: false))
        }
        let title = [sheet.displayName, category, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return (title, try SiriTransactionLedger.read(sheet: sheet, access: access, interval: interval,
                                                      includeExpenses: kind.includesExpenses, includeIncome: kind.includesIncome,
                                                      expenseName: name, categoryName: category, previewOnly: false))
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
@MainActor
final class SiriExpandedNavigation: ObservableObject {
    static let shared = SiriExpandedNavigation()
    @Published var request: SiriExpandedSearch?
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriShowAllTransactionsIntent: AppIntent {
    static let title: LocalizedStringResource = "明細をすべて表示"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "検索条件") var search: String

    init() {}
    init(search: String) { self.search = search }

    @MainActor
    func perform() async throws -> some IntentResult {
        let request = try JSONDecoder().decode(SiriExpandedSearch.self, from: Data(search.utf8))
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        _ = try access.resolve(request.sheetID)
        SiriExpandedNavigation.shared.request = request
        return .result()
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpandedTransactionsView: View {
    let request: SiriExpandedSearch
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private struct Day: Identifiable {
        let id: String
        var rows: [SiriExpenseCardRow]
    }
    @State private var days: [Day] = []
    @State private var heading = ""
    @State private var total = ""
    @State private var loaded = false
    @State private var unavailable = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if unavailable {
                    ContentUnavailableView("この検索結果は現在表示できません。", systemImage: "lock")
                } else if loaded {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: heading).font(.headline)
                                Text(verbatim: request.period).font(.subheadline)
                                Text(verbatim: total).font(.body.bold().monospacedDigit())
                            }
                        }
                        if days.isEmpty {
                            Text("該当する明細はありません")
                        }
                        ForEach(days) { day in
                            Section {
                                ForEach(day.rows, id: \.expenseIdentifier) { row in
                                    if let identifier = row.expenseIdentifier {
                                        NavigationLink(value: identifier) { rowContent(row) }
                                    } else {
                                        rowContent(row)
                                    }
                                }
                            } header: { Text(verbatim: day.id) }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .privacySensitive()
            .navigationDestination(for: String.self) { identifier in
                if !unavailable, let access = try? IntentSheetAccess(checking: PersistenceController.shared.container.viewContext),
                   let target = try? SiriVirtualExpenseLink.resolve(identifier, access: access) {
                    switch target {
                    case .stored(let expense):
                        if let sheet = expense.sheet {
                            #if os(watchOS)
                            WatchExpenseDetailView(expense: expense, sheet: sheet)
                            #else
                            ExpenseDetailView(expense: expense, lockRecord: sheet)
                            #endif
                        }
                    case .virtual(let occurrence, _, _):
                        List {
                            Label("繰り返し", systemImage: "repeat")
                            Text(verbatim: CurrencyCatalog.format(occurrence.amount, code: occurrence.currencyCode))
                                .font(.title2.bold().monospacedDigit())
                            Text(verbatim: occurrence.title.isEmpty ? occurrence.categoryDisplayName : occurrence.title)
                            Text(occurrence.date, format: .dateTime.year().month().day())
                            if !occurrence.note.isEmpty { Text(verbatim: occurrence.note) }
                        }
                        .navigationTitle("詳細")
                    }
                } else {
                    ContentUnavailableView("この明細は現在表示できません。", systemImage: "lock")
                }
            }
            .navigationTitle("明細")
            #if !os(watchOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            #endif
        }
        .task(id: request) { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: RunLoop.main)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: RunLoop.main)) { _ in reload() }
        #if os(macOS)
        .frame(minWidth: 340, idealWidth: 460, minHeight: 320, idealHeight: 520)
        #endif
    }

    private func rowContent(_ row: SiriExpenseCardRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                labels(row)
                Spacer(minLength: 12)
                amount(row)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 3) {
                labels(row)
                amount(row)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func labels(_ row: SiriExpenseCardRow) -> some View {
        let subtitle = [row.category == row.title ? nil : row.category, row.payerName]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.title).font(.body)
            if !subtitle.isEmpty { Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func amount(_ row: SiriExpenseCardRow) -> some View {
        Text(verbatim: [row.signedAmount ?? row.amount, row.foreignCurrencyCode].compactMap { $0 }.joined(separator: " "))
            .font(.body.monospacedDigit())
    }

    @MainActor
    private func reload() {
        do {
            let (title, ledger) = try request.load()
            heading = title
            switch request.kind {
            case .expense: total = String(localized: "支出 \(ledger.expenseTotal)")
            case .income: total = String(localized: "収入 \(ledger.incomeTotal)")
            case .both: total = String(localized: "収支 \(ledger.netTotal)")
            }
            var grouped: [Day] = []
            for row in ledger.rows {
                if let last = grouped.indices.last, grouped[last].id == row.date {
                    grouped[last].rows.append(row)
                } else {
                    grouped.append(Day(id: row.date, rows: [row]))
                }
            }
            days = grouped
            unavailable = false
        } catch {
            path = []
            days = []
            heading = ""
            total = ""
            unavailable = true
        }
        loaded = true
    }
}
#endif

#if (os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import Combine
import CoreData
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@available(iOS 27.3, macOS 27.3, *)
struct SiriOpenResultsInAppIntent: AppIntent {
    static let title: LocalizedStringResource = "検索結果をBudgetyで開く"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "検索条件") var search: String

    init() {}
    init(search: String) { self.search = search }

    @MainActor
    func perform() async throws -> some IntentResult {
        let request = try SiriExpandedSearch.decode(search)
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        _ = try access.resolve(request.sheetID)
        SiriResultsPresenter.shared.open(request)
        return .result()
    }
}

@available(iOS 27.3, macOS 27.3, *)
@MainActor
final class SiriResultsPresenter: NSObject {
    static let shared = SiriResultsPresenter()

    #if os(iOS)
    private var pending: SiriExpandedSearch?

    func open(_ request: SiriExpandedSearch) {
        pending = request
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive && $0.keyWindow != nil }) {
            presentIfNeeded(in: scene)
        }
    }

    func presentIfNeeded(in scene: UIWindowScene) {
        guard let request = pending, scene.activationState == .foregroundActive,
              var presenter = scene.keyWindow?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        if let transition = presenter.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in
               Task { @MainActor in self.presentIfNeeded(in: scene) }
           }) { return }

        pending = nil
        let results = SiriAppResultsView(request: request) { [weak presenter] in
            presenter?.dismiss(animated: true)
        }
        presenter.present(UIHostingController(rootView: results), animated: true)
    }
    #else
    fileprivate var windows = [NSWindow]()

    func open(_ request: SiriExpandedSearch) {
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        window.delegate = self
        windows.append(window)
        window.title = String(localized: "明細")
        let results = SiriAppResultsView(request: request) { [weak window] in
            guard let window else { return }
            if let parent = window.sheetParent { parent.endSheet(window) }
            else { window.close() }
        }
        window.contentViewController = NSHostingController(rootView: results)
        window.setContentSize(NSSize(width: 500, height: 560))
        if var presenter = NSApp.keyWindow ?? NSApp.mainWindow {
            while let sheet = presenter.attachedSheet { presenter = sheet }
            presenter.beginSheet(window) { [weak window] _ in window?.close() }
        } else {
            // Keep a visible window when the last main window was already closed.
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
    #endif
}

#if os(macOS)
@available(macOS 27.3, *)
extension SiriResultsPresenter: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }
}
#endif

@available(iOS 27.3, macOS 27.3, *)
private struct SiriAppResultsView: View {
    let request: SiriExpandedSearch
    let close: () -> Void

    private struct Day: Identifiable {
        let id: String
        var rows: [SiriExpenseCardRow]
    }
    @State private var heading = ""
    @State private var total = ""
    @State private var days = [Day]()
    @State private var unavailable = false
    @State private var path = [String]()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if unavailable {
                    ContentUnavailableView("この検索結果は現在表示できません。", systemImage: "lock")
                } else {
                    List {
                        Section {
                            Text(verbatim: heading).font(.headline)
                            Text(verbatim: request.period)
                            Text(verbatim: total).font(.body.bold().monospacedDigit())
                        }
                        if days.isEmpty { Text("該当する明細はありません") }
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
                }
            }
            .navigationTitle("明細")
            .navigationDestination(for: String.self) { identifier in detail(identifier) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: close) }
            }
        }
        .privacySensitive()
        .onAppear(perform: refresh)
        .onChange(of: phase) { _, phase in if phase == .active { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: RunLoop.main)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: RunLoop.main)) { _ in refresh() }
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        .appUpdateGate()
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 300)
        #endif
    }

    private func rowContent(_ row: SiriExpenseCardRow) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: row.title)
                let subtitle = [row.title == row.category ? nil : row.category, row.payerName].compactMap { $0 }.joined(separator: " · ")
                if !subtitle.isEmpty { Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            Text(verbatim: [row.signedAmount ?? row.amount, row.foreignCurrencyCode].compactMap { $0 }.joined(separator: " "))
                .monospacedDigit()
        }
    }

    @ViewBuilder private func detail(_ identifier: String) -> some View {
        if !unavailable,
           let access = try? IntentSheetAccess(checking: PersistenceController.shared.container.viewContext),
           let target = try? SiriVirtualExpenseLink.resolve(identifier, access: access) {
            switch target {
            case .stored(let expense):
                if let sheet = expense.sheet { ExpenseDetailView(expense: expense, lockRecord: sheet) }
            case .virtual(let occurrence, let sheet, let rule):
                #if os(iOS)
                SiriVirtualExpenseDetail(identifier: identifier, occurrence: occurrence, sheet: sheet, rule: rule)
                    .id(identifier)
                #else
                if let draft = RecurringOccurrenceDraft(occurrence, sheet: sheet) {
                    ExpenseDetailView(expense: draft.expense, isVirtualDraft: true, lockRecord: sheet)
                }
                #endif
            }
        } else {
            ContentUnavailableView("この明細は現在表示できません。", systemImage: "lock")
        }
    }

    private func refresh() {
        do {
            let (title, ledger) = try request.load(payerPhotoLimit: 0)
            heading = title
            switch request.kind {
            case .expense: total = String(localized: "支出 \(ledger.expenseTotal)")
            case .income: total = String(localized: "収入 \(ledger.incomeTotal)")
            case .both: total = String(localized: "収支 \(ledger.netTotal)")
            }
            var grouped = [Day]()
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
            unavailable = true
            path = []
            days = []
            heading = ""
            total = ""
        }
    }
}
#endif

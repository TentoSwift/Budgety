#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import CryptoKit
import Foundation
import SwiftUI

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriExpandedSearch: Codable, Hashable {
    let sheetID: String
    let memberID: String?
    let name: String?
    let category: String?
    let kind: SiriTransactionSelection
    let interval: DateInterval?
    let period: String
    var presentationID: UUID? = UUID()

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(_ search: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(search.utf8))
    }

    @MainActor
    func load(pageOffset: Int? = nil, pageSize: Int = SiriTransactionPage.pageSize, payerPhotoLimit: Int? = nil) throws -> (title: String, ledger: SiriTransactionLedger) {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try access.resolve(sheetID)
        if let memberID {
            let roster = try SiriSheetMemberRoster(sheet: sheet, access: access)
            guard let member = roster.members.first(where: { $0.id == memberID }) else { throw AppIntentError.missingPayer }
            return (member.name + " · " + sheet.displayName,
                    try SiriMemberTransactionLookup.ledger(in: sheet, access: access, member: member, roster: roster,
                                                          interval: interval, includeExpenses: kind.includesExpenses,
                                                          includeIncome: kind.includesIncome, previewOnly: false,
                                                          pageOffset: pageOffset, pageSize: pageSize, payerPhotoLimit: payerPhotoLimit))
        }
        let title = [sheet.displayName, category, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return (title, try SiriTransactionLedger.read(sheet: sheet, access: access, interval: interval,
                                                      includeExpenses: kind.includesExpenses, includeIncome: kind.includesIncome,
                                                      expenseName: name, categoryName: category, previewOnly: false,
                                                      pageOffset: pageOffset, pageSize: pageSize, payerPhotoLimit: payerPhotoLimit))
    }

    @MainActor
    static func currentView(search: String) throws -> SiriExpenseCardView {
        if let position = SiriSnippetCursor.read(search), position != SiriSnippetCursor.compact {
            #if os(iOS) || os(macOS)
            if position == SiriSnippetCursor.overview {
                return SiriExpenseCardView(overview: try SiriTransactionOverview.load(search: search))
            }
            #endif
            return SiriExpenseCardView(page: try SiriTransactionPage.load(search: search, offset: position))
        }
        return try decode(search).compactView(search: search)
    }

    @MainActor
    func compactView(search: String) throws -> SiriExpenseCardView {
        if let memberID {
            let scope = SiriExpenseScope(interval: interval, label: period, isDay: false)
            var card = try SiriMemberTransactionLookup.search(sheetID: sheetID, memberIdentifier: memberID, scope: scope,
                                                              includeExpenses: kind.includesExpenses, includeIncome: kind.includesIncome).card
            card.expandedSearch = search
            return SiriExpenseCardView(member: card, resumePage: false)
        }
        var card = try SiriExpenseLookup.search(sheetID: sheetID, expenseName: name, categoryName: category,
                                                interval: interval, periodLabel: period, kind: kind).card
        card.expandedSearch = search
        return SiriExpenseCardView(result: card, resumePage: false)
    }
}

// Siri can render the same answer in another process, or from its transcript later.
// Store only an opaque card key and its cursor. Fetch every amount again with current sheet access.
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
@MainActor
enum SiriSnippetCursor {
    private static let key = "SiriTransactionSnippetCursors.v1"
    static let compact = -1
    static let overview = -2

    private static func cardKey(_ search: String) -> String {
        let request = try? SiriExpandedSearch.decode(search)
        if let id = request?.presentationID { return id.uuidString }
        // Older cards have no ID. Their JSON keys may have been written in a different order.
        let canonical = (try? request?.encoded()) ?? search
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64EncodedString()
    }

    static func read(_ search: String) -> Int? {
        let entries = UserDefaults.standard.array(forKey: key) as? [[String: Int]]
        let id = cardKey(search)
        return entries?.lazy.compactMap { $0[id] }.first
    }

    static func set(_ offset: Int, for search: String) {
        let id = cardKey(search)
        var entries = UserDefaults.standard.array(forKey: key) as? [[String: Int]] ?? []
        entries.removeAll { $0[id] != nil }
        UserDefaults.standard.set(Array(([[id: offset]] + entries).prefix(64)), forKey: key)
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
@MainActor
struct SiriTransactionPage {
    let search: String
    let title: String
    let period: String
    let rows: [SiriExpenseCardRow]
    let start: Int
    let totalCount: Int

    #if os(watchOS)
    static let pageSize = 1
    #else
    static let pageSize = 3
    #endif

    static func load(search: String, offset: Int) throws -> Self {
        let request = try SiriExpandedSearch.decode(search)
        let (title, ledger) = try request.load(pageOffset: offset, pageSize: pageSize)
        return Self(search: search, title: title, period: request.period, rows: ledger.rows,
                    start: SiriTransactionLedger.clampedStart(offset: offset, count: ledger.count, pageSize: pageSize),
                    totalCount: ledger.count)
    }
}

#if os(iOS) || os(macOS)
@available(iOS 27.3, macOS 27.3, *)
@MainActor
struct SiriTransactionOverview {
    let search: String
    let title: String
    let period: String
    let rows: [SiriExpenseCardRow]
    let totalCount: Int
    static let maxRows = 8

    static func load(search: String) throws -> Self {
        let request = try SiriExpandedSearch.decode(search)
        let (title, ledger) = try request.load(pageOffset: 0, pageSize: maxRows)
        return Self(search: search, title: title, period: request.period, rows: ledger.rows, totalCount: ledger.count)
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriTransactionListSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "検索した明細の一覧カードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "検索条件") var search: String

    init() {}
    init(search: String) { self.search = search }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        if let position = SiriSnippetCursor.read(search), position != SiriSnippetCursor.overview {
            return .result(view: try SiriExpandedSearch.currentView(search: search))
        }
        return .result(view: SiriExpenseCardView(overview: try SiriTransactionOverview.load(search: search)))
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriShowTransactionListIntent: AppIntent {
    static let title: LocalizedStringResource = "検索した明細の一覧を表示"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "検索条件") var search: String

    init() {}
    init(search: String) { self.search = search }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SiriExpenseCardRow]> & ShowsSnippetIntent {
        let request = try SiriExpandedSearch.decode(search)
        let (_, ledger) = try request.load(payerPhotoLimit: SiriTransactionOverview.maxRows)
        // Siri can present the individual entities as a collection. Other hosts can
        // redraw the existing answer with the same query, starting at the first match.
        SiriSnippetCursor.set(SiriSnippetCursor.overview, for: search)
        return .result(value: ledger.rows, snippetIntent: SiriTransactionListSnippetIntent(search: search))
    }
}
#endif

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriShowAllTransactionsIntent: AppIntent {
    static let title: LocalizedStringResource = "明細をすべて表示"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "検索条件") var search: String
    @Parameter(title: "表示開始位置") var offset: Int?

    init() {}
    init(search: String, offset: Int = 0) {
        self.search = search
        self.offset = offset
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let requested = offset ?? 0
        #if os(iOS) || os(macOS)
        // Older Siri transcripts called this paging action from their compact preview.
        // Their first tap now opens the overview, just like a newly archived button.
        if requested >= 0, (SiriSnippetCursor.read(search) ?? SiriSnippetCursor.compact) == SiriSnippetCursor.compact {
            let overview = try SiriTransactionOverview.load(search: search)
            SiriSnippetCursor.set(SiriSnippetCursor.overview, for: search)
            let dialog: IntentDialog = overview.rows.isEmpty ? "該当する明細はありません。" : "明細の一覧を表示しました。"
            return .result(dialog: dialog, snippetIntent: SiriTransactionListSnippetIntent(search: search))
        }
        #endif
        let page = try SiriTransactionPage.load(search: search, offset: requested)
        let position = requested == SiriSnippetCursor.compact ? requested : page.start
        SiriSnippetCursor.set(position, for: search)
        let snippet = SiriTransactionPageSnippetIntent(search: search, offset: position)
        let dialog: IntentDialog
        if position == SiriSnippetCursor.compact {
            dialog = "検索結果に戻りました。"
        } else if page.rows.isEmpty {
            dialog = "該当する明細はありません。"
        } else {
            let lines = page.rows.map { "\($0.date)　\($0.title)　\($0.signedAmount ?? $0.amount)" }.joined(separator: "、")
            dialog = IntentDialog(full: "\(lines)", supporting: "明細を表示しました。")
        }
        return .result(dialog: dialog, snippetIntent: snippet)
    }
}

@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriTransactionPageSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "検索した明細の続きを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "検索条件") var search: String
    @Parameter(title: "表示開始位置") var offset: Int

    init() {}
    init(search: String, offset: Int) {
        self.search = search
        self.offset = offset
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let position = SiriSnippetCursor.read(search) ?? offset
        #if os(iOS) || os(macOS)
        if position == SiriSnippetCursor.overview {
            return .result(view: SiriExpenseCardView(overview: try SiriTransactionOverview.load(search: search)))
        }
        #endif
        if position == SiriSnippetCursor.compact {
            let view = try SiriExpandedSearch.decode(search).compactView(search: search)
            return .result(view: view)
        }
        return .result(view: SiriExpenseCardView(page: try SiriTransactionPage.load(search: search, offset: position)))
    }
}
#endif

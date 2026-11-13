#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
import AppIntents
import CoreData
import SwiftUI

enum SiriRosterFilter: String, AppEnum {
    case all, participants, virtualMembers
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "メンバーの範囲"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "全員", .participants: "参加者のみ", .virtualMembers: "バーチャルメンバーのみ"
    ]

    var contents: SiriDirectoryContents {
        switch self {
        case .all: .members
        case .participants: .participants
        case .virtualMembers: .virtualMembers
        }
    }
}

enum SiriDirectoryContents: String, AppEnum {
    case members, participants, virtualMembers, categories, expenseCategories, incomeCategories
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "一覧の種類"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .members: "メンバー", .participants: "参加者", .virtualMembers: "バーチャルメンバー",
        .categories: "カテゴリ", .expenseCategories: "支出カテゴリ", .incomeCategories: "収入カテゴリ"
    ]

    var heading: String {
        switch self {
        case .members: String(localized: "メンバー")
        case .participants: String(localized: "参加者")
        case .virtualMembers: String(localized: "バーチャルメンバー")
        case .categories: String(localized: "カテゴリ")
        case .expenseCategories: String(localized: "支出カテゴリ")
        case .incomeCategories: String(localized: "収入カテゴリ")
        }
    }
}

@available(iOS 27.3, macOS 27.3, *)
#if os(iOS) || os(macOS)
@AppIntent(.tool)
#endif
struct SiriListSheetMembersIntent: AppIntent {
    static let title: LocalizedStringResource = "シートのメンバーを表示"
    static let description = IntentDescription("「家計のシートには誰がいる？」「旅行のバーチャルメンバーを教えて」に、現在の参加者やバーチャルメンバーをプロフィール付きのカードで返します。", searchKeywords: ["参加者", "メンバー一覧", "バーチャルメンバー"])
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "シート") var sheet: ExpenseSheetEntity?
    @Parameter(title: "メンバーの範囲", description: "省略すると、参加者とバーチャルメンバーの両方を表示します。")
    var filter: SiriRosterFilter?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SiriSheetDirectoryResult> & ProvidesDialog & ShowsSnippetIntent {
        let sheetID = try await SiriExpenseLookup.sheetIdentifier(sheet: sheet) {
            try await $sheet.requestDisambiguation(among: $0, dialog: "どのシートのメンバーを表示しますか？")
        }
        let contents = (filter ?? .all).contents
        let result = try SiriSheetDirectoryResult.load(sheetID: sheetID, contents: contents)
        return .result(value: result, dialog: IntentDialog("\(result.summary)"),
                       snippetIntent: SiriSheetDirectorySnippetIntent(sheetID: sheetID, contents: contents))
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriSheetDirectorySnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "シートの一覧カードを表示"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "シートの識別子") var sheetID: String
    @Parameter(title: "一覧の種類") var contents: SiriDirectoryContents

    init() {}
    init(sheetID: String, contents: SiriDirectoryContents) {
        self.sheetID = sheetID
        self.contents = contents
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let result = try SiriSheetDirectoryResult.load(sheetID: sheetID, contents: contents)
        return .result(view: SiriSheetDirectoryCard(result: result))
    }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriDirectoryEntry: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "一覧の項目"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Property(title: "名前") var name: String
    @Property(title: "種別") var detail: String
    #if os(watchOS)
    var colorHex = ""
    var symbol: String?
    var photo: IntentFile?
    var isVirtual = false
    #else
    @Property(title: "色", visibility: .internal) var colorHex: String
    @Property(title: "カテゴリのアイコン", visibility: .internal) var symbol: String?
    @Property(title: "プロフィール画像", visibility: .internal) var photo: IntentFile?
    @Property(title: "バーチャルメンバー", visibility: .internal) var isVirtual: Bool
    #endif

    init() {}
    init(name: String, detail: String, colorHex: String, symbol: String? = nil, photo: IntentFile? = nil, isVirtual: Bool = false) {
        self.name = name
        self.detail = detail
        self.colorHex = colorHex
        self.symbol = symbol
        self.photo = photo
        self.isVirtual = isVirtual
    }

    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)", subtitle: "\(detail)") }
}

@available(iOS 27.3, macOS 27.3, *)
struct SiriSheetDirectoryResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "シートの一覧"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let previewLimit = 5

    @Property(title: "シート名") var sheetName: String
    @Property(title: "一覧の種類") var contents: SiriDirectoryContents
    @Property(title: "項目") var rows: [SiriDirectoryEntry]
    #if os(watchOS)
    var sheetSymbol = ""
    var sheetColorHex = ""
    #else
    @Property(title: "シートのアイコン", visibility: .internal) var sheetSymbol: String
    @Property(title: "シートの色", visibility: .internal) var sheetColorHex: String
    #endif

    var displayRepresentation: DisplayRepresentation { .init(title: "\(sheetName)", subtitle: "\(contents.heading)") }
    var summary: String {
        guard !rows.isEmpty else { return String(localized: "「\(sheetName)」に該当する\(contents.heading)はありません。") }
        let names = rows.map(\.name).formatted(.list(type: .and))
        return String(localized: "「\(sheetName)」の\(contents.heading)は、\(names)です。")
    }

    @MainActor
    static func load(sheetID: String, contents: SiriDirectoryContents) throws -> Self {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let sheet = try access.resolve(sheetID)
        var result = Self()
        result.sheetName = sheet.displayName
        result.sheetSymbol = sheet.displaySymbol
        result.sheetColorHex = sheet.displayColorHex
        result.contents = contents
        switch contents {
        case .members, .participants, .virtualMembers:
            let roster = try SiriSheetMemberRoster(sheet: sheet, access: access)
            let members = roster.members.filter { member in
                let virtual = UserProfileStore.isVirtualRecordName(member.profileID)
                return contents == .members || (contents == .virtualMembers) == virtual
            }
            result.rows = members.enumerated().map { index, member in
                let color: String
                let photo: Data?
                if member.isSelf {
                    color = UserProfileStore.shared.avatarBgColorHex ?? "#5B8DEF"
                    photo = UserProfileStore.shared.photoData
                } else {
                    let info = sheet.memberDisplayInfo(for: member.profileID)
                    color = info.colorHex
                    photo = info.photoData
                }
                return SiriDirectoryEntry(name: member.name, detail: member.role, colorHex: color,
                                          photo: index < previewLimit ? SiriExpensePayer.thumbnail(from: photo) : nil,
                                          isVirtual: UserProfileStore.isVirtualRecordName(member.profileID))
            }
        case .categories, .expenseCategories, .incomeCategories:
            result.rows = SiriCategoryStore.sortedCategories(in: sheet).compactMap { category in
                if contents == .expenseCategories && category.kind != .expense { return nil }
                if contents == .incomeCategories && category.kind != .income { return nil }
                return SiriDirectoryEntry(name: category.displayName, detail: category.kind.label,
                                          colorHex: category.displayColorHex, symbol: category.displaySymbol)
            }
        }
        return result
    }
}

#if os(iOS) || os(macOS)
@available(iOS 27.3, macOS 27.3, *)
extension SiriSheetDirectoryResult: SnippetRepresentableEntity {
    static var snippet: some EntitySnippetContent<Self> {
        CardSnippet(supportedFamilies: [.standard]) { result, _ in SiriSheetDirectoryCard(result: result) }
    }
}
#endif

@available(iOS 27.3, macOS 27.3, *)
struct SiriSheetDirectoryCard: View {
    let result: SiriSheetDirectoryResult
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let secondary = Color(white: colorScheme == .dark ? 0.82 : 0.30)
        ViewThatFits(in: .vertical) {
            ForEach((0...min(result.rows.count, SiriSheetDirectoryResult.previewLimit)).reversed(), id: \.self) { limit in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SheetSymbolIcon(symbol: result.sheetSymbol, tint: Color(hex: result.sheetColorHex) ?? .indigo, size: 24)
                            .accessibilityHidden(true)
                        Text("\(result.sheetName) · \(result.contents.heading)").font(.headline)
                    }
                    if result.rows.isEmpty {
                        Text("該当する項目はありません").font(.subheadline)
                    }
                    ForEach(0..<limit, id: \.self) { index in
                        let entry = result.rows[index]
                        HStack(spacing: 8) {
                            if let symbol = entry.symbol {
                                CategoryIconView(symbol: symbol, tint: Color(hex: entry.colorHex) ?? .gray, size: 28)
                                    .accessibilityHidden(true)
                            } else {
                                AvatarView(photoData: entry.photo?.data, displayName: entry.name, colorHex: entry.colorHex,
                                           size: 28, isVirtual: entry.isVirtual).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: entry.name).font(.body)
                                Text(verbatim: entry.detail).font(.caption).foregroundStyle(secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if result.rows.count > limit {
                        Text("+\(result.rows.count - limit)件").font(.caption).foregroundStyle(secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .foregroundStyle(Color(white: colorScheme == .dark ? 1.0 : 0.08))
        .background(Color(white: colorScheme == .dark ? 0.10 : 0.98), in: RoundedRectangle(cornerRadius: 14))
        .privacySensitive()
    }
}
#endif

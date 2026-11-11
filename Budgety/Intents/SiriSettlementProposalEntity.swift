#if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
import AppIntents
import CoreData
import Foundation

@available(iOS 27.3, *)
struct SiriSettlementProposalEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "送金の提案"
    static let defaultQuery = SiriSettlementProposalQuery()
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    let id: String
    @Property(title: "シートの識別子", visibility: .internal) var sheetID: String
    @Property(title: "シート名") var sheetName: String
    @Property(title: "送金者") var fromName: String
    @Property(title: "受取者") var toName: String
    @Property(title: "金額") var amount: String

    init(sheetID: String, sheetName: String, proposal: SiriSettlementStore.Proposal) {
        id = proposal.id
        self.sheetID = sheetID
        self.sheetName = sheetName
        fromName = proposal.fromName
        toName = proposal.toName
        amount = proposal.formattedAmount
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(fromName) → \(toName)", subtitle: "\(amount) · \(sheetName)")
    }
}

@available(iOS 27.3, *)
struct SiriSettlementProposalQuery: EntityStringQuery {
    @IntentParameterDependency<SiriSettleSuggestedTransferIntent>(\.$sheet) var selection

    @MainActor
    func suggestedEntities() async throws -> [SiriSettlementProposalEntity] {
        let sheets = try SiriSettlementStore.writableSheets()
        if let id = selection?.sheet.id {
            guard let sheet = sheets.first(where: { $0.id == id }) else { return [] }
            return try Self.proposals(in: sheet)
        }
        return try Self.availableProposals(across: sheets)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriSettlementProposalEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await suggestedEntities().filter {
            query.isEmpty || [$0.fromName, $0.toName, $0.sheetName, $0.amount, "\($0.fromName) → \($0.toName)"].contains {
                $0.localizedStandardContains(query)
            }
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriSettlementProposalEntity] {
        let sheetIDs = Set(identifiers.compactMap(Self.sheetIdentifier(of:)))
        let sheets = try SiriSettlementStore.writableSheets().filter {
            sheetIDs.contains($0.id) && (selection?.sheet.id == nil || selection?.sheet.id == $0.id)
        }
        let current = try Self.availableProposals(across: sheets)
        return identifiers.compactMap { id in current.first { $0.id == id } }
    }

    @MainActor
    static func proposals(in sheet: ExpenseSheetEntity) throws -> [SiriSettlementProposalEntity] {
        try SiriSettlementStore.proposals(sheetID: sheet.id).map {
            SiriSettlementProposalEntity(sheetID: sheet.id, sheetName: sheet.name, proposal: $0)
        }
    }

    @MainActor
    static func availableProposals(across sheets: [ExpenseSheetEntity]) throws -> [SiriSettlementProposalEntity] {
        var result: [SiriSettlementProposalEntity] = []
        for sheet in sheets {
            do { result += try proposals(in: sheet) }
            // A sheet with an open, unsaved edit cannot supply a payable proposal.
            catch SiriSettlementStore.Failure.changed, SiriSettlementStore.Failure.readOnly { continue }
        }
        return result
    }

    static func sheetIdentifier(of identifier: String) -> String? {
        guard let fragment = identifier.firstIndex(of: "#"), fragment != identifier.startIndex else { return nil }
        return String(identifier[..<fragment])
    }
}

@available(iOS 27.3, *)
struct SiriSettlementWritableSheetQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [ExpenseSheetEntity] { try SiriSettlementStore.writableSheets() }

    @MainActor
    func entities(matching string: String) async throws -> [ExpenseSheetEntity] {
        let name = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return try SiriSettlementStore.writableSheets().filter { name.isEmpty || $0.name.localizedStandardContains(name) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExpenseSheetEntity] {
        let available = try SiriSettlementStore.writableSheets()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
}

@available(iOS 27.3, *)
protocol SettlementMemberOptions: SheetScopedMemberQuery {
    var requestedSheetID: String? { get }
    var senderID: String? { get }
}

@available(iOS 27.3, *)
extension SettlementMemberOptions {
    @MainActor func selectedSheetID(access: IntentSheetAccess) throws -> String? {
        requestedSheetID ?? senderID.flatMap(SiriSettlementProposalQuery.sheetIdentifier(of:))
    }

    @MainActor func suggestedEntities() async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let scope = try selectedSheetID(access: access)
        let sheets = try SiriSettlementStore.writableSheets().filter { scope == nil || $0.id == scope }
        return try sheets.flatMap { sheet -> [SiriSheetMemberEntity] in
            let members = try SiriSettlementStore.members(in: access.resolve(sheet.id), access: access)
            guard members.count > 1 else { return [] }
            return members.filter { $0.id != senderID }
        }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [SiriSheetMemberEntity] {
        let available = try await suggestedEntities()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
}

@available(iOS 27.3, *)
struct SiriSettlementSenderQuery: SettlementMemberOptions {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriLogSettlementTransferIntent>(\.$sheet) var selection
    var requestedSheetID: String? { selection?.sheet.id }
    var senderID: String? { nil }
}

@available(iOS 27.3, *)
struct SiriSettlementRecipientQuery: SettlementMemberOptions {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriLogSettlementTransferIntent>(\.$sheet) var selection
    @IntentParameterDependency<SiriLogSettlementTransferIntent>(\.$fromMember) var source
    var requestedSheetID: String? { selection?.sheet.id }
    var senderID: String? { source?.fromMember.id }
}
#endif

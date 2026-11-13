import AppIntents
import CloudKit
import CoreData

struct SiriSheetMemberEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "シートのメンバー"
    static let defaultQuery = SiriSheetMemberQuery()
    #if (os(iOS) || os(macOS) || os(watchOS)) && canImport(AppIntents, _version: 301.2.7.2)
    @available(iOS 27.3, macOS 27.3, watchOS 27.3, *)
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    #endif

    let id: String
    let profileID: String
    let memberID: UUID?
    let isSelf: Bool
    let name: String
    let sheetName: String
    fileprivate let aliases: [String]
    let role: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(sheetName) · \(role)",
                              image: .init(systemName: isSelf ? "person.crop.circle" : "person.fill"))
    }
}

private enum SiriSheetMemberError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    var localizedStringResource: LocalizedStringResource { "このシートの現在のメンバーを選び直してください。" }
}

/// Use the split picker's current participants. Never resolve a saved selection by name.
@MainActor
struct SiriSheetMemberRoster {
    let members: [SiriSheetMemberEntity]
    let selfProfileIDs: Set<String>

    init(sheet: ExpenseSheet, access: IntentSheetAccess, preparingToSave: Bool = false) throws {
        let sheetID = sheet.objectID.uriRepresentation().absoluteString
        let stored = try access.resolve(sheetID)
        let profile = UserProfileStore.shared
        let share = ShareCoordinator.shared.existingShare(for: stored)
        let localSelfID = profile.selfMemberID
        var activeIDs = Self.activeIDs(in: stored)
        if access.viewContext.hasChanges,
           let editing = try access.viewContext.existingObject(with: stored.objectID) as? ExpenseSheet {
            let allowed = Set(Self.activeIDs(in: editing))
            activeIDs.removeAll { !allowed.contains($0) }
        }

        let request = NSFetchRequest<Member>(entityName: "Member")
        var memberFilters = [NSPredicate(format: "recordName IN %@", activeIDs)]
        if let localSelfID { memberFilters.append(NSPredicate(format: "id == %@", localSelfID as CVarArg)) }
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: memberFilters)
        let local = try access.context.fetch(request)
        let me = localSelfID.flatMap { id in local.first { $0.id == id } }
        let selfID = [profile.canonicalSelfID(forShare: share), localSelfID?.uuidString]
            .compactMap { $0 }.first { !$0.isEmpty && !UserProfileStore.isSelfPlaceholderRecordName($0) }
            ?? (preparingToSave ? profile.ensureSelfMemberID().uuidString : "")
        var selfAliases = profile.canonicalSelfIDs(forShare: share)
        if !selfID.isEmpty { selfAliases.insert(selfID) }
        if let localSelfID { selfAliases.insert(localSelfID.uuidString) }
        if let me, profile.canonicalSelfID(forShare: share) == nil,
           let cachedID = me.recordName, !cachedID.isEmpty { selfAliases.insert(cachedID) }
        if let email = profile.selfEmail, !email.isEmpty { selfAliases.insert("email:" + email.lowercased()) }

        selfProfileIDs = selfAliases
        let profiles = (stored.participantProfiles as? Set<ParticipantProfile>) ?? []
        let selfProfile = profiles.first { $0.recordName.map(selfAliases.contains) == true && !$0.archived }
        let selfName = selfProfile?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? profile.resolvedDisplayName
        var result = [SiriSheetMemberEntity(
            id: sheetID + "#self", profileID: selfID, memberID: profile.selfMemberID, isSelf: true,
            name: selfName, sheetName: stored.displayName,
            aliases: [profile.resolvedDisplayName, "自分", "私", "わたし", "僕", "ぼく", "me", "myself"],
            role: String(localized: "自分")
        )]
        for id in activeIDs where !selfAliases.contains(id) {
            let profileNames = profiles.filter { !$0.archived && $0.recordName == id }
                .compactMap(\.displayName).filter { !$0.isEmpty }
            // A legacy local self cache can still carry another participant’s record name.
            let matchingMembers = local.filter { $0.recordName == id && ($0.id == nil || $0.id != localSelfID) }
            let participant = share?.participants.first { $0.budgetyCanonicalID == id && $0.acceptanceStatus == .accepted }
            let cloudName = participant?.userIdentity.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) }
            let displayName = stored.memberDisplayInfo(for: id).name
            let role: String = UserProfileStore.isVirtualRecordName(id) ? String(localized: "バーチャルメンバー")
                : (participant?.role == .owner ? String(localized: "オーナー") : String(localized: "参加者"))
            result.append(SiriSheetMemberEntity(
                id: sheetID + "#member:" + id, profileID: id,
                memberID: matchingMembers.count == 1 ? matchingMembers[0].id : nil,
                isSelf: false, name: displayName, sheetName: stored.displayName,
                aliases: profileNames + matchingMembers.map(\.displayName) + [cloudName].compactMap { $0 }, role: role
            ))
        }
        members = result
    }

    func resolve(_ selection: SiriSheetMemberEntity) throws -> SiriSheetMemberEntity {
        guard let current = members.first(where: { $0.id == selection.id }) else { throw SiriSheetMemberError.unavailable }
        return current
    }

    /// Identity aliases used only for legacy rows with a name and no stable payer ID.
    func uniqueStoredNames(for member: SiriSheetMemberEntity, in sheet: ExpenseSheet) -> Set<String> {
        func names(_ person: SiriSheetMemberEntity) -> [String] {
            // Spoken pronouns resolve the intent's parameter, not a historical payer's identity.
            let aliases = person.isSelf ? [UserProfileStore.shared.resolvedDisplayName] : person.aliases
            return ([person.name] + aliases).map(Self.storedNameKey)
        }
        var result = Set(names(member))
        for other in members where other.id != member.id { result.subtract(names(other)) }
        let ids = member.isSelf ? selfProfileIDs : [member.profileID]
        for profile in sheet.participantProfiles as? Set<ParticipantProfile> ?? [] {
            guard !ids.contains(profile.recordName ?? ""), let name = profile.displayName else { continue }
            result.remove(Self.storedNameKey(name))
        }
        result.remove("")
        result.remove(Self.storedNameKey(String(localized: "メンバー")))
        return result
    }

    nonisolated static func storedNameKey(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
        return (normalized.applyingTransform(.hiraganaToKatakana, reverse: false) ?? normalized)
            .filter { !$0.isWhitespace }
    }

    /// A spoken name can belong to any accessible sheet. Keep the current sheet first for disambiguation.
    static func searchCandidates(access: IntentSheetAccess, sheetID: String?) throws -> [SiriSheetMemberEntity] {
        if let sheetID { return try Self(sheet: access.resolve(sheetID), access: access).members }
        var sheets = try access.sheets()
        if let last = IntentSheetAccess.lastOpenedSheetURI,
           let index = sheets.firstIndex(where: { $0.objectID.uriRepresentation().absoluteString == last }) {
            let current = sheets.remove(at: index)
            sheets.insert(current, at: 0)
        }
        return try sheets.flatMap { try Self(sheet: $0, access: access).members }
    }

    private static func activeIDs(in sheet: ExpenseSheet) -> [String] {
        // The offline picker can still have a stored profile for an archived member.
        let inactive = (sheet.participantProfiles as? Set<ParticipantProfile> ?? [])
            .filter { $0.archived || $0.isDeleted }.compactMap(\.recordName)
        return sheet.acceptedMemberProfileIDs().filter { !inactive.contains($0) }
    }
}

protocol SheetScopedMemberQuery: EntityStringQuery where Entity == SiriSheetMemberEntity, Result == [SiriSheetMemberEntity], DefaultValue == SiriSheetMemberEntity {
    @MainActor func selectedSheetID(access: IntentSheetAccess) throws -> String?
}

extension SheetScopedMemberQuery {
    @MainActor
    func suggestedEntities() async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        guard let scope = try selectedSheetID(access: access) else { return [] }
        return try SiriSheetMemberRoster(sheet: access.resolve(scope), access: access).members
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriSheetMemberEntity] {
        let members = try await suggestedEntities()
        let query = SiriSheetMemberRoster.storedNameKey(string)
        guard !query.isEmpty else { return members }
        let candidates = members.map { ($0, ([$0.name] + $0.aliases).map(SiriSheetMemberRoster.storedNameKey)) }
        let exact = candidates.filter { $0.1.contains(query) }
        if exact.count > 1, exact.allSatisfy({ $0.0.isSelf }),
           ["私", "わたし", "自分", "僕", "ぼく", "me", "myself"].map(SiriSheetMemberRoster.storedNameKey).contains(query),
           let last = IntentSheetAccess.lastOpenedSheetURI,
           let current = exact.first(where: { $0.0.id == last + "#self" }) {
            return [current.0]
        }
        if !exact.isEmpty { return exact.map(\.0) }

        // Siri may include an honorific in the spoken name. A literal member name
        // such as お母さん has already had a chance to match in full.
        let suffixes = ["さん", "ちゃん", "くん", "さま", "様", "君"].map(SiriSheetMemberRoster.storedNameKey)
        let base = suffixes.first(where: { query.count > $0.count && query.hasSuffix($0) })
            .map { String(query.dropLast($0.count)) } ?? query
        let stripped = candidates.filter { $0.1.contains(base) }
        if !stripped.isEmpty { return stripped.map(\.0) }
        return candidates.filter { $0.1.contains { $0.contains(base) } }.map(\.0)
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        let scope = try selectedSheetID(access: access)
        var bySheet: [String: [SiriSheetMemberEntity]] = [:]
        return try identifiers.compactMap { id in
            // Core Data object URI strings never contain a fragment. The suffix is an opaque identity.
            guard let separator = id.firstIndex(of: "#") else { return nil }
            let sheetID = String(id[..<separator])
            guard scope == nil || sheetID == scope else { return nil }
            if bySheet[sheetID] == nil {
                guard let stored = try? access.resolve(sheetID) else { return nil }
                bySheet[sheetID] = try SiriSheetMemberRoster(sheet: stored, access: access).members
            }
            return bySheet[sheetID]?.first { $0.id == id }
        }
    }
}

struct SiriSheetMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<AddExpenseIntent>(\.$sheet) var addExpense
    @IntentParameterDependency<AddExpenseIntent>(\.$sheetName) var nameOverride

    @MainActor
    func suggestedEntities() async throws -> [SiriSheetMemberEntity] {
        let access = try IntentSheetAccess(checking: PersistenceController.shared.container.viewContext)
        if let id = try selectedSheetID(access: access) {
            return try SiriSheetMemberRoster(sheet: access.resolve(id), access: access).members
        }
        // Siri may resolve a spoken person through the entity's default query before
        // invoking a tool. A shortcut still editing its sheet uses the scoped picker.
        guard addExpense == nil, nameOverride == nil else { return [] }
        return try SiriSheetMemberRoster.searchCandidates(access: access, sheetID: nil)
    }

    @MainActor
    func selectedSheetID(access: IntentSheetAccess) throws -> String? {
        if let name = nameOverride?.sheetName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let sheets = try access.sheets()
            let exact = sheets.filter { $0.name == name }
            let matches = exact.isEmpty ? sheets.filter { $0.name?.caseInsensitiveCompare(name) == .orderedSame } : exact
            guard matches.count == 1 else { throw AppIntentError.sheetNotFound }
            return matches[0].objectID.uriRepresentation().absoluteString
        }
        return addExpense?.sheet.id
    }
}

#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
struct SiriRecordingMemberQuery: SheetScopedMemberQuery {
    typealias Entity = SiriSheetMemberEntity
    typealias Result = [SiriSheetMemberEntity]
    typealias DefaultValue = SiriSheetMemberEntity
    @IntentParameterDependency<SiriRecordExpenseIntent>(\.$sheet) var expense
    @IntentParameterDependency<SiriRecordIncomeIntent>(\.$sheet) var income

    func selectedSheetID(access: IntentSheetAccess) throws -> String? { expense?.sheet.id ?? income?.sheet.id }
}
#endif

//
//  PersistenceController.swift
//  Expenso
//

import CoreData
import CloudKit
import Combine

final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    var privateStore: NSPersistentStore?
    var sharedStore: NSPersistentStore?

    /// CloudKit からの初回 import が完了したか。Free 上限の判定に使う:
    /// 完了前にシート作成を許すと、後から sync で来た既存シートと合わせて
    /// 上限超過になってしまうため、ゲート側でこのフラグが false の間は
    /// 「同期待ち」として作成をブロックする。
    /// 一度 true になったら UserDefaults に永続化し、次回起動時は最初から true。
    @Published private(set) var initialSyncComplete: Bool = UserDefaults.standard.bool(forKey: PersistenceController.initialSyncCompleteKey)

    /// iCloud アカウントが利用可能か (= サインイン済み)。
    /// `.noAccount` / `.restricted` の時のみ false。判定前は楽観的に true。
    /// シート作成ゲートで同期的に参照するためキャッシュしている。
    @Published private(set) var iCloudAccountAvailable: Bool = true

    private static let cloudKitContainerIdentifier = "iCloud.com.tento.budgety"
    private static let initialSyncCompleteKey = "ExpensoInitialSyncComplete"

    /// `save()` で configuration mismatch を検知した時に立てるフラグ。
    /// 次回起動時にこのフラグが立っていれば、ストアを無条件で破棄してから loadPersistentStores する。
    private static let storeNeedsResetKey = "expensoStoreNeedsReset"

    /// 一度きりの seed/migration を実行済みかを記録する UserDefaults キー。
    /// 値は最後に実行したリビジョン番号。新しい migration を追加したらこの定数を上げる。
    private static let migrationRevisionKey = "expensoMigrationRevision"
    private static let currentMigrationRevision = 1

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Expenso")

        guard let baseDescription = container.persistentStoreDescriptions.first,
              let baseURL = baseDescription.url else {
            fatalError("ストア記述子が取得できませんでした")
        }

        baseDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        baseDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        // 軽量マイグレーションを明示。スキーマ変更があっても自動でマッピングを推論する。
        baseDescription.shouldMigrateStoreAutomatically = true
        baseDescription.shouldInferMappingModelAutomatically = true
        // ロードを同期化。init 内で privateStore/sharedStore が確実に埋まり、後段の seed/migration の
        // 競合 (空 fetch・nil ストア) を防ぐ。
        baseDescription.shouldAddStoreAsynchronously = false
        baseDescription.configuration = "Private"

        // 共有シートの受信には Private/Shared 両ストアに CloudKit オプションが要るため、
        // 常に有効化する。Premium ゲートは「共有を作る」など UI レベルでかける。
        if !inMemory {
            let privateOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
            privateOptions.databaseScope = .private
            baseDescription.cloudKitContainerOptions = privateOptions
        } else {
            baseDescription.cloudKitContainerOptions = nil
        }

        if !inMemory {
            let sharedURL = baseURL.deletingLastPathComponent().appendingPathComponent("Expenso-shared.sqlite")
            let sharedDescription = baseDescription.copy() as! NSPersistentStoreDescription
            sharedDescription.url = sharedURL
            let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions
            sharedDescription.configuration = "Shared"

            container.persistentStoreDescriptions = [baseDescription, sharedDescription]
        } else {
            container.persistentStoreDescriptions = [baseDescription]
        }

        if inMemory {
            container.persistentStoreDescriptions.forEach {
                $0.url = URL(fileURLWithPath: "/dev/null")
            }
        }

        // 前回の save() で configuration mismatch (= entity セット変更等で本当に互換不能) が
        // 起きていた場合だけ、無条件で wipe する。
        // 通常のスキーマ変更 (新しい optional 属性追加など) は Core Data の lightweight migration
        // (`shouldMigrateStoreAutomatically + shouldInferMappingModelAutomatically`) に任せる。
        // 起動時の version-hash 比較で先回り wipe すると、互換可能な変更でも一律にユーザーデータ
        // (= 共有や CKShare メタデータ含む) を吹き飛ばしてしまうため行わない。
        if !inMemory, UserDefaults.standard.bool(forKey: Self.storeNeedsResetKey) {
            for description in container.persistentStoreDescriptions {
                if let url = description.url {
                    try? Self.deleteSQLiteFiles(at: url)
                }
            }
            UserDefaults.standard.removeObject(forKey: Self.storeNeedsResetKey)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .expensoStoreReset,
                    object: nil,
                    userInfo: ["message": "前回の保存エラーを検出したためデータベースをリセットしました。"]
                )
            }
        }

        let privateURL = baseDescription.url
        let sharedURL: URL? = container.persistentStoreDescriptions.first(where: { $0.configuration == "Shared" })?.url

        container.loadPersistentStores { [weak self] description, error in
            if let error = error as NSError? {
                #if DEBUG
                print("⚠️ loadPersistentStores failed: \(error)")
                #endif
                // 最終手段: ストアファイルを削除して再ビルドを促す
                if let url = description.url {
                    try? Self.deleteSQLiteFiles(at: url)
                    NotificationCenter.default.post(
                        name: .expensoStoreReset,
                        object: nil,
                        userInfo: ["message": "データベースを再構築しました。アプリを再起動してください。"]
                    )
                }
                return
            }
            guard let self else { return }
            if description.url == privateURL {
                self.privateStore = self.container.persistentStoreCoordinator.persistentStore(for: description.url!)
            } else if let sharedURL, description.url == sharedURL {
                self.sharedStore = self.container.persistentStoreCoordinator.persistentStore(for: description.url!)
            }
        }


        // CloudKit のイベントを監視して initialSyncComplete を立てる。
        // - `.import` 完了: 既存データが降りてきた → 開放 (= 既存ユーザー)
        // - `.setup` 完了 + 8 秒経過: import が来なかった = 空クラウド → 開放 (= 新規ユーザー)
        // 注意: `queue: .main` を指定すると main thread が
        // `persistUpdatedShare` の内部 lock を取って待機している間に
        // observer block も main を取りに行って互いに待つデッドロック
        // (= __ulock_wait) になる。`queue: nil` で投稿スレッド上で同期実行し、
        // @Published 更新だけを async に main へ送る。
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil
            else { return }
            switch event.type {
            case .import:
                self.markInitialSyncComplete()
            case .setup:
                // setup 完了から 8 秒以内に .import が来なければ空クラウド扱いで開放
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                    self?.markInitialSyncComplete()
                }
            default: break
            }
        }

        // iCloud サインイン状態を取得・監視 (シート作成ゲートで参照)。
        // 未サインイン等で利用不可なら初回同期を待つ意味が無いのでゲートも即時開放する。
        refreshAccountStatus()
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshAccountStatus()
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // setQueryGenerationFrom(.current) は付けない。これを付けると viewContext が起動時点の
        // レコード集合に pin され、CloudKit が import した他端末の Expense / Sheet 等が
        // automaticallyMergesChangesFromParent を経ても auto-advance されず、再起動するまで
        // 見えなくなる。pinning 無しでも auto-merge は問題なく機能する。

        // 一度きりの seed/migration はリビジョン番号でガード。次回起動以降は走らせない。
        runOneTimeMigrationsIfNeeded()

        #if DEBUG
        if inMemory {
            seedPreviewData()
        } else if ProcessInfo.processInfo.environment["EXPENSO_SEED"] == "1" {
            seedDevDataIfNeeded()
        }
        #endif
    }

    /// iCloud アカウント状態を取得して `iCloudAccountAvailable` を更新する。
    /// 起動時・`.CKAccountChanged`・前面化時に呼ぶ。
    func refreshAccountStatus() {
        CKContainer(identifier: Self.cloudKitContainerIdentifier).accountStatus { [weak self] status, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // サインイン済みか (作成ゲート用): .noAccount / .restricted のみ false。
                let signedIn = (status != .noAccount && status != .restricted)
                if self.iCloudAccountAvailable != signedIn {
                    self.iCloudAccountAvailable = signedIn
                }
                // .available 以外なら初回同期を待つ意味が無いのでゲート開放 (従来挙動)。
                if status != .available { self.markInitialSyncComplete() }
            }
        }
    }

    /// `initialSyncComplete` を 1 度だけ true にする (= idempotent)。
    /// CloudKit イベント / アカウント未利用 / フォールバックタイマーから呼ばれる。
    private func markInitialSyncComplete() {
        guard !UserDefaults.standard.bool(forKey: Self.initialSyncCompleteKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.initialSyncCompleteKey)
        DispatchQueue.main.async { [weak self] in
            self?.initialSyncComplete = true
        }
    }

    /// 起動時に走る一度きりの seed/migration を、UserDefaults のリビジョン番号でガードする。
    /// データ件数に関わらず O(1) で済むよう、フラグが既に最新ならスキップ。
    private func runOneTimeMigrationsIfNeeded() {
        // `seedDefaultMemberIfNeeded` は count(req) == 0 の高速チェックなので毎回呼んでよい
        seedDefaultMemberIfNeeded()
        // 注意: 以前は起動時 + CloudKit remote change ごとに「sheet == nil の Expense」を
        // 自動削除していたが、これは CloudKit import 中に親シートやリレーションが解決される前の
        // Expense (一時的に sheet == nil) まで消してしまい、その削除が CloudKit に同期されて
        // データが恒久的に消える原因になっていた。特にショートカット等でアプリがバックグラウンド
        // 起動して import が走るタイミングで顕著。孤児 Expense は UI に出ない (常に sheet で
        // 絞って fetch) ので無害なため、自動削除は廃止し、シート削除時の Cascade ルールに任せる。
        // CKShare の zone 移動で複製されたシートを統合
        mergeDuplicateSheets()
        // 同じ参加者の Member プロフィール (名前/色/写真) を最新 ParticipantProfile に揃える
        syncMembersFromParticipantProfiles()

        let stored = UserDefaults.standard.integer(forKey: Self.migrationRevisionKey)
        guard stored < Self.currentMigrationRevision else { return }

        // ここから下は重い fetch を伴うので、リビジョン未達の起動でだけ実行する
        ensureCategoriesForExistingGroups()
        mergeDuplicateMembers()

        UserDefaults.standard.set(Self.currentMigrationRevision, forKey: Self.migrationRevisionKey)
    }

    /// CKShare 作成時の zone 移動などで複製されたシートを検出し、
    /// 子データ (Expense / ExpenseCategory / RecurringRule / ExpenseTemplate /
    /// ParticipantProfile) を keeper 側へ re-link した上で重複側を削除する。
    ///
    /// 判定条件: 同じ `name` + 同じ `createdAt` (秒単位) のシート群を「同一」とみなす。
    /// keeper の優先順位:
    ///   1) CKShare が紐付いているシート (= 共有 zone 上のシートを残す)
    ///   2) それ以外は createdAt 昇順で最古 (= オリジナル想定)
    private func mergeDuplicateSheets() {
        let ctx = container.viewContext
        guard let allSheets = try? ctx.fetch(NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")),
              allSheets.count > 1 else { return }

        let bucket = Dictionary(grouping: allSheets) { (s: ExpenseSheet) -> String in
            let name = (s.name ?? "").trimmingCharacters(in: .whitespaces)
            let ts = s.createdAt.map { Int($0.timeIntervalSince1970) } ?? 0
            return "\(name)#\(ts)"
        }

        var didChange = false
        for (_, sheets) in bucket where sheets.count > 1 {
            // CKShare が紐付いている方を最優先で keeper にする
            let withShare: ExpenseSheet? = sheets.first { s in
                ((try? container.fetchShares(matching: [s.objectID]))?[s.objectID]) != nil
            }
            let keeper: ExpenseSheet = withShare ?? sheets
                .sorted { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
                .first!
            for dup in sheets where dup.objectID != keeper.objectID {
                relinkChildren(from: dup, to: keeper, ctx: ctx)
                ctx.delete(dup)
                didChange = true
                #if DEBUG
                print("⚠️ mergeDuplicateSheets: deleted duplicate \(dup.objectID) → keeper \(keeper.objectID) (name=\(keeper.name ?? "?"))")
                #endif
            }
        }
        if didChange, ctx.hasChanges { try? ctx.save() }
    }

    /// 重複シート (`dup`) の子データを keeper シートへ移動する。
    /// 同名の ExpenseCategory や同 recordName の ParticipantProfile が keeper にも
    /// あれば重複扱いで `dup` 側を削除 (sheet relation だけ書き換える代わりに統合)。
    private func relinkChildren(from dup: ExpenseSheet, to keeper: ExpenseSheet, ctx: NSManagedObjectContext) {
        // Expense
        if let expenses = dup.expenses as? Set<Expense> {
            for e in expenses { e.sheet = keeper }
        }
        // RecurringRule
        if let rules = dup.recurringRules as? Set<RecurringRule> {
            for r in rules { r.sheet = keeper }
        }
        // ExpenseTemplate
        if let templates = dup.templates as? Set<ExpenseTemplate> {
            for t in templates { t.sheet = keeper }
        }
        // ExpenseCategory: 同名は keeper の category を優先、重複は削除
        if let dupCats = dup.categories as? Set<ExpenseCategory> {
            let keeperCatNames = Set(((keeper.categories as? Set<ExpenseCategory>) ?? []).compactMap { $0.name })
            for c in dupCats {
                if let name = c.name, keeperCatNames.contains(name) {
                    ctx.delete(c)
                } else {
                    c.sheet = keeper
                }
            }
        }
        // ParticipantProfile: 同 recordName は keeper のものを優先、重複は削除
        if let dupPPs = dup.participantProfiles as? Set<ParticipantProfile> {
            let keeperRNs = Set(((keeper.participantProfiles as? Set<ParticipantProfile>) ?? [])
                .compactMap { ($0.recordName ?? "").isEmpty ? nil : $0.recordName })
            for p in dupPPs {
                if let rn = p.recordName, !rn.isEmpty, keeperRNs.contains(rn) {
                    ctx.delete(p)
                } else {
                    p.sheet = keeper
                }
            }
        }
    }

    /// 既存 Member の denormalized プロフィール (= name / colorHex / photoData) を、
    /// 同じ Apple ID (recordName 一致) を持つ最新の ParticipantProfile に揃える。
    ///
    /// 注意: かつてあった「Member.recordName が空 → 同名 PP から借りる」逆引き同期は
    /// 削除した。汎用名 ("自分" / "メンバー" 等) のとき別人の PP を誤って拾い、self Member に
    /// 他人の recordName を書き込む不具合を引き起こすため。recordName は picker か
    /// migration が canonical 経由で書き込む。
    ///
    /// PP 機能は現在無効化されているので関数全体を早期 return。残骸の Member 同期で
    /// 不整合が出ないようにする。再度有効化する場合は BuildInfo.profileFeatureEnabled を
    /// 参照する gate を入れること。
    /// 起動時に毎回走らせるが、O(M + P) で軽量。
    private func syncMembersFromParticipantProfiles() {
        return // PP feature disabled; rely on canonical IDs from picker / migration.
        // swiftlint:disable:next unreachable_code
        let ctx = container.viewContext
        let ppReq = NSFetchRequest<ParticipantProfile>(entityName: "ParticipantProfile")
        guard let allPPs = try? ctx.fetch(ppReq), !allPPs.isEmpty else { return }
        let memberReq = NSFetchRequest<Member>(entityName: "Member")
        guard let allMembers = try? ctx.fetch(memberReq), !allMembers.isEmpty else { return }

        // recordName ごとに最新 (updatedAt 降順) の PP を 1 つ選ぶ
        var latestByRecordName: [String: ParticipantProfile] = [:]
        for pp in allPPs {
            guard let rn = pp.recordName, !rn.isEmpty else { continue }
            let cur = latestByRecordName[rn]
            let curAt = cur?.updatedAt ?? .distantPast
            let ppAt = pp.updatedAt ?? .distantPast
            if cur == nil || ppAt > curAt {
                latestByRecordName[rn] = pp
            }
        }

        var didChange = false
        for member in allMembers {
            // recordName 一致 → 最新 PP の displayName / colorHex / photoData を Member に同期
            guard let rn = member.recordName, !rn.isEmpty,
                  let pp = latestByRecordName[rn] else { continue }
            if let dn = pp.displayName, !dn.isEmpty, member.name != dn {
                member.name = dn
                didChange = true
            }
            if let cc = pp.colorHex, !cc.isEmpty, member.colorHex != cc {
                member.colorHex = cc
                didChange = true
            }
            if member.photoData != pp.photoData {
                member.photoData = pp.photoData
                didChange = true
            }
            if didChange { member.updatedAt = .now }
        }
        if didChange, ctx.hasChanges { try? ctx.save() }
    }

    /// アプリ初回起動時にメンバーが 1 人もいなければ「自分」を作る。
    /// メンバーはアカウント単位 (グローバル) のため、シート作成時には作らない。
    private func seedDefaultMemberIfNeeded() {
        let ctx = container.viewContext
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.fetchLimit = 1
        if let count = try? ctx.count(for: req), count > 0 { return }

        let displayName = UserDefaults.standard.string(forKey: "displayName") ?? ""
        let m = Member(context: ctx)
        m.id = UUID()
        m.name = displayName.isEmpty ? "自分" : displayName
        m.colorHex = "#5B8DEF"
        m.sortOrder = 0
        m.createdAt = .now
        try? ctx.save()
    }

    /// 旧スキーマではメンバーがシートごとに重複していた。同名のメンバーを 1 つに統合する。
    /// (Expense.payer リレーションは廃止され、paidBy 文字列のみで紐付くため再リンクは不要)
    private func mergeDuplicateMembers() {
        let ctx = container.viewContext
        guard let all = try? ctx.fetch(NSFetchRequest<Member>(entityName: "Member")) else { return }
        let byName = Dictionary(grouping: all) { ($0.name ?? "").trimmingCharacters(in: .whitespaces) }
        var didChange = false
        for (name, members) in byName where members.count > 1 && !name.isEmpty {
            let sorted = members.sorted { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
            for dup in sorted.dropFirst() {
                ctx.delete(dup)
                didChange = true
            }
        }
        if didChange { try? ctx.save() }
    }

    /// シート専用のデフォルトカテゴリ (支出 + 収入) を作成する。
    /// 新規シート作成時、または既存シートにカテゴリが無い場合の補填として呼ぶ。
    static func seedDefaultCategories(for sheet: ExpenseSheet, in ctx: NSManagedObjectContext) {
        for (i, seed) in CategoryDefaults.seeds.enumerated() {
            let cat = ExpenseCategory(context: ctx)
            cat.id = UUID()
            cat.name = seed.name
            cat.colorHex = seed.colorHex
            cat.symbol = seed.symbol
            cat.kindRaw = seed.kind.rawValue
            cat.sortOrder = Int32(i)
            cat.isBuiltIn = true
            cat.createdAt = .now
            cat.sheet = sheet
        }
    }

    /// 既存シートに収入カテゴリが無ければ補填する (旧データ移行用)。
    static func ensureIncomeSeedCategories(for sheet: ExpenseSheet, in ctx: NSManagedObjectContext) {
        let existing = (sheet.categories as? Set<ExpenseCategory>) ?? []
        let hasIncome = existing.contains(where: { ($0.kindRaw ?? "") == "income" })
        if hasIncome { return }
        let baseSort = (existing.map(\.sortOrder).max() ?? -1) + 1
        for (i, seed) in CategoryDefaults.incomeSeeds.enumerated() {
            let cat = ExpenseCategory(context: ctx)
            cat.id = UUID()
            cat.name = seed.name
            cat.colorHex = seed.colorHex
            cat.symbol = seed.symbol
            cat.kindRaw = seed.kind.rawValue
            cat.sortOrder = Int32(i) + baseSort
            cat.isBuiltIn = true
            cat.createdAt = .now
            cat.sheet = sheet
        }
    }

    /// 既存シート(カテゴリ未設定)にデフォルトを補填し、シートに属さない孤児カテゴリを削除し、
    /// 旧スキーマで保存された Expense を同じシート内のカテゴリ名一致で再リンクする。
    private func ensureCategoriesForExistingGroups() {
        let ctx = container.viewContext
        guard let sheets = try? ctx.fetch(NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")) else { return }

        var didChange = false

        for sheet in sheets {
            let existing = (sheet.categories as? Set<ExpenseCategory>) ?? []
            if existing.isEmpty {
                Self.seedDefaultCategories(for: sheet, in: ctx)
                didChange = true
            } else {
                // 旧データに収入カテゴリが無ければ補填
                let beforeCount = existing.count
                Self.ensureIncomeSeedCategories(for: sheet, in: ctx)
                if (sheet.categories as? Set<ExpenseCategory>)?.count != beforeCount { didChange = true }
            }

            // シート内のカテゴリ名一致で Expense を再リンク
            let groupCats = ((sheet.categories as? Set<ExpenseCategory>) ?? []).reduce(into: [String: ExpenseCategory]()) { dict, cat in
                if let n = cat.name { dict[n] = cat }
            }
            let expReq = NSFetchRequest<Expense>(entityName: "Expense")
            expReq.predicate = NSPredicate(format: "sheet == %@ AND category == nil AND categoryRaw != nil AND categoryRaw != ''", sheet)
            if let unlinked = try? ctx.fetch(expReq), !unlinked.isEmpty {
                for exp in unlinked {
                    if let raw = exp.categoryRaw, let match = groupCats[raw] {
                        exp.category = match
                        didChange = true
                    }
                }
            }
        }

        // group=nil の孤児カテゴリ (旧グローバルシード) を削除
        let orphanReq = NSFetchRequest<ExpenseCategory>(entityName: "ExpenseCategory")
        orphanReq.predicate = NSPredicate(format: "sheet == nil")
        if let orphans = try? ctx.fetch(orphanReq), !orphans.isEmpty {
            for orphan in orphans { ctx.delete(orphan) }
            didChange = true
        }

        if didChange { try? ctx.save() }
    }

    /// 既存の永続ストアが現在の `NSManagedObjectModel` の configuration と互換かをチェックし、
    /// 互換でなければ SQLite ファイルごと破棄する。`loadPersistentStores` 前に呼ぶ前提。
    private static func resetIncompatibleStoresIfNeeded(model: NSManagedObjectModel,
                                                        descriptions: [NSPersistentStoreDescription]) {
        var didReset = false
        for description in descriptions {
            guard let url = description.url else { continue }
            // ファイルがまだ無ければスキップ (新規作成時)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            do {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: NSSQLiteStoreType,
                    at: url,
                    options: nil
                )
                let compatible = model.isConfiguration(
                    withName: description.configuration,
                    compatibleWithStoreMetadata: metadata
                )
                if !compatible {
                    #if DEBUG
                    print("⚠️ Store at \(url.lastPathComponent) is incompatible with configuration \"\(description.configuration ?? "nil")\". Destroying for fresh start.")
                    #endif
                    try Self.deleteSQLiteFiles(at: url)
                    didReset = true
                }
            } catch {
                #if DEBUG
                print("⚠️ Failed to read metadata for \(url.lastPathComponent): \(error). Removing.")
                #endif
                try? Self.deleteSQLiteFiles(at: url)
                didReset = true
            }
        }
        if didReset {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .expensoStoreReset,
                    object: nil,
                    userInfo: ["message": "データベースの構造変更に伴い古いデータをリセットしました。"]
                )
            }
        }
    }

    func save() {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return }
        do {
            try ctx.save()
        } catch {
            let nsError = error as NSError
            #if DEBUG
            print("⚠️ Core Data save failed: \(nsError)")
            if let detail = nsError.userInfo[NSDetailedErrorsKey] as? [NSError] {
                for e in detail { print("  - \(e)") }
            }
            #endif
            ctx.rollback()

            // configuration mismatch を検知したら次回起動時にストアを wipe するフラグを立てる
            if Self.isConfigurationMismatch(error: nsError) {
                UserDefaults.standard.set(true, forKey: Self.storeNeedsResetKey)
                NotificationCenter.default.post(
                    name: .expensoSaveFailed,
                    object: nil,
                    userInfo: ["message": "データベース構造の不整合を検出しました。アプリを再起動するとデータをリセットして復旧します。"]
                )
            } else {
                NotificationCenter.default.post(
                    name: .expensoSaveFailed,
                    object: nil,
                    userInfo: ["message": "保存に失敗しました: \(error.localizedDescription)"]
                )
            }
        }
    }

    /// "The model configuration used to open the store is incompatible..." 系のエラーかを判定。
    /// NSCocoaErrorDomain の version-hash 不一致系コード、または同等のメッセージを含むエラーを拾う。
    private static func isConfigurationMismatch(error: NSError) -> Bool {
        let mismatchCodes: Set<Int> = [
            NSPersistentStoreIncompatibleVersionHashError, // 134100
            NSPersistentStoreInvalidTypeError,             // 134000
            NSMigrationMissingSourceModelError,            // 134110
            NSMigrationMissingMappingModelError            // 134120
        ]
        if error.domain == NSCocoaErrorDomain && mismatchCodes.contains(error.code) { return true }
        if error.localizedDescription.contains("model configuration") { return true }
        if let detail = error.userInfo[NSDetailedErrorsKey] as? [NSError] {
            return detail.contains(where: { Self.isConfigurationMismatch(error: $0) })
        }
        return false
    }

    /// 全データを削除する。Private ストアの全エンティティを削除し、Core Data 経由で
    /// CloudKit (private DB) にも反映される。共有シートの参加者ローカルでは削除できない
    /// 場合があるため、保存失敗時にエラーをユーザーに通知する。
    /// 全データを完全リセットする。
    /// 1. CKShare を全解除 (= 自分が作成した共有を停止)
    /// 2. Core Data の全エンティティを削除 (Expense, ExpenseCategory, ExpenseSheet,
    ///    Member, ParticipantProfile, RecurringRule, ExpenseTemplate)
    /// 3. UserProfileStore (displayName / photoData / colorHex / userRecordName /
    ///    selfMemberID / profileUpdatedAt) をリセット
    /// 4. Budgety 関連の UserDefaults キー (シートロック・migration flag・最後に開いたシート等) を削除
    @MainActor
    func eraseAllData() async {
        // 1) CKShare を解除 (= 共有を停止)
        #if !os(watchOS)
        _ = await ShareCoordinator.shared.revokeAllOwnedShares()
        #endif

        // 2) Core Data 全エンティティ削除
        let ctx = container.viewContext
        let entities = [
            "Expense", "ExpenseCategory", "ExpenseSheet",
            "Member", "ParticipantProfile", "RecurringRule", "ExpenseTemplate"
        ]
        for entityName in entities {
            let req = NSFetchRequest<NSManagedObject>(entityName: entityName)
            if let items = try? ctx.fetch(req) {
                for item in items { ctx.delete(item) }
            }
        }
        do {
            try ctx.save()
        } catch {
            #if DEBUG
            print("⚠️ eraseAllData failed: \(error)")
            #endif
            ctx.rollback()
            NotificationCenter.default.post(
                name: .expensoSaveFailed,
                object: nil,
                userInfo: ["message": "削除に失敗しました: \(error.localizedDescription)"]
            )
            return
        }

        // 3) UserProfileStore をリセット
        UserProfileStore.shared.resetAll()

        // 4) Budgety 関連 UserDefaults をクリア
        let ud = UserDefaults.standard
        let prefixes = [
            "BudgetySheetLock.",       // legacy
            "BudgetySheetLockBio.",
            "userProfile."
        ]
        let exactKeys = [
            "displayName",
            "lastOpenedSheetURI",
            "ExpensoInitialSyncComplete",
            "expensoMigrationRevision",
            "expensoStoreNeedsReset"
        ]
        for (key, _) in ud.dictionaryRepresentation() {
            if exactKeys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) {
                ud.removeObject(forKey: key)
            }
        }

        NotificationCenter.default.post(
            name: .expensoStoreReset,
            object: nil,
            userInfo: ["message": "すべてのデータを削除しました。アプリを再起動してください。"]
        )
    }

    func cloudKitContainer() -> CKContainer {
        CKContainer(identifier: Self.cloudKitContainerIdentifier)
    }

    #if DEBUG
    /// CloudKit Development スキーマをモデル定義から一括生成する (Production デプロイ準備用)。
    ///
    /// NSPersistentCloudKitContainer は通常レコード同期時にフィールドを遅延生成するため、
    /// まだ一度も同期されていない新規属性 (例: `settledBeneficiaryProfileIDs`) は Development
    /// スキーマに現れず、CloudKit Console の Deploy Schema Changes にも出てこない。
    /// このメソッドを一度実行すると、モデルの全 Record Type / フィールド / インデックスが
    /// Development に作られ、その後 Console から Production へデプロイできるようになる。
    ///
    /// 実行方法: iCloud サインイン済みの DEBUG ビルドで環境変数 `EXPENSO_INIT_CK_SCHEMA=1`
    /// を付けて一度だけ起動する。スキーマ生成にはネットワークと数十秒かかることがある。
    /// 注意: DEBUG 限定。Production ビルドには絶対に含めない。
    func initializeCloudKitSchemaForDeploy() {
        do {
            try container.initializeCloudKitSchema(options: [])
            print("✅ initializeCloudKitSchema: Development スキーマを生成しました")
        } catch {
            print("⚠️ initializeCloudKitSchema 失敗: \(error)")
        }
    }
    #endif

    /// バックグラウンド context で書き込みを行うヘルパー。クロージャ内では渡されたコンテキスト上で
    /// Core Data オブジェクトを生成・操作し、終了時に save する。
    /// `viewContext.automaticallyMergesChangesFromParent` が立っているため、保存後に viewContext に
    /// 反映される。NSManagedObject はコンテキストを跨げないので、必要なオブジェクトは objectID を渡し
    /// クロージャ内で `ctx.object(with:)` で再取得すること。
    /// 戻り値は完了 / 失敗のいずれかを返す。失敗時は通常の save 経路と同様にエラー通知を投げる。
    @discardableResult
    func performWrite(_ block: @escaping (NSManagedObjectContext) throws -> Void) async -> Bool {
        let bg = container.newBackgroundContext()
        bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return await withCheckedContinuation { continuation in
            bg.perform {
                do {
                    try block(bg)
                    if bg.hasChanges {
                        try bg.save()
                    }
                    continuation.resume(returning: true)
                } catch {
                    let nsError = error as NSError
                    #if DEBUG
                    print("⚠️ Background write failed: \(nsError)")
                    #endif
                    bg.rollback()
                    if Self.isConfigurationMismatch(error: nsError) {
                        UserDefaults.standard.set(true, forKey: Self.storeNeedsResetKey)
                    }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .expensoSaveFailed,
                            object: nil,
                            userInfo: ["message": "保存に失敗しました: \(error.localizedDescription)"]
                        )
                    }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    #if DEBUG
    private func seedPreviewData() {
        let ctx = container.viewContext
        let sheet = ExpenseSheet(context: ctx)
        sheet.name = "サンプル家計"
        sheet.colorHex = "#5B8DEF"
        sheet.createdAt = .now
        sheet.note = ""
        Self.seedDefaultCategories(for: sheet, in: ctx)

        let foodCat = lookupCategory(named: "食費", sheet: sheet, in: ctx)

        for (i, title) in ["スーパー", "電車", "ランチ"].enumerated() {
            let e = Expense(context: ctx)
            e.title = title
            e.amount = NSDecimalNumber(value: (i + 1) * 800)
            e.categoryRaw = "食費"
            e.category = foodCat
            e.date = Calendar.current.date(byAdding: .day, value: -i, to: .now)
            e.paidBy = "自分"
            e.note = ""
            e.createdAt = .now
            e.sheet = sheet
        }
        try? ctx.save()
    }

    static var preview: PersistenceController = PersistenceController(inMemory: true)

    private func seedDevDataIfNeeded() {
        let ctx = container.viewContext
        let request = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        request.fetchLimit = 1
        if let count = try? ctx.count(for: request), count > 0 { return }

        let family = ExpenseSheet(context: ctx)
        family.name = "家族の家計"
        family.colorHex = "#5B8DEF"
        family.note = "毎月の食費・光熱費"
        family.createdAt = .now
        Self.seedDefaultCategories(for: family, in: ctx)
        // Member はアカウント単位 (グローバル) なので両シートで共通に作る
        _ = makeMember(name: "自分", color: "#5B8DEF", sort: 0, ctx: ctx)
        _ = makeMember(name: "パートナー", color: "#FF2D55", sort: 1, ctx: ctx)

        let trip = ExpenseSheet(context: ctx)
        trip.name = "京都旅行"
        trip.colorHex = "#34C759"
        trip.createdAt = Calendar.current.date(byAdding: .day, value: -3, to: .now)
        Self.seedDefaultCategories(for: trip, in: ctx)

        let samples: [(String, Decimal, String, Int, String, ExpenseSheet, String)] = [
            ("スーパー", 4280, "食費", 0, "自分", family, "業務スーパーで野菜まとめ買い"),
            ("電車代", 580, "交通", 1, "自分", family, ""),
            ("カフェ", 920, "食費", 2, "パートナー", family, "スタバで打ち合わせ"),
            ("光熱費", 12500, "光熱費", 5, "自分", family, ""),
            ("ホテル", 18900, "旅行", 0, "自分", trip, "1泊2食付き"),
            ("ランチ", 2400, "食費", 1, "自分", trip, ""),
            ("お土産", 3600, "買い物", 1, "パートナー", trip, "京都の和菓子"),
            ("先月のスーパー", 8500, "食費", 35, "自分", family, ""),
            ("先月の電車", 1200, "交通", 36, "自分", family, ""),
            ("先月の光熱費", 11800, "光熱費", 40, "自分", family, "")
        ]

        for (title, amount, catName, daysAgo, paidBy, sheet, note) in samples {
            let e = Expense(context: ctx)
            e.title = title
            e.amount = NSDecimalNumber(decimal: amount)
            e.categoryRaw = catName
            e.category = lookupCategory(named: catName, sheet: sheet, in: ctx)
            e.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)
            e.paidBy = paidBy
            e.note = note
            e.createdAt = .now
            e.sheet = sheet
        }
        try? ctx.save()
    }

    private func makeMember(name: String, color: String, sort: Int32, ctx: NSManagedObjectContext) -> Member {
        let m = Member(context: ctx)
        m.id = UUID()
        m.name = name
        m.colorHex = color
        m.sortOrder = sort
        m.createdAt = .now
        return m
    }
    #endif

    fileprivate func lookupCategory(named name: String, sheet: ExpenseSheet, in ctx: NSManagedObjectContext) -> ExpenseCategory? {
        let req = NSFetchRequest<ExpenseCategory>(entityName: "ExpenseCategory")
        req.predicate = NSPredicate(format: "name == %@ AND sheet == %@", name, sheet)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    /// SQLite ストア本体と WAL/SHM/journal、Core Data + CloudKit のサポートディレクトリを
    /// 一括削除する。`NSPersistentStoreCoordinator.destroyPersistentStore` は iOS 26 SDK で
    /// インスタンスメソッド限定になったため、自前で削除する。
    private static func deleteSQLiteFiles(at url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent

        let candidates: [URL] = [
            url,
            parent.appendingPathComponent(fileName + "-wal"),
            parent.appendingPathComponent(fileName + "-shm"),
            parent.appendingPathComponent(fileName + "-journal"),
            // Core Data + CloudKit が作る変更履歴等のサポートディレクトリ
            parent.appendingPathComponent(".\(stem)_SUPPORT", isDirectory: true),
            parent.appendingPathComponent("\(stem)_SUPPORT", isDirectory: true)
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            try fm.removeItem(at: candidate)
        }
    }
}

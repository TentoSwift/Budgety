//
//  Expense+Extensions.swift
//  Expenso
//

import Foundation
import CoreData
import SwiftUI
import CloudKit

extension Expense {
    var displayTitle: String { title ?? "" }

    /// 支払者の表示名。`payerProfileID` (canonical) から動的に解決する。
    /// 解決順 (memberDisplayInfo と一致させる):
    /// 1. 自分 → UserProfileStore.resolvedDisplayName
    /// 2. **PublicProfileSync の cache (= Public DB カスタム名)** ← 最優先
    /// 3. CKShare 参加者 → iCloud nameComponents (都度取得)
    /// 4. ParticipantProfile.displayName (= フォールバック)
    /// 5. ローカル Member.displayName
    /// 6. 保存時の `paidBy` 文字列 (= 旧データ用 fallback)
    @MainActor
    var displayPaidBy: String {
        if let n = resolvedSelfDisplayName(), !n.isEmpty { return n }
        if let n = resolvedPublicProfileName(), !n.isEmpty { return n }
        if let n = resolvedSharedParticipantName(), !n.isEmpty { return n }
        if let n = resolvedParticipantProfile?.displayName, !n.isEmpty { return n }
        if let n = resolvedPayer?.displayName, !n.isEmpty { return n }
        return paidBy ?? ""
    }
    @MainActor
    var payerTint: Color {
        if let hex = resolvedParticipantProfile?.displayColorHex, !hex.isEmpty,
           let c = Color(hex: hex) {
            return c
        }
        if isPayerSelf {
            return UserProfileStore.shared.bgColor
        }
        return resolvedPayer?.tint ?? .secondary
    }
    @MainActor
    var payerPhotoData: Data? {
        if let pp = resolvedParticipantProfile?.photoData { return pp }
        if isPayerSelf { return UserProfileStore.shared.photoData }
        // Public DB cache から他参加者の photo を取得
        if let pid = payerProfileID, !pid.isEmpty,
           let cached = PublicProfileSync.shared.cachedProfile(for: pid),
           let photo = cached.photoData {
            return photo
        }
        return resolvedPayer?.photoData
    }

    /// Public DB に登録された他参加者のカスタム表示名 (= ProfileEditView で設定したもの)。
    @MainActor
    private func resolvedPublicProfileName() -> String? {
        guard let pid = payerProfileID, !pid.isEmpty else { return nil }
        // 自分は resolvedSelfDisplayName で処理済みなのでスキップ
        if isPayerSelf { return nil }
        guard let cached = PublicProfileSync.shared.profileOrPrefetch(for: pid),
              !cached.displayName.isEmpty else { return nil }
        return cached.displayName
    }

    /// `payerProfileID` が「自分」を指しているか。
    @MainActor
    var isPayerSelf: Bool {
        guard let pid = payerProfileID, !pid.isEmpty else { return false }
        let share: CKShare? = sheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
        return UserProfileStore.shared.canonicalSelfIDs(forShare: share).contains(pid)
    }

    /// payerProfileID が自分なら UserProfileStore の displayName を返す。
    @MainActor
    private func resolvedSelfDisplayName() -> String? {
        guard isPayerSelf else { return nil }
        return UserProfileStore.shared.resolvedDisplayName
    }

    /// payerProfileID が CKShare の参加者 (オーナー含む) なら iCloud nameComponents を返す。
    /// URN マッチを優先、email/phone ベース canonical (旧データ) もフォールバックで照合。
    @MainActor
    func resolvedSharedParticipantName(includingEmail: Bool = true) -> String? {
        guard let pid = payerProfileID, !pid.isEmpty,
              let sheet = sheet,
              let share = ShareCoordinator.shared.existingShare(for: sheet) else { return nil }
        // オーナー: URN 一致
        let ownerRN = share.owner.userIdentity.userRecordID?.recordName ?? ""
        if !UserProfileStore.isSelfPlaceholderRecordName(ownerRN), ownerRN == pid {
            return nameFromIdentity(share.owner.userIdentity, includingEmail: includingEmail)
        }
        // 参加者: URN 一致を優先、無ければ budgetyCanonicalID (email 等) もチェック
        for p in share.participants {
            let rn = p.userIdentity.userRecordID?.recordName ?? ""
            if !UserProfileStore.isSelfPlaceholderRecordName(rn), rn == pid {
                return nameFromIdentity(p.userIdentity, includingEmail: includingEmail)
            }
            if let cid = p.budgetyCanonicalID, cid == pid {
                return nameFromIdentity(p.userIdentity, includingEmail: includingEmail)
            }
        }
        return nil
    }

    @MainActor
    private func nameFromIdentity(_ identity: CKUserIdentity, includingEmail: Bool) -> String? {
        if let nc = identity.nameComponents {
            let formatted = PersonNameComponentsFormatter().string(from: nc)
            if !formatted.isEmpty { return formatted }
        }
        if includingEmail, let email = identity.lookupInfo?.emailAddress, !email.isEmpty {
            return email
        }
        return nil
    }

    /// 支払者の Member を引く。Member は Private ストアにしか存在しないが、
    /// id / recordName / 名前のいずれかで見つかれば Shared ストアの Expense でも返す
    /// (= 自分が払った共有支出や、他端末で作られた支出を編集するときに支払者が解決できるように)。
    @MainActor
    var resolvedPayer: Member? {
        // 支払者の identity は payerProfileID で判定する。共有シートの場合は
        // canonicalSelfIDs (シート用 canonical + 旧 userRecordName) と照合し、
        // 旧 ID が残っていても「自分」として解決できるようにする。
        let pc = PersistenceController.shared
        let ctx = managedObjectContext ?? pc.container.viewContext
        guard let pid = payerProfileID, !pid.isEmpty else { return nil }

        // 1) 自分: payerProfileID が canonical self ID 群のいずれかと一致 → selfMember
        let share: CKShare? = sheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
        let selfIDs = UserProfileStore.shared.canonicalSelfIDs(forShare: share)
        if selfIDs.contains(pid),
           let selfID = UserProfileStore.shared.selfMemberID {
            let req = NSFetchRequest<Member>(entityName: "Member")
            req.predicate = NSPredicate(format: "id == %@", selfID as CVarArg)
            req.fetchLimit = 1
            if let m = (try? ctx.fetch(req))?.first { return m }
        }
        // 2) 他人: Member.recordName == payerProfileID
        let req = NSFetchRequest<Member>(entityName: "Member")
        req.predicate = NSPredicate(format: "recordName == %@", pid)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    /// `generatedFromRuleID` から元の RecurringRule を引く (定期から生成された支出のみ非 nil)。
    var relatedRule: RecurringRule? {
        guard let id = generatedFromRuleID else { return nil }
        let ctx = managedObjectContext ?? PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<RecurringRule>(entityName: "RecurringRule")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }

    /// 同シート配下の ParticipantProfile を引く。recordName 一致 → displayName 一致の順。
    var resolvedParticipantProfile: ParticipantProfile? {
        guard let sheet = sheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        // 1) recordName 一致
        if let pid = payerProfileID, !pid.isEmpty,
           let pp = profiles.first(where: { $0.recordName == pid }) {
            return pp
        }
        // 2) displayName 一致 (旧データ移行用)。同名が複数いると Set の列挙順次第で
        //    別人を拾い、背景色がチカチカ入れ替わるため、recordName でソートして決定的に選ぶ。
        //    バーチャルメンバーは除外する: payerProfileID を持たない旧支出に対し、後から
        //    同名のバーチャルメンバーを追加しても (名前一致で) その支払者表示を乗っ取らない
        //    ようにする。バーチャルが支払者の支出は payerProfileID で 1) により解決される。
        guard let name = paidBy, !name.isEmpty else { return nil }
        return profiles
            .filter { $0.displayName == name && !UserProfileStore.isVirtualRecordName($0.recordName ?? "") }
            .sorted { ($0.recordName ?? "") < ($1.recordName ?? "") }
            .first
    }

    var amountDecimal: Decimal {
        get { (amount ?? 0) as Decimal }
        set { amount = NSDecimalNumber(decimal: newValue) }
    }

    /// FX 換算スナップショット (= 作成 / 編集時に解決された target 通貨建ての金額)。
    /// 設定されていれば SettlementCalculator は当時の値をそのまま使い、為替変動
    /// による残高ドリフトを防ぐ。SettlementRecord の FX スナップショットと同じ役割。
    var fxConvertedAmountDecimal: Decimal? {
        get {
            guard let n = fxConvertedAmount else { return nil }
            return n as Decimal
        }
        set {
            if let v = newValue { fxConvertedAmount = NSDecimalNumber(decimal: v) }
            else { fxConvertedAmount = nil }
        }
    }

    /// FX スナップショットが有効かつ現在の target と一致する時のみ返す。
    /// 一致しない (シート既定通貨が変更された) 時は nil → 現行 FX で再計算。
    func snapshotConvertedAmount(forTarget targetCode: String) -> Decimal? {
        guard let snap = fxConvertedAmountDecimal,
              let snapTarget = fxTargetCurrency,
              snapTarget == targetCode else { return nil }
        return snap
    }

    /// 現在の `amount` / `currencyCode` / `sheet.resolvedDefaultCurrencyCode` から
    /// FX スナップショットを取り直して保存する。Expense 作成・編集時に呼ぶ。
    /// レートが取得できなければスナップショットは nil にし、Calculator は
    /// 現行 FX にフォールバックする (= 旧挙動)。
    @MainActor
    func captureFXSnapshot() {
        guard let sheet else { return }
        let target = sheet.resolvedDefaultCurrencyCode
        if let converted = FXRatesService.shared.convert(
            amountDecimal, from: resolvedCurrencyCode, to: target
        ) {
            fxConvertedAmountDecimal = converted
            fxTargetCurrency = target
        } else {
            fxConvertedAmountDecimal = nil
            fxTargetCurrency = nil
        }
    }

    /// 受益者の profileID リスト (誰の負担として扱うか)。
    /// 内部表現: `beneficiaryProfileIDs` カンマ区切り文字列。
    /// 空文字 = 割り勘オフ (支払者単独負担)。SettlementCalculator では残高変動なし・
    /// カテゴリ集計のみ計上。「全メンバー均等割り」ではない点に注意。
    var beneficiaryIDList: [String] {
        get {
            (beneficiaryProfileIDs ?? "")
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            // 重複と空文字を除去してから join
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            beneficiaryProfileIDs = cleaned.joined(separator: ",")
        }
    }

    /// 精算計算で使う実効受益者リスト。
    /// 受益者が明示的に設定されていればそれをそのまま返す。
    /// 空 (= 割り勘オフ / solo シートで作成) の場合は空のまま返す。
    /// SettlementCalculator では「空 = 支払者単独負担」として扱われ、
    /// 精算は発生しないがカテゴリ集計には含められる。
    @MainActor
    func resolvedBeneficiaryIDs() -> [String] {
        beneficiaryIDList
    }

    /// 精算済みにした受益者の profileID リスト (支出ごと・相手ごとの精算)。
    /// `beneficiaryProfileIDs` のサブセット。内部表現は CSV。
    var settledBeneficiaryIDList: [String] {
        get {
            (settledBeneficiaryProfileIDs ?? "")
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            settledBeneficiaryProfileIDs = cleaned.joined(separator: ",")
        }
    }

    /// 指定受益者がこの支出で精算済みか。
    func isBeneficiarySettled(_ profileID: String) -> Bool {
        settledBeneficiaryIDList.contains(profileID)
    }

    /// 指定受益者の精算済みフラグを切り替える。
    func setBeneficiarySettled(_ settled: Bool, for profileID: String) {
        var list = settledBeneficiaryIDList
        if settled {
            if !list.contains(profileID) { list.append(profileID) }
        } else {
            list.removeAll { $0 == profileID }
        }
        settledBeneficiaryIDList = list
    }

    /// 現在の受益者に含まれない精算済みフラグを除去する。
    /// 割り勘を編集して受益者から外した人の精算済みマークが残ると、
    /// 再追加時に勝手に「精算済み」表示になるため、保存時に掃除する。
    func pruneSettledBeneficiaries() {
        let current = Set(beneficiaryIDList)
        let pruned = settledBeneficiaryIDList.filter { current.contains($0) }
        if pruned.count != settledBeneficiaryIDList.count {
            settledBeneficiaryIDList = pruned
        }
    }

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRaw ?? "") ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// 通貨コード (空なら親シートの既定 → JPY)
    var resolvedCurrencyCode: String {
        if let c = currencyCode, !c.isEmpty { return c }
        if let s = sheet?.resolvedDefaultCurrencyCode, !s.isEmpty { return s }
        return CurrencyCatalog.defaultCode
    }

    /// 通貨記号付きの金額表示 (符号は kind に応じて変える呼び出し元で扱う)
    var formattedAmount: String {
        CurrencyCatalog.format(amountDecimal, code: resolvedCurrencyCode)
    }

    /// 符号付き表示 (収入は正、支出は負として表現)
    var formattedSignedAmount: String {
        let sign = kind == .expense ? "-" : "+"
        return sign + formattedAmount
    }

    /// `category` リレーションが nil でも、`categoryRaw` (名前) とシートのカテゴリ集合から
    /// 一致するものを引いて返すフォールバック付きアクセサ。
    /// Shared/Private のクロスストアで linkage が外れたケースでも、表示が正しく出るようにする。
    var resolvedCategory: ExpenseCategory? {
        if let c = category { return c }
        guard let raw = categoryRaw, !raw.isEmpty,
              let sheet = sheet,
              let cats = sheet.categories as? Set<ExpenseCategory> else { return nil }
        return cats.first(where: { $0.name == raw })
    }

    var categoryDisplayName: String {
        resolvedCategory?.displayName ?? (categoryRaw?.isEmpty == false ? categoryRaw! : String(localized: "カテゴリなし"))
    }

    var categoryTint: Color {
        resolvedCategory?.tint ?? .gray
    }

    var categorySymbol: String {
        resolvedCategory?.displaySymbol ?? "tag.slash"
    }
}

/// The same typed or spoken term matches titles and the category currently shown on a transaction.
struct TransactionSearchTerm {
    private let key: String
    private var alternativeKeys: [String] = []
    private var merchantGroup: String?
    var isEmpty: Bool { key.isEmpty }

    nonisolated enum FoodGroup: String, CaseIterable {
        case japanese = "和食", western = "洋食", chinese = "中華料理", italian = "イタリアン"
        case french = "フレンチ", korean = "韓国料理", indian = "インド料理"
        case hamburger = "ハンバーガー", diningOut = "外食"

        var includedGroups: Set<Self> {
            switch self {
            case .diningOut: Set(Self.allCases)
            case .western: [.western, .italian, .french, .hamburger]
            default: [self]
            }
        }

        var labels: [String] {
            switch self {
            case .japanese: ["和食", "日本料理", "日本食", "わしょく"]
            case .western: ["洋食", "西洋料理", "ようしょく"]
            case .chinese: ["中華料理", "中華", "中国料理", "町中華"]
            case .italian: ["イタリアン", "イタリア料理"]
            case .french: ["フレンチ", "フランス料理"]
            case .korean: ["韓国料理", "韓国グルメ"]
            case .indian: ["インド料理", "インドカレー"]
            case .hamburger: ["ハンバーガー", "バーガー", "ハンバーガーショップ", "hamburger", "burger"]
            case .diningOut: ["外食", "外食費", "飲食店", "店内飲食", "外での食事"]
            }
        }

        var restaurants: [String] {
            switch self {
            case .japanese: ["大戸屋", "やよい軒", "すき家", "吉野家", "松屋", "なか卯", "丸亀製麺", "はなまるうどん", "和食さと", "とんかつ和幸", "しゃぶ葉", "日本料理店", "そば屋"]
            case .western: ["たいめいけん", "びっくりドンキー", "いきなりステーキ", "洋食屋"]
            case .chinese: ["餃子の王将", "大阪王将", "バーミヤン", "日高屋", "紅虎餃子房", "中国飯店"]
            case .italian: ["サイゼリヤ", "サイゼリア", "カプリチョーザ", "ジョリーパスタ", "鎌倉パスタ", "ピッツェリア", "トラットリア"]
            case .french: ["フレンチレストラン", "ブラッスリー", "ビストロ", "ジョエル・ロブション"]
            case .korean: ["韓国食堂", "韓国料理店", "韓国屋台", "妻家房"]
            case .indian: ["インド料理店", "インドレストラン", "エリックサウス"]
            case .hamburger: ["マクドナルド", "マクド", "mcdonald", "モスバーガー", "mos burger", "バーガーキング", "burger king", "フレッシュネスバーガー", "ロッテリア", "ゼッテリア", "シェイクシャック", "shake shack"]
            case .diningOut: ["レストラン", "食堂", "居酒屋", "焼肉店", "牛角", "ラーメン店", "ラーメン屋", "ファミレス", "ガスト", "ロイヤルホスト", "デニーズ", "大衆酒場"]
            }
        }

        var dishes: [String] {
            switch self {
            case .japanese: ["天ぷら", "天麩羅", "とんかつ", "親子丼", "牛丼", "蕎麦", "うどん", "刺身", "焼き魚", "懐石", "会席料理"]
            case .western: ["オムライス", "ハンバーグ", "ビーフシチュー", "ハヤシライス", "グラタン"]
            case .chinese: ["麻婆豆腐", "回鍋肉", "青椒肉絲", "小籠包", "餃子", "炒飯"]
            case .italian: ["パスタ", "ピッツァ", "ピザ", "リゾット"]
            case .french: ["ブイヤベース", "フランス料理"]
            case .korean: ["ビビンバ", "サムギョプサル", "スンドゥブ", "チヂミ"]
            case .indian: ["タンドリーチキン", "ビリヤニ"]
            case .hamburger: ["ビッグマック", "チーズバーガー", "てりやきバーガー"]
            case .diningOut: []
            }
        }
    }

    private static let sushiKeys = ["寿司", "寿し", "鮨", "鮓", "京樽", "銚子丸", "すしざんまい", "すしランチ", "すし屋", "回転すし", "にぎりすし", "手巻きすし", "元気すし", "すし食いねぇ"] + sushiMerchants.values.flatMap { $0 }
    private static let cafeKeys = ["カフェ", "喫茶", "cafe", "café", "coffee shop", "coffeehouse", "スターバックス", "スタバ", "starbucks", "ドトール", "doutor", "タリーズ", "tully", "コメダ", "komeda", "サンマルクカフェ", "エクセルシオール", "ベローチェ", "ヴェローチェ", "星乃珈琲"]
    private static let foodAliases: [String: FoodGroup] = {
        var aliases: [String: FoodGroup] = [:]
        for group in FoodGroup.allCases {
            for label in group.labels { aliases[normalized(label)] = group }
        }
        return aliases
    }()

    // Precompute these once; ledger searches can visit years of rows.
    private static let foodKeys: [FoodGroup: [String]] = Dictionary(uniqueKeysWithValues: FoodGroup.allCases.map { group in
        var words = group.labels
        for included in group.includedGroups {
            words += included.restaurants
            if group != .diningOut { words += included.labels + included.dishes }
        }
        if group == .japanese || group == .diningOut { words += sushiKeys }
        if group == .diningOut { words += cafeKeys }
        return (group, Array(Set(words.map(normalized))))
    })
    private static let nonFood = ["食器", "への電車", "電車代", "乗車券", "交通費", "定期券", "家具", "家賃", "光熱費", "水道代", "電気代", "通信費", "クリーニング", "Tシャツ", "キーホルダー", "ぬいぐるみ", "洋服", "ゲームソフト", "クスリのアオキ", "ドラッグストア"].map(normalized)
    private static let notDining = ["テイクアウト", "テークアウト", "持ち帰り", "持帰り", "持帰", "デリバリー", "出前", "宅配", "ウーバーイーツ", "uber eats", "自炊", "食材", "スーパーで", "コンビニで", "冷凍", "おうちごはん", "食パン", "弁当持参"].map(normalized)
    private static let unspecifiedFood = Set(["食費", "昼食", "ランチ", "お昼", "朝食", "夕食", "晩ごはん", "ディナー", "ごはん", "食事", "飲食", "買い物"].map(normalized))
    private static let retail = ["コンビニ", "スーパー", "ローソン", "ファミリーマート", "ファミマ", "セブンイレブン", "セブン-イレブン", "デイリーヤマザキ", "デイリーヤマサキ"].map(normalized)


    init(_ text: String) {
        key = Self.normalized(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A spoken group searches titles and categories. Ordinary names and exact category filters keep their literal meaning.
    static func ledgerName(_ text: String) -> Self {
        var term = Self(text)
        guard !term.isEmpty else { return term }
        if let group = spendingGroup(text) {
            term.merchantGroup = group
            if let food = FoodGroup(rawValue: group) {
                term.alternativeKeys = foodKeys[food] ?? []
            } else {
                switch group {
                case "寿司系": term.alternativeKeys = sushiKeys.map(normalized)
                case "カフェ": term.alternativeKeys = cafeKeys.map(normalized)
                default: term.alternativeKeys = [normalized(String(group.dropLast()))]
                }
            }
        } else if let selection = sushiMerchantList(text) {
            term.alternativeKeys = selection.names.flatMap { sushiMerchants[$0] ?? [] }
        } else if let shop = sushiMerchant(named: text) {
            term.alternativeKeys = sushiMerchants[shop] ?? []
        }
        return term
    }

    private static let sushiMerchants = [
        "はま寿司": ["ハマ寿司", "ハマズシ", "ハマスシ", "hamasushi", "hama sushi"],
        "かっぱ寿司": ["カッパ寿司", "カッパズシ", "カッパスシ", "kappasushi", "kappa sushi"],
        "くら寿司": ["クラ寿司", "クラズシ", "クラスシ", "kurasushi", "kura sushi"],
        "スシロー": ["スシロー", "スシロウ", "sushiro", "sushirō"], "魚べい": ["魚ベイ", "ウオベイ", "uobei"]
    ]

    private static func sushiMerchant(named text: String) -> String? {
        let key = normalized(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return sushiMerchants.first { $0.value.contains(key) }?.key
    }

    static func sushiMerchantList(_ text: String) -> (names: [String], examples: Bool)? {
        var subject = text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let examples = subject.hasSuffix("など")
        if examples { subject.removeLast(2) }
        let parts = subject.replacing(#/\s*(?:[とや・、,])\s*[、,]?\s*/#, with: "\n")
            .split(separator: "\n")
        guard !parts.isEmpty, examples || parts.count > 1 else { return nil }
        let names = parts.compactMap { sushiMerchant(named: String($0)) }
        return names.count == parts.count ? (names, examples) : nil
    }

    static func sushiSubject(_ text: String?) -> String? {
        guard let text else { return nil }
        if let list = sushiMerchantList(text) {
            return list.examples ? "寿司系" : list.names.joined(separator: "・")
        }
        switch normalized(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case "寿司系", "スシ系", "鮨系", "鮓系": return "寿司系"
        case "寿司", "スシ", "鮨", "鮓": return "寿司"
        default: return nil
        }
    }

    /// Only an open group asks the on-device model for additional merchant names.
    static func spendingGroup(_ text: String?) -> String? {
        guard let term = text?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty else { return nil }
        let name = term.hasSuffix("系") ? String(term.dropLast()) : term
        if let food = foodAliases[normalized(name)] { return food.rawValue }
        if sushiSubject(term) == "寿司系" { return "寿司系" }
        switch normalized(term) {
        case "カフェ", "カフェ系", "喫茶", "喫茶店", "喫茶店系", "cafe", "café", "coffee shop", "coffee shops": return "カフェ"
        default: return term.count > 1 && term.hasSuffix("系") ? term : nil
        }
    }

    static func isKnownUnrelatedMerchant(_ title: String, for group: String) -> Bool {
        let key = normalized(title)
        if unspecifiedFood.contains(key) || nonFood.contains(where: key.contains) { return true }
        // Several unrelated retailers share the phonetic name マツヤ. A receipt in kana alone
        // cannot identify the 松屋 restaurant. An explicit dish or category can still match.
        if key == "マツヤ" || key.hasPrefix("マツヤ ") || key.hasPrefix("マツヤ　") { return true }
        if group == "寿司系" { return true } // A sushi total needs explicit evidence in the title or category.
        if group == FoodGroup.diningOut.rawValue && notDining.contains(where: key.contains) { return true }
        if retail.contains(where: key.contains) { return true }
        let allowed = FoodGroup(rawValue: group)?.includedGroups ?? []
        if !allowed.contains(.diningOut), FoodGroup.diningOut.restaurants.contains(where: { key.contains(normalized($0)) }),
           !ledgerName(group).matches(title) { return true }
        if FoodGroup.allCases.contains(where: { food in
            food != .diningOut && !allowed.contains(food) && (foodKeys[food] ?? []).contains(where: key.contains)
        }) { return !ledgerName(group).matches(title) }
        if group == "カフェ" { return ledgerName("寿司系").matches(title) }
        return false
    }

    /// Recheck a stored model selection against this row on every read, including older Siri cards.
    func matchesLedgerRow(title: String, category: String, relatedTitles: Set<String> = []) -> Bool {
        if let group = merchantGroup {
            let titleKey = Self.normalized(title), categoryKey = Self.normalized(category)
            if Self.nonFood.contains(where: titleKey.contains) || Self.nonFood.contains(where: categoryKey.contains) { return false }
            if group == FoodGroup.diningOut.rawValue && (Self.notDining.contains(where: titleKey.contains)
                || Self.notDining.contains(where: categoryKey.contains) || Self.retail.contains(where: titleKey.contains)) { return false }
            if group == "寿司系" {
                return matches(title) || matches(category) || titleKey == "スシ" || categoryKey == "スシ"
            }
            if matches(title) || matches(category) { return true }
            return relatedTitles.contains(title) && !Self.isKnownUnrelatedMerchant(title, for: group)
        }
        return matches(title) || matches(category)
    }

    func matches(_ value: String) -> Bool {
        let candidate = Self.normalized(value)
        return candidate.contains(key) || alternativeKeys.contains(where: candidate.contains)
    }

    func matchesCategory(_ name: String) -> Bool {
        Self.normalized(name) == key
    }

    func matchesNameOrCategory(of expense: Expense) -> Bool {
        matchesLedgerRow(title: expense.displayTitle, category: expense.categoryDisplayName)
    }

    func matchesNameOrCategory(of occurrence: RecurringOccurrence) -> Bool {
        matchesLedgerRow(title: occurrence.title, category: occurrence.categoryDisplayName)
    }

    nonisolated private static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}

#if os(macOS) || os(visionOS)
/// The editor may stay open while the main context saves unrelated changes.
@MainActor
struct RecurringOccurrenceDraft: Identifiable {
    let id: String
    let context: NSManagedObjectContext
    let expense: Expense

    init?(_ occurrence: RecurringOccurrence, sheet: ExpenseSheet) {
        guard let coordinator = sheet.managedObjectContext?.persistentStoreCoordinator else { return nil }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.automaticallyMergesChangesFromParent = true
        guard let draftSheet = try? context.existingObject(with: sheet.objectID) as? ExpenseSheet,
              let rules = draftSheet.recurringRules as? Set<RecurringRule>,
              let rule = rules.first(where: { $0.id == occurrence.ruleID }) else { return nil }
        let category = (draftSheet.categories as? Set<ExpenseCategory>)?.first {
            $0.kind == occurrence.kind && $0.name == occurrence.categoryRaw
        }
        let expense = RecurringExpenseGenerator.makeOccurrence(for: rule, on: occurrence.scheduledDate,
                                                              sheet: draftSheet, category: category, in: context)
        expense.date = occurrence.date
        id = occurrence.id
        self.context = context
        self.expense = expense
    }
}
#endif

//
//  WatchAddExpenseView.swift
//  Budgety Watch
//
//  Digital Crown で金額を回し、保存する超シンプル追加画面。
//  - シートのテーマ色 (= sheet.tint) で UI が彩られる
//  - 自動採用される予定のカテゴリをプレビュー表示
//  - 保存時にチェックマークがバウンス + ハプティクス
//

import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct WatchAddExpenseView: View {
    let sheet: ExpenseSheet

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx

    /// Digital Crown で操作する金額 (= 円)。0 ... 100,000 (= 10 万円)。
    /// 実際の刻みは回転速度に応じて 1 / 10 / 100 / 1000 と段階的に変わる
    /// (`CrownSpeedStepper` が算出)。
    @State private var amount: Double = 0
    /// Digital Crown の生の回転値 (detent アキュムレータ)。速度推定に使う。
    /// amount とは別に細かい粒度で回し、その変化量と時間差から刻みを決める。
    @State private var crownRaw: Double = 0
    /// 回転速度 → 刻み量を決めるロジック (ヒステリシス付き)。
    @State private var crownStepper = CrownSpeedStepper()
    @FocusState private var crownFocused: Bool
    @State private var saved: Bool = false
    @State private var saveBounce: Int = 0
    @State private var showingCategoryPicker: Bool = false
    @State private var manuallySelectedCategory: ExpenseCategory?

    /// 割り勘トグル。オフ = 自分の負担のみ。オン = `selectedBeneficiaries` で割る相手を選ぶ
    /// (空 = 全員均等)。共有シート (他メンバーあり) でのみ UI を出す。
    @State private var splitEnabled: Bool = false
    @State private var selectedBeneficiaries: Set<String> = []
    @State private var showingSplitPicker: Bool = false

    /// シートの全支出カテゴリ (= sortOrder 順)。
    private var availableCategories: [ExpenseCategory] {
        guard let cats = sheet.categories as? Set<ExpenseCategory> else { return [] }
        return cats
            .filter { $0.kind == .expense }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 自動採用されるカテゴリ (= シートの最初の支出カテゴリ)。
    private var autoCategory: ExpenseCategory? {
        availableCategories.first
    }

    /// 実際に保存に使うカテゴリ (= ユーザー選択優先 / 無ければ auto)。
    private var effectiveCategory: ExpenseCategory? {
        manuallySelectedCategory ?? autoCategory
    }

    /// 共有シート (自分以外の参加メンバーがいる) か。割り勘 UI はこの時だけ出す。
    private var isShared: Bool { sheet.hasAcceptedOtherMembers() }

    /// 割り勘ボタンのラベル。
    private var splitLabel: String {
        guard splitEnabled else { return String(localized: "割り勘なし") }
        let total = sheet.acceptedMemberProfileIDs().count
        let n = selectedBeneficiaries.isEmpty ? total : selectedBeneficiaries.count
        return n >= total ? String(localized: "全員で割り勘") : String(localized: "\(n)人で割り勘")
    }

    /// シートの通貨記号 (¥ / $ / € など)。
    private var currencySymbol: String {
        CurrencyCatalog.option(for: sheet.resolvedDefaultCurrencyCode).symbol
    }

    /// シート既定通貨の小数桁数 (0 = JPY/KRW 等 / 2 = USD/EUR 等)。
    private var currencyDecimals: Int {
        CurrencyCatalog.fractionDigits(for: sheet.resolvedDefaultCurrencyCode)
    }
    /// Digital Crown の刻み。小数なし通貨は 100、小数あり通貨は 1。
    private var amountStep: Double { currencyDecimals == 0 ? 100 : 1 }
    /// クイック加算ボタンの刻み (通貨の桁数に合わせる)。
    private var quickSteps: [Int] { currencyDecimals == 0 ? [100, 500, 1000] : [1, 10, 100] }
    /// 金額を通貨フォーマットしたテキスト (¥5,000 / $5.00 など)。
    private var amountText: String {
        CurrencyCatalog.format(Decimal(amount), code: sheet.resolvedDefaultCurrencyCode)
    }

    var body: some View {
        ZStack {
            content
            if saved {
                savedOverlay
                    .transition(.opacity)
            }
        }
        .containerBackground(sheet.tint.gradient, for: .navigation)
        .navigationTitle {
            Text("追加")
                .foregroundStyle(sheet.tint)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                let canSave = amount > 0 && !saved
                Button {
                    save()
                } label: {
                    Image(systemName: "checkmark")
                }
                .tint(canSave ? sheet.tint : .clear)
                .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            WatchCategoryPicker(
                categories: availableCategories,
                selected: effectiveCategory
            ) { picked in
                manuallySelectedCategory = picked
            }
        }
        .sheet(isPresented: $showingSplitPicker) {
            WatchSplitPicker(
                sheet: sheet,
                splitEnabled: $splitEnabled,
                selected: $selectedBeneficiaries
            )
        }
    }

    /// 割り勘の状態を表すボタン (共有シートのみ)。タップで相手選択シートを開く。
    @ViewBuilder
    private var splitPreview: some View {
        if isShared {
            Button {
                showingSplitPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: splitEnabled ? "person.2.fill" : "person.fill")
                        .font(.caption2.weight(.semibold))
                    Text(splitLabel)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.20)))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 6) {
            VStack(spacing: 4) {
                categoryPreview
                splitPreview
            }
            Spacer(minLength: 0)
            Text(amountText)
                .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy, value: amount)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(quickSteps, id: \.self) { step in
                    quickButton(step)
                }
            }
        }
        .padding(.horizontal, 4)
        .focusable(true)
        .focused($crownFocused)
        // 生の回転値を細かい粒度 (0.5 detent) で受け、変化量と時間差から
        // 回転速度を推定して amount の刻みを 1x/10x/100x/1000x に切り替える。
        .digitalCrownRotation(
            $crownRaw,
            from: -1_000_000, through: 1_000_000, by: 0.5,
            sensitivity: .high,
            isContinuous: true,
            isHapticFeedbackEnabled: false
        )
        .onChange(of: crownRaw) { oldValue, newValue in
            applyCrownDelta(from: oldValue, to: newValue)
        }
        .onAppear { crownFocused = true }
        .opacity(saved ? 0 : 1)
    }

    @ViewBuilder
    private var categoryPreview: some View {
        if let cat = effectiveCategory {
            Button {
                showingCategoryPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cat.symbol ?? "tag.fill")
                        .font(.caption.weight(.semibold))
                    Text(cat.name ?? "")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.20)))
            }
            .buttonStyle(.plain)
        }
    }

    private func quickButton(_ step: Int) -> some View {
        Button {
            amount = min(100_000, amount + Double(step))
            WKInterfaceDevice.current().play(.click)
        } label: {
            Text("+\(step)")
                .font(.system(.caption, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.20))
                )
        }
        .buttonStyle(.plain)
    }

    private var savedOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: saveBounce)
            Text("保存しました")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Digital Crown の生の回転差分を amount に反映する。回転が速いほど大きい
    /// 刻み (1 → 10 → 100 → 1000 × 通貨基準) で動かし、大きい刻みの時はその
    /// 単位に丸める。切替はヒステリシス付きで頻繁に飛び跳ねないようにする。
    private func applyCrownDelta(from oldValue: Double, to newValue: Double) {
        let rawDelta = newValue - oldValue
        guard rawDelta != 0 else { return }
        // 速度に応じた刻み倍率 (1 / 10 / 100 / 1000)。
        let multiplier = crownStepper.step(forRawDelta: rawDelta, now: Date())
        let step = amountStep * Double(multiplier)
        let direction: Double = rawDelta > 0 ? 1 : -1
        var next = amount + direction * step
        // 大きい刻みで動いた時はその刻み単位へ丸めると気持ちよい。
        if multiplier > 1 {
            next = (next / step).rounded() * step
        }
        next = min(100_000, max(0, next))
        guard next != amount else { return }
        amount = next
        WKInterfaceDevice.current().play(.click)
    }

    private func save() {
        guard amount > 0 else { return }
        let dec = Decimal(amount)
        let expense = Expense(context: ctx)
        // ストア割当は Expense 自体の作成直後にやる。Member などほかのエンティティを
        // 触る前に固定しないと cross-store エラーになる。
        if let store = sheet.objectID.persistentStore {
            ctx.assign(expense, to: store)
        }
        expense.amount = NSDecimalNumber(decimal: dec)
        expense.currencyCode = sheet.resolvedDefaultCurrencyCode
        expense.kindRaw = TransactionKind.expense.rawValue
        expense.date = Date()
        expense.title = ""
        expense.note = ""
        expense.createdAt = .now
        expense.sheet = sheet
        expense.category = effectiveCategory
        // 支払者: 自分。watchOS では Member は触らず、payerProfileID と payerMemberID を
        // UserProfileStore キャッシュから直接埋めるだけにする (ensureSelfMemberExists を
        // 呼ぶと別ストアに Member が作られて cross-store クラッシュを起こす可能性あり)。
        // 旧 userRecordName を入れておけば、iOS 側 auto-migration が共有シートの場合に
        // email canonical へ書き換える。
        let profile = UserProfileStore.shared
        let mid = profile.ensureSelfMemberID()
        expense.payerMemberID = mid
        if let pid = profile.userRecordName, !pid.isEmpty {
            expense.payerProfileID = pid
        }
        // 割り勘: 共有シートのみ反映。
        // - オン: 選んだ相手 (空にはしない。未選択なら現メンバー全員を明示保存)
        // - オフ: 受益者未設定 (空) で保存
        //   (= resolvedBeneficiaryIDs() で「割り勘オフ = 支払者単独負担」扱い)
        // 空 = 全員均等にすると、あとで追加したメンバーが過去の支出に遡って
        // 含まれてしまうため、オン時のみ必ず明示的な ID リストを保存する。
        if isShared, splitEnabled {
            let ids = selectedBeneficiaries.isEmpty
                ? Set(sheet.acceptedMemberProfileIDs())
                : selectedBeneficiaries
            expense.beneficiaryProfileIDs = ids.sorted().joined(separator: ",")
        }
        // オフの場合は beneficiaryProfileIDs を触らない (デフォルトの空のまま)

        // FX スナップショット (= 為替変動による残高ドリフト防止)。
        // watchOS では既定通貨を使うのでだいたい snapshot == amount だが、
        // 共有シートで他端末が target を変えた時の整合性のため明示的に保存。
        expense.captureFXSnapshot()

        do {
            try ctx.save()
            WKInterfaceDevice.current().play(.success)
            withAnimation(.snappy) {
                saved = true
                saveBounce += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                dismiss()
            }
        } catch {
            WKInterfaceDevice.current().play(.failure)
        }
    }
}

// MARK: - Crown Speed Stepper

/// Digital Crown の回転速度から刻み倍率 (1 / 10 / 100 / 1000) を決める。
/// - 直近の速度を指数移動平均 (EMA) で平滑化し、単発の急変で刻みが飛ばないようにする。
/// - しきい値にヒステリシス (上げる閾値 > 下げる閾値) を持たせ、境界で倍率が
///   チラつかないようにする。
/// - 一定時間 (idleReset) 回転が止まったら速度をリセットして「遅い」から再開する。
struct CrownSpeedStepper {
    /// 平滑化した速度 (raw detents / 秒)。
    private var smoothedSpeed: Double = 0
    /// 前回イベントの時刻。
    private var lastEventTime: Date?
    /// 現在の刻み倍率 (1 / 10 / 100 / 1000)。ヒステリシス判定の基準。
    private var currentMultiplier: Int = 1

    /// EMA の平滑化係数 (0..1)。大きいほど直近値に敏感。
    private let smoothing: Double = 0.35
    /// この秒数以上イベントが空いたら停止とみなし速度を 0 に戻す。
    private let idleReset: TimeInterval = 0.35

    /// 倍率を上げるしきい値 (raw detents / 秒)。速い順に判定。
    /// 下げるしきい値はこれより低くしてヒステリシスにする。
    private let upThresholds: [(speed: Double, multiplier: Int)] = [
        (28, 1000),
        (16, 100),
        (7,  10),
    ]
    /// 倍率を下げる時のしきい値 (= up の 0.6 倍相当)。
    private let downThresholds: [(speed: Double, multiplier: Int)] = [
        (18, 1000),
        (10, 100),
        (4,  10),
    ]

    /// 生の回転差分と現在時刻から、この 1 ステップに使う刻み倍率を返す。
    mutating func step(forRawDelta rawDelta: Double, now: Date) -> Int {
        let magnitude = abs(rawDelta)
        // 経過時間 (秒)。初回や長い空白は idleReset で頭打ちにして速度を薄める。
        let dt: TimeInterval
        if let last = lastEventTime {
            dt = min(max(now.timeIntervalSince(last), 0.001), idleReset)
        } else {
            dt = idleReset
        }
        lastEventTime = now

        // 長時間止まっていたら一旦リセット (= ゆっくり操作に戻す)。
        if dt >= idleReset {
            smoothedSpeed = 0
            currentMultiplier = 1
        }

        // 瞬間速度を EMA で平滑化。
        let instantSpeed = magnitude / dt
        smoothedSpeed = smoothedSpeed * (1 - smoothing) + instantSpeed * smoothing

        currentMultiplier = resolveMultiplier(speed: smoothedSpeed, current: currentMultiplier)
        return currentMultiplier
    }

    /// 平滑化速度と現在倍率から、ヒステリシス付きで次の倍率を決める。
    private func resolveMultiplier(speed: Double, current: Int) -> Int {
        // まず「上げられる最大倍率」を up しきい値で判定。
        var target = 1
        for t in upThresholds where speed >= t.speed {
            target = t.multiplier
            break
        }
        // 現在より上げる時は up 判定をそのまま採用。
        if target > current { return target }
        // 現在を維持 or 下げる時は down しきい値で判定 (ヒステリシス)。
        // 速度が down しきい値を割った段階のみ倍率を下げる。
        var held = 1
        for t in downThresholds where speed >= t.speed {
            held = t.multiplier
            break
        }
        return max(held, target)
    }
}

// MARK: - Category Picker

struct WatchCategoryPicker: View {
    let categories: [ExpenseCategory]
    let selected: ExpenseCategory?
    let onPick: (ExpenseCategory) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories, id: \.objectID) { cat in
                    Button {
                        onPick(cat)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: cat.symbol ?? "tag.fill")
                                // Dynamic Type で巨大化して円からはみ出さないよう固定サイズに
                                // (ホーム行のカテゴリアイコンと同じ方式)。
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle().fill((Color(hex: cat.colorHex ?? "#5B8DEF") ?? .blue).gradient)
                                )
                            Text(cat.name ?? "")
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            if cat.objectID == selected?.objectID {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("カテゴリ")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Split (割り勘) Picker

/// 割り勘の ON/OFF と、割る相手 (受益者) を選ぶピッカー。
/// メンバーは ParticipantProfile から解決 (= watchOS でも CloudKit 同期済みなら表示可能)。
struct WatchSplitPicker: View {
    let sheet: ExpenseSheet
    @Binding var splitEnabled: Bool
    @Binding var selected: Set<String>

    @Environment(\.dismiss) private var dismiss
    /// 他メンバーのプロフィール写真がロードされたら再描画する。
    @ObservedObject private var pub = PublicProfileSync.shared

    /// 割り勘候補メンバー。空 id を除き、重複を取り除いた安全なリスト。
    /// `ForEach(id: \.self)` は id が重複すると watchOS でクラッシュ/描画崩れを
    /// 起こすため、必ずここで一意化してから使う。
    private var members: [String] {
        var seen = Set<String>()
        return sheet.acceptedMemberProfileIDs().filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("割り勘する", isOn: $splitEnabled)
                }
                if splitEnabled {
                    Section("割る相手") {
                        // enumerated() で index+id の複合キーにし、万一 id が重複
                        // していても ForEach の identity が衝突しないようにする。
                        ForEach(Array(members.enumerated()), id: \.offset) { _, id in
                            memberRow(id)
                        }
                    }
                }
            }
            .navigationTitle("割り勘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .onAppear { prefetchMemberPhotos() }
            .onChange(of: splitEnabled) { _, on in
                // 初めてオンにした時は全員を選択 (= 全員均等)。
                if on && selected.isEmpty {
                    selected = Set(members)
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ id: String) -> some View {
        let info = sheet.memberDisplayInfo(for: id)
        let isOn = selected.contains(id)
        Button {
            if isOn { selected.remove(id) } else { selected.insert(id) }
            WKInterfaceDevice.current().play(.click)
        } label: {
            HStack(spacing: 10) {
                avatar(info)
                Text(info.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isOn ? sheet.tint : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// メンバーアバター。写真があれば写真、無ければ配色 + 頭文字。
    @ViewBuilder
    private func avatar(_ info: (name: String, colorHex: String, photoData: Data?)) -> some View {
        let color = Color(hex: info.colorHex) ?? .blue
        #if canImport(UIKit)
        if let data = info.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            initialAvatar(name: info.name, color: color)
        }
        #else
        initialAvatar(name: info.name, color: color)
        #endif
    }

    private func initialAvatar(name: String, color: Color) -> some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 28, height: 28)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            )
    }

    /// メンバーのプロフィール写真を Public DB からまとめて取得する。
    private func prefetchMemberPhotos() {
        let urns = members.filter {
            !$0.isEmpty
            && !$0.hasPrefix("email:")
            && !$0.hasPrefix("phone:")
            && !UserProfileStore.isVirtualRecordName($0)
        }
        guard !urns.isEmpty else { return }
        Task { await PublicProfileSync.shared.fetchProfiles(forURNs: urns) }
    }
}

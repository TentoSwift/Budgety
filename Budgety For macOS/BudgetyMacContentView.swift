//
//  BudgetyMacContentView.swift
//  Budgety For macOS
//
//  iOS 版 SheetListView 相当。NavigationSplitView の sidebar にシート一覧、
//  detail に選択中のシートの支出ビュー。
//

import SwiftUI
import CoreData

struct BudgetyMacContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)
        ],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var selectedSheet: ExpenseSheet?
    @State private var showingAddSheet: Bool = false
    @State private var showSettingsView: Bool = false
    @State private var showingProfileEdit: Bool = false
    @State private var showingPaywall: Bool = false
    @State private var showSyncWaitingAlert: Bool = false
    @State private var showOfflineAlert: Bool = false
    @StateObject private var lockManager = SheetLockManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let sheet = selectedSheet {
                if lockManager.isUnlocked(sheet) {
                    BudgetyMacSheetView(sheet: sheet)
                } else {
                    // ロック中はパスワード入力画面を detail に表示。
                    // 解錠すると lockManager の変化で自動的にシート本体へ切り替わる。
                    SheetLockView(
                        record: sheet,
                        onUnlock: { },
                        onCancel: { selectedSheet = nil }
                    )
                }
            } else {
                ContentUnavailableView {
                    Label("シートを選択", systemImage: "rectangle.stack")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            MacAddSheetView()
        }
        .sheet(isPresented: $showSettingsView) {
            BudgetyMacSettingsView()
        }
        .sheet(isPresented: $showingProfileEdit) {
            ProfileEditView()
        }
        .sheet(isPresented: $showingPaywall) {
            MacModalSheet { PaywallView() }
        }
        .alert("同期完了を待っています", isPresented: $showSyncWaitingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iCloud から既存のシートを取得中です。少し待ってからもう一度お試しください。")
        }
        .alert("インターネット接続が必要です", isPresented: $showOfflineAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("シートの新規作成には iCloud との同期が必要です。インターネットに接続してから再度お試しください。")
        }
        .onAppear {
            if selectedSheet == nil { selectedSheet = sheets.first }
        }
        .onChange(of: selectedSheet) { old, _ in
            // 別シートへ移動したら、離れたシートを再ロックする。
            if let old, lockManager.hasPassword(for: old) {
                lockManager.lock(old)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // アプリがバックグラウンド (非表示) になったら全シートを再ロック。
            if phase == .background { lockManager.lockAll() }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSheet) {
            if sheets.isEmpty {
                Section {
                    Label("シートがありません", systemImage: "tray")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(sheets) { sheet in
                    NavigationLink(value: sheet) {
                        sheetRow(sheet)
                    }
                    .tag(sheet)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            profileFooter
        }
        .toolbar {
            ToolbarItem {

            }
            ToolbarItem {
                Button {
                    tryShowAddSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .help("シートを追加")
            }
        }
    }

    /// Free 上限・同期状態を確認してから新規シート作成ダイアログを出す (iOS と同じゲート)。
    /// 無料プランは自分が作成したシートを `FreeTierLimits.ownedSheets` 個までに制限する。
    private func tryShowAddSheet() {
        switch PurchaseManager.sheetCreationGate() {
        case .allowed:
            showingAddSheet = true
        case .waitingForSync:
            showSyncWaitingAlert = true
            Haptics.warning()
        case .offline:
            showOfflineAlert = true
            Haptics.warning()
        case .overLimit:
            showingPaywall = true
            Haptics.warning()
        }
    }

    /// Apple Music の sidebar footer 風プロフィール行。タップで ProfileEditView を開く。
    private var profileFooter: some View {
        Button {
            showingProfileEdit = true
        } label: {
            HStack(spacing: 10) {
                AvatarView(
                    photoData: profile.photoData,
                    displayName: profile.resolvedDisplayName,
                    colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                    size: 28
                )
                Text(profile.resolvedDisplayName)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("プロフィールを編集")
        .background(.bar)
    }

    private func sheetRow(_ sheet: ExpenseSheet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(sheet.tint.gradient)
                    .frame(width: 36, height: 36)
                Image(systemName: sheet.symbol ?? "person.2.fill")
                    .foregroundStyle(.white)
                    .font(.callout.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sheet.displayName).font(.body.weight(.medium))
                Text(monthlyLabel(for: sheet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if lockManager.hasPassword(for: sheet) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if sheet.isOwnedByCurrentUser == false {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func monthlyLabel(for sheet: ExpenseSheet) -> String {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let monthlyTotal = ((sheet.expenses as? Set<Expense>) ?? [])
            .filter { e in
                guard let d = e.date, e.kind == .expense else { return false }
                let c = cal.dateComponents([.year, .month], from: d)
                return c.year == comps.year && c.month == comps.month
            }
            .reduce(Decimal(0)) { $0 + $1.amountDecimal }
        return "今月 \(CurrencyCatalog.format(monthlyTotal, code: sheet.resolvedDefaultCurrencyCode))"
    }
}

// MARK: - Add Sheet

struct MacAddSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @State private var name: String = ""
    @State private var colorHex: String = "#5B8DEF"
    @State private var symbol: String = "person.2.fill"
    @State private var currencyCode: String = CurrencyCatalog.defaultCode

    var body: some View {
        MacSheetFormDialog(
            title: "新規シート",
            name: $name,
            colorHex: $colorHex,
            symbol: $symbol,
            currencyCode: $currencyCode,
            primaryActionLabel: "OK",
            onCancel: { dismiss() },
            onSave: { save() }
        )
    }

    private func save() {
        let sheet = ExpenseSheet(context: viewContext)
        sheet.name = name.trimmingCharacters(in: .whitespaces)
        sheet.colorHex = colorHex
        sheet.symbol = symbol
        sheet.defaultCurrencyCode = currencyCode
        sheet.createdAt = .now
        PersistenceController.seedDefaultCategories(for: sheet, in: viewContext)
        PersistenceController.shared.save()
        Task { @MainActor in
            await UserProfileStore.shared.ensureUserRecordNameLoaded()
            UserProfileStore.shared.ensureSelfMemberExists(in: viewContext)
            UserProfileStore.shared.ensureProfile(in: sheet, ctx: viewContext)
        }
        dismiss()
    }
}

// MARK: - Edit Sheet (Mac)

/// Mac 用シート編集ダイアログ。リマインダー風のコンパクトなレイアウト。
struct MacEditSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var record: ExpenseSheet

    @State private var name: String = ""
    @State private var colorHex: String = "#5B8DEF"
    @State private var symbol: String = "person.2.fill"
    @State private var currencyCode: String = CurrencyCatalog.defaultCode
    @State private var didLoad: Bool = false
    @State private var showingDeleteConfirm: Bool = false

    var body: some View {
        MacSheetFormDialog(
            title: "シートを編集",
            name: $name,
            colorHex: $colorHex,
            symbol: $symbol,
            currencyCode: $currencyCode,
            primaryActionLabel: "保存",
            destructiveAction: { showingDeleteConfirm = true },
            onCancel: { dismiss() },
            onSave: { save() }
        )
        .onAppear { loadOnce() }
        .confirmationDialog(
            "「\(name)」を削除しますか？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                viewContext.delete(record)
                PersistenceController.shared.save()
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("配下の支出・カテゴリ・送金記録もすべて削除されます。")
        }
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        name = record.displayName
        colorHex = record.colorHex ?? "#5B8DEF"
        symbol = record.symbol ?? "person.2.fill"
        currencyCode = record.resolvedDefaultCurrencyCode
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        record.name = trimmed
        record.colorHex = colorHex
        record.symbol = symbol
        record.defaultCurrencyCode = currencyCode
        PersistenceController.shared.save()
        dismiss()
    }
}

// MARK: - Shared dialog

/// リマインダー風の縦コンパクトなシート設定ダイアログ。Add / Edit 両方で使う。
private struct MacSheetFormDialog: View {
    let title: String
    @Binding var name: String
    @Binding var colorHex: String
    @Binding var symbol: String
    @Binding var currencyCode: String
    let primaryActionLabel: String
    var destructiveAction: (() -> Void)? = nil
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var showingSymbolPicker: Bool = false
    @State private var showingPaywall: Bool = false
    @StateObject private var pm = PurchaseManager.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// AX サイズなら column を縦に積む。
    private var useStackedLayout: Bool {
        dynamicTypeSize >= .accessibility1
    }

    /// テキストサイズに応じてラベル列の幅を計算 (= ラベルが折り返さないように)
    private var labelColumnWidth: CGFloat {
        switch dynamicTypeSize {
        case .accessibility5, .accessibility4: return 140
        case .accessibility3, .accessibility2: return 120
        case .accessibility1, .xxxLarge:       return 100
        default:                               return 80
        }
    }

    /// リマインダー準拠の 12 色パレット。
    private let palette: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#5B8DEF",
        "#5856D6", "#FF2D55", "#AF52DE", "#A2845E", "#8E8E93", "#FFB1C8"
    ]

    /// 現在選択中のカラー (フォールバックはアクセントカラー)。
    private var selectedColor: Color {
        Color(hex: colorHex) ?? .accentColor
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ヘッダ (タブ風タイトル)
                HStack {
                    Spacer()
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selectedColor))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.bottom, 14)

                // フォーム
                VStack(spacing: 16) {
                    // 名前
                    formRow(label: "名前:") {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // カラー + アイコン (AX サイズなら縦並び)
                    colorAndIconRow

                    Divider().padding(.top, 4)

                    // 既定通貨
                    formRow(label: "既定通貨:") {
                        Picker("", selection: $currencyCode) {
                            ForEach(CurrencyCatalog.all) { opt in
                                Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320, alignment: .leading)
                        Spacer(minLength: 0)
                    }

                    Divider().padding(.top, 4)

                    // ボタン
                    HStack {
                        if let destructiveAction {
                            Button {
                                destructiveAction()
                            } label: {
                                Text("削除")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        Spacer()
                        Button("キャンセル") { onCancel() }
                        Button(primaryActionLabel) { onSave() }
                            .keyboardShortcut(.return)
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            }
        }
        .scrollIndicators(.never)
        .frame(width: 560)
        .frame(minHeight: 280, maxHeight: 720)
    }

    /// label が AX サイズで折り返す前提のラベル付き行。狭い時は縦並び。
    @ViewBuilder
    private func formRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if useStackedLayout {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                content()
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .frame(width: labelColumnWidth, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    /// カラー + アイコン 行。AX サイズでは縦に積む。
    @ViewBuilder
    private var colorAndIconRow: some View {
        if useStackedLayout {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("カラー:")
                    colorGrid
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("アイコン:")
                    symbolPickerButton
                }
            }
        } else {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text("カラー:")
                            .frame(width: labelColumnWidth, alignment: .trailing)
                        colorGrid
                    }
                }
                Divider().frame(height: 60)
                HStack(spacing: 10) {
                    Text("アイコン:")
                    symbolPickerButton
                }
            }
        }
    }

    private var colorGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(28), spacing: 10), count: 6)
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(palette, id: \.self) { hex in
                let isOn = (hex == colorHex)
                Circle()
                    .fill(Color(hex: hex) ?? .blue)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if isOn {
                            Circle()
                                .stroke(Color(hex: hex) ?? .blue, lineWidth: 2)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { colorHex = hex }
            }
        }
    }

    private var symbolPickerButton: some View {
        Button {
            showingSymbolPicker.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(selectedColor)
                    .frame(width: 44, height: 44)
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSymbolPicker, arrowEdge: .top) {
            symbolGrid
        }
    }

    private var symbolGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SheetSymbols.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(section.symbols, id: \.self) { sym in
                                symbolButton(sym)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .frame(width: 320, height: 360)
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }

    @ViewBuilder
    private func symbolButton(_ sym: String) -> some View {
        let isSelected = (symbol == sym)
        let isLocked = SheetSymbols.isPremiumSymbol(sym) && !pm.isPremium
        Button {
            if isLocked {
                showingPaywall = true
            } else {
                symbol = sym
                showingSymbolPicker = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected
                          ? AnyShapeStyle(selectedColor)
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 36, height: 36)
                if isSelected {
                    Circle()
                        .stroke(selectedColor, lineWidth: 2)
                        .frame(width: 40, height: 40)
                }
                Image(systemName: sym)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .opacity(isLocked ? 0.45 : 1)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 13, y: 13)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct BudgetyMacSettingsView: View {
    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pm = PurchaseManager.shared
    @State private var shareURLText: String = ""
    @State private var acceptInProgress: Bool = false
    @State private var acceptMessage: String?
    @State private var showingPaywall: Bool = false
    @State private var showingProfileEdit: Bool = false
    @State private var showingEraseConfirm: Bool = false

    var body: some View {
        Form {
            Section("プロフィール") {
                Button {
                    showingProfileEdit = true
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(
                            photoData: profile.photoData,
                            displayName: profile.resolvedDisplayName,
                            colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                            size: 40
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.resolvedDisplayName)
                                .foregroundStyle(.primary)
                            Text("名前・写真・背景色を編集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            Section("Premium") {
                HStack(spacing: 12) {
                    Image(systemName: pm.isPremium ? "crown.fill" : "crown")
                        .foregroundStyle(pm.isPremium ? .yellow : .secondary)
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text(pm.isPremium ? "Premium 加入中" : "無料プラン")
                            .font(.body.weight(.medium))
                        Text(pm.isPremium
                             ? "すべての機能をご利用いただけます。"
                             : "Premium にすると共有招待やカテゴリ追加など追加機能が解放されます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if pm.isPremium {
                    Link("サブスクリプションを管理",
                         destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                } else {
                    Button {
                        showingPaywall = true
                    } label: {
                        Label("Premium にアップグレード", systemImage: "crown.fill")
                    }
                    Button {
                        Task { await pm.restore() }
                    } label: {
                        if pm.isProcessing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("復元中…")
                            }
                        } else {
                            Label("購入を復元", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(pm.isProcessing)
                }
            }

            Section {
                TextField("https://www.icloud.com/share/...", text: $shareURLText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        Task { await acceptURL() }
                    } label: {
                        if acceptInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("URL を貼り付けて参加")
                        }
                    }
                    .disabled(shareURLText.isEmpty || acceptInProgress)
                    Spacer()
                }
                if let acceptMessage {
                    Text(acceptMessage)
                        .font(.caption)
                        .foregroundStyle(acceptMessage.contains("失敗") ? .red : .secondary)
                }
            } header: {
                Text("共有シートに参加")
            } footer: {
                Text("メールで届いた共有リンク (https://www.icloud.com/share/... または cloudkit-... など) を貼り付けて参加できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("バージョン") {
                LabeledContent("Budgety", value: "1.0")
            }

            Section {
                Button(role: .destructive) {
                    showingEraseConfirm = true
                } label: {
                    Label("全データを削除", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text("シート・支出・カテゴリ・メンバー・繰り返し項目・テンプレ・プロフィール (名前/写真) を含む全データを削除し、設定 (シートロック等) も初期化します。自分が作成した共有は解除され iCloud からも削除されます。受信した共有シートはオーナー側のデータには影響しません。元に戻せません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPaywall) {
            MacModalSheet { PaywallView() }
        }
        .sheet(isPresented: $showingProfileEdit) {
            ProfileEditView()
        }
        .confirmationDialog(
            "全データを削除しますか?",
            isPresented: $showingEraseConfirm,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) {
                Task { @MainActor in
                    Haptics.warning()
                    await PersistenceController.shared.eraseAllData()
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("すべてのデータ・プロフィール・設定を削除し、アプリを初期状態に戻します。元に戻せません。削除後はアプリを再起動してください。")
        }
    }

    @MainActor
    private func acceptURL() async {
        let trimmed = shareURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            acceptMessage = "URL の形式が正しくありません"
            return
        }
        acceptInProgress = true
        defer { acceptInProgress = false }
        do {
            // AppDelegate を取り出してメソッド経由で受諾
            if let delegate = NSApp.delegate as? BudgetyMacAppDelegate {
                try await delegate.acceptShareURL(url)
                acceptMessage = "受諾を実行しました (シートが現れるまで数秒)"
                shareURLText = ""
            } else {
                acceptMessage = "AppDelegate が見つかりません"
            }
        } catch {
            acceptMessage = "失敗: \(error.localizedDescription)"
        }
    }
}

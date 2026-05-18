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

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)
        ],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var selectedSheet: ExpenseSheet?
    @State private var showingAddSheet: Bool = false
    @State private var showSettingsView: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let sheet = selectedSheet {
                BudgetyMacSheetView(sheet: sheet)
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
        .onAppear {
            if selectedSheet == nil { selectedSheet = sheets.first }
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
        .toolbar {
            ToolbarItem {
                
            }
            ToolbarItem {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("シートを追加")
            }
        }
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
            if sheet.isOwnedByCurrentUser == false {
                Image(systemName: "person.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

    private let palette: [String] = [
        "#5B8DEF", "#34C759", "#FF9500", "#FF3B30",
        "#AF52DE", "#FF2D55", "#5AC8FA", "#FFCC00"
    ]
    private let symbols: [String] = [
        "person.2.fill", "house.fill", "airplane",
        "cart.fill", "fork.knife", "gift.fill",
        "briefcase.fill", "book.fill"
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("シート名") {
                    TextField("", text: $name)
                }
                Section("カラー") {
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if hex == colorHex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { colorHex = hex }
                        }
                    }
                }
                Section("アイコン") {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(symbols, id: \.self) { s in
                            Button {
                                symbol = s
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(symbol == s
                                              ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                              : AnyShapeStyle(.quaternary))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: s).font(.callout)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("既定通貨") {
                    Picker("通貨", selection: $currencyCode) {
                        ForEach(CurrencyCatalog.all) { opt in
                            Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("完了") { save() }
                    .keyboardShortcut(.return)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
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

// MARK: - Settings

struct BudgetyMacSettingsView: View {
    @StateObject private var profile = UserProfileStore.shared
    @StateObject private var pm = PurchaseManager.shared
    @State private var shareURLText: String = ""
    @State private var acceptInProgress: Bool = false
    @State private var acceptMessage: String?
    @State private var showingPaywall: Bool = false
    @State private var showingProfileEdit: Bool = false

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
                        .foregroundStyle(acceptMessage.contains("失敗") ? .red : .green)
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
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPaywall) {
            MacModalSheet { PaywallView() }
        }
        .sheet(isPresented: $showingProfileEdit) {
            ProfileEditView()
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

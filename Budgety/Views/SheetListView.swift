//
//  SheetListView.swift
//  Expenso
//

import SwiftUI
import CoreData

struct SheetListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var showingAddSheet = false
    @State private var showingSettings = false
    @State private var showingPaywall = false
    @State private var showSyncWaitingAlert = false
    @State private var showOfflineAlert = false
    @State private var path: [NSManagedObjectID] = []
    @State private var didRestorePath = false
    @AppStorage("lastOpenedSheetURI") private var lastOpenedSheetURI: String = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sheets.isEmpty {
                    ContentUnavailableView {
                        Label("シートがありません", systemImage: "person.2")
                    } description: {
                        VStack(spacing: 8) {
                            Text("シートを作成して、家族や友人と支出を共有しましょう。")
                            iCloudStatusBanner()
                        }
                    } actions: {
                        Button {
                            tryShowAddSheet()
                        } label: {
                            Label("シートを作成", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(sheets) { sheet in
                            NavigationLink(value: sheet.objectID) {
                                SheetRowView(record: sheet)
                            }
                        }
                        .onDelete(perform: deleteGroups)
                    }
                }
            }
            .navigationTitle("Budgety")
            .navigationDestination(for: NSManagedObjectID.self) { id in
                if let sheet = try? viewContext.existingObject(with: id) as? ExpenseSheet {
                    LockedSheetGate(record: sheet) {
                        SheetDetailView(record: sheet)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // SettingsView 自身が NavigationStack を持つため、ここを
                    // NavigationLink で push すると nested NavigationStack に
                    // なって 1 回目の push が即座に pop される。
                    // sheet 提示なら SettingsView の内側 NavigationStack が
                    // 独立したコンテキストになり問題なく動く。
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        tryShowAddSheet()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddSheetView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .alert("同期完了を待っています", isPresented: $showSyncWaitingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("iCloud から既存のシートを取得中です。少し待ってからもう一度お試しください。")
            }
            .alert("インターネット接続が必要です", isPresented: $showOfflineAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("シートの新規作成には iCloud との同期が必要です。Wi-Fi またはモバイル通信に接続してから再度お試しください。")
            }
            .onAppear {
                applyDemoLaunch()
                restoreLastOpenedSheetIfNeeded()
            }
            .onChange(of: sheets.count) { _, _ in
                restoreLastOpenedSheetIfNeeded()
            }
            .onChange(of: path) { _, newPath in
                // 末尾のシート URI を覚えておき、次回起動時に復元する
                if let last = newPath.last {
                    lastOpenedSheetURI = last.uriRepresentation().absoluteString
                } else {
                    lastOpenedSheetURI = ""
                }
            }
        }
    }

    /// 前回開いていたシートを起動時に自動で開く。
    /// `sheets` が空 (= CloudKit 初回 import 未完了) の段階では何もせず、
    /// 後から sheets が更新された時点 (`onChange(of: sheets.count)`) に再試行する。
    /// 一度成功したら以後は走らないように `didRestorePath` でガード。
    private func restoreLastOpenedSheetIfNeeded() {
        guard !didRestorePath else { return }
        guard !lastOpenedSheetURI.isEmpty, sheets.first != nil else { return }
        guard let coord = viewContext.persistentStoreCoordinator,
              let url = URL(string: lastOpenedSheetURI),
              let objectID = coord.managedObjectID(forURIRepresentation: url),
              let _ = try? viewContext.existingObject(with: objectID) as? ExpenseSheet
        else {
            // URI 不正 / シートが削除済 → 復元失敗だが以後再試行しない
            didRestorePath = true
            return
        }
        path = [objectID]
        didRestorePath = true
    }

    /// 新しいシートを追加しようとした時のゲート。3 値で分岐:
    /// - `.allowed`: そのまま追加画面を出す
    /// - `.waitingForSync`: CloudKit 初回 import 完了待ち → アラートで「同期待ち」を案内
    /// - `.overLimit`: Free 上限到達 → Paywall を提示
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

    private func applyDemoLaunch() {
        let demo = ProcessInfo.processInfo.environment["EXPENSO_DEMO"]
        switch demo {
        case "addGroup":
            showingAddSheet = true
        case "detail", "addExpense", "share", "editGroup", "editExpense", "calendar", "templates", "stats", "chat":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let first = sheets.first { path = [first.objectID] }
            }
        case "detailGreen":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if sheets.count > 1 { path = [sheets[1].objectID] }
            }
        default:
            break
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        let targets = offsets.map { sheets[$0] }
        Task { @MainActor in
            for sheet in targets {
                if sheet.isOwnedByCurrentUser {
                    viewContext.delete(sheet)
                } else {
                    // 参加シートはローカルだけ purge。オーナー側を削除しない。
                    try? await ShareCoordinator.shared.leaveSharedSheet(sheet)
                }
            }
            PersistenceController.shared.save()
            Haptics.warning()
        }
    }
}

private struct SheetRowView: View {
    @ObservedObject var record: ExpenseSheet
    @StateObject private var lockManager = SheetLockManager.shared

    var body: some View {
        HStack(spacing: 14) {
            SheetIconView(record: record, size: 44)
            Text(record.displayName)
                .font(.headline)
            Spacer()
            if lockManager.hasPassword(for: record) {
                Image(systemName: lockManager.isUnlocked(record) ? "lock.open.fill" : "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// ロック対象シートの開封ゲート。未解錠なら SheetLockView を出し、
/// 解錠後/最初からロック無しなら子コンテンツ (SheetDetailView) を表示。
/// シートから離脱 (= NavigationStack で pop) すると再ロックする。
private struct LockedSheetGate<Content: View>: View {
    @ObservedObject var record: ExpenseSheet
    let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @StateObject private var lockManager = SheetLockManager.shared

    var body: some View {
        Group {
            if lockManager.isUnlocked(record) {
                content()
            } else {
                SheetLockView(
                    record: record,
                    onUnlock: { /* state 更新で自動で content に切替 */ },
                    onCancel: { dismiss() }
                )
            }
        }
        .onDisappear {
            // シート画面から離れたら次回入る時にパスワード再要求
            if lockManager.hasPassword(for: record) {
                lockManager.lock(record)
            }
        }
    }
}

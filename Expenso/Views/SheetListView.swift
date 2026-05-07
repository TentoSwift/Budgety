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
    @State private var path: [NSManagedObjectID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sheets.isEmpty {
                    ContentUnavailableView {
                        Label("シートがありません", systemImage: "person.2")
                    } description: {
                        Text("シートを作成して、家族や友人と支出を共有しましょう。")
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
            .navigationTitle("Expenso")
            .navigationDestination(for: NSManagedObjectID.self) { id in
                if let sheet = try? viewContext.existingObject(with: id) as? ExpenseSheet {
                    SheetDetailView(record: sheet)
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
            .onAppear { applyDemoLaunch() }
        }
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

    var body: some View {
        HStack(spacing: 14) {
            SheetIconView(record: record, size: 44)
            Text(record.displayName)
                .font(.headline)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

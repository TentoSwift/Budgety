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
                            showingAddSheet = true
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
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddSheetView()
            }
            .onAppear { applyDemoLaunch() }
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

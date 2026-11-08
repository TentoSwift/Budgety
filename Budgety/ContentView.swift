import SwiftUI
import CoreData

struct ContentView: View {
    #if os(iOS)
    @State private var coverActive: Bool?
    #endif

    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            Group {
                if let coverActive {
                    DuoSheetsView(coverActive: coverActive)
                } else {
                    SheetListView()
                }
            }
            .onHingeChange { _, context in
                coverActive = context.hinge.map { $0.status == .closed }
            }
        } else {
            SheetListView()
        }
        #else
        SheetListView()
        #endif
    }
}

#if os(iOS)
private struct DuoSheetsView: View {
    let coverActive: Bool
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)])
    private var sheets: FetchedResults<ExpenseSheet>
    @State private var selectedID: NSManagedObjectID?
    @State private var showingLibrary = false

    private var selected: ExpenseSheet? {
        sheets.first { $0.objectID == selectedID } ?? sheets.first
    }

    var body: some View {
        if sheets.isEmpty {
            SheetListView()
        } else if coverActive {
            SheetListView(showsQuickExpense: true)
        } else {
            NavigationSplitView {
                List(sheets, selection: $selectedID) { sheet in
                    Text(sheet.displayName).tag(sheet.objectID)
                }
                .navigationTitle("シート")
                .toolbar {
                    Button("シートを管理", systemImage: "folder.badge.gearshape") { showingLibrary = true }
                }
                .sheet(isPresented: $showingLibrary) { SheetListView() }
            } detail: {
                if let selected {
                    NavigationStack { SheetDetailView(record: selected).sheetLockCover(selected) }
                        .id(selected.objectID)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }
}
#endif

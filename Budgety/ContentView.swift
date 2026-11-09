import SwiftUI
import CoreData

#if os(iOS)
import Darwin

private enum DuoDevice {
    static let isDuo: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
        #else
        var system = utsname()
        guard uname(&system) == 0 else { return false }
        let identifier = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier == "iPhone19,4"
        #endif
    }()
}
#endif

struct ContentView: View {
    var body: some View {
        #if os(iOS)
        if DuoDevice.isDuo {
            GeometryReader { geometry in
                let insets = geometry.safeAreaInsets
                let width = geometry.size.width + insets.leading + insets.trailing
                let height = geometry.size.height + insets.top + insets.bottom
                let expanded = width > height && height >= 600
                DuoSheetsView(compact: !expanded)
                    .environment(\.horizontalSizeClass, expanded ? .regular : .compact)
            }
            .ignoresSafeArea(.keyboard)
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
    let compact: Bool
    @State private var sheetPath: [NSManagedObjectID] = []
    @State private var restoredSelection = false
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)])
    private var sheets: FetchedResults<ExpenseSheet>
    @AppStorage("lastOpenedSheetURI") private var lastOpenedSheetURI = ""
    @AppStorage("iosArchivedSectionExpanded") private var archivedExpanded = false
    @State private var showingSettings = false

    private var selected: ExpenseSheet? {
        sheets.first { $0.objectID == sheetPath.last }
            ?? sheets.first { !$0.archived }
            ?? (archivedExpanded ? sheets.first : nil)
    }

    var body: some View {
        Group {
        if sheets.isEmpty {
            SheetListView()
        } else if compact {
            SheetListView(showsQuickExpense: true, sharedPath: $sheetPath)
        } else {
            NavigationSplitView {
                let archived = sheets.filter { $0.archived }
                List(selection: Binding<NSManagedObjectID?>(
                    get: { selected?.objectID },
                    set: { id in
                        if let id { sheetPath = [id] }
                    }
                )) {
                    ForEach(sheets.filter { !$0.archived }) { sheet in
                        SheetRowView(record: sheet).tag(sheet.objectID)
                    }
                    if !archived.isEmpty {
                        Section {
                            if archivedExpanded {
                                ForEach(archived) { sheet in
                                    SheetRowView(record: sheet).tag(sheet.objectID)
                                }
                            }
                        } header: {
                            ArchivedSheetsHeader(count: archived.count, archivedExpanded: $archivedExpanded)
                        }
                    }
                }
                .listStyle(.plain)
                .animation(.easeInOut(duration: 0.25), value: archivedExpanded)
                .navigationTitle("シート")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        SettingsAvatarButton { showingSettings = true }
                    }
                }
            } detail: {
                if let selected {
                    NavigationStack { SheetDetailView(record: selected).sheetLockCover(selected) }
                        .id(selected.objectID)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .animation(nil, value: compact)
        .onChange(of: sheets.map(\.objectID), initial: true) { _, ids in
            guard !ids.isEmpty else { return }
            if !restoredSelection {
                restoredSelection = true
                if let id = ids.first(where: { $0.uriRepresentation().absoluteString == lastOpenedSheetURI }) {
                    sheetPath = [id]
                }
            }
            sheetPath = sheetPath.filter { ids.contains($0) }
            if !compact, sheetPath.isEmpty, let id = selected?.objectID { sheetPath = [id] }
        }
        .onChange(of: compact) { _, compact in
            if !compact, sheetPath.isEmpty, let id = selected?.objectID { sheetPath = [id] }
        }
        .onChange(of: sheetPath) { _, path in
            lastOpenedSheetURI = path.last?.uriRepresentation().absoluteString ?? ""
        }
    }
}
#endif

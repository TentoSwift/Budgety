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
                DuoSheetsView(compact: !expanded, sidebarWidth: min(320, max(260, geometry.size.width * 0.4)))
                    .environment(\.horizontalSizeClass, expanded ? .regular : .compact)
                    .environment(\.duoExpanded, expanded)
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
extension EnvironmentValues {
    @Entry var duoExpanded: Bool? = nil
}

private struct DuoSheetsView: View {
    let compact: Bool
    let sidebarWidth: CGFloat
    @State private var sheetPath: [NSManagedObjectID] = []
    @State private var restoredSelection = false
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: false)])
    private var sheets: FetchedResults<ExpenseSheet>
    @AppStorage("lastOpenedSheetURI") private var lastOpenedSheetURI = ""
    @AppStorage("iosArchivedSectionExpanded") private var archivedExpanded = false
    @State private var showingSettings = false
    @State private var sidebarHidden = false
    private var showsSidebar: Bool { !compact && !sidebarHidden && !sheetPath.isEmpty }

    var body: some View {
        // The main stack owns the list, pushed detail and any presented editor on both displays.
        HStack(spacing: 0) {
            // A clipped NavigationStack still contributes toolbar items to accessibility.
            // Keep the detail stack in its own stable slot and remove the hidden sidebar.
            if showsSidebar {
                sidebar
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) { Divider() }
            }
            SheetListView(showsQuickExpense: compact, sharedPath: $sheetPath,
                          usesDuoSidebar: !compact, showDuoSidebar: sidebarHidden ? { sidebarHidden = false } : nil)
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onChange(of: sidebarOrderedIDs, initial: true) { previousIDs, ids in
            if !restoredSelection && !ids.isEmpty {
                restoredSelection = true
                let restored = ids.first { $0.uriRepresentation().absoluteString == lastOpenedSheetURI }
                if sheetPath.isEmpty, let id = restored ?? (compact ? nil : firstSidebarSheetID) { sheetPath = [id] }
            } else if let id = sheetPath.last, !ids.contains(id) {
                // Keep the neighboring visible row selected, as in the sidebar.
                // A deleted row must never remain the detail destination.
                let visible = Set(sheets.filter { !$0.archived || archivedExpanded }.map(\.objectID))
                let neighbors = previousIDs.firstIndex(of: id).map { index in
                    Array(previousIDs.dropFirst(index + 1)) + Array(previousIDs.prefix(index).reversed())
                } ?? []
                let replacement = neighbors.first(where: visible.contains) ?? firstSidebarSheetID
                sheetPath = compact ? [] : replacement.map { [$0] } ?? []
            }
        }
    }

    // Keep archived IDs in the ordering even when their section is collapsed:
    // collapsing a section must not look like deleting the selected sheet.
    private var sidebarOrderedIDs: [NSManagedObjectID] {
        sheets.filter { !$0.archived }.map(\.objectID) + sheets.filter(\.archived).map(\.objectID)
    }

    private var firstSidebarSheetID: NSManagedObjectID? {
        (sheets.first { !$0.archived } ?? (archivedExpanded ? sheets.first : nil))?.objectID
    }

    private var sidebar: some View {
        NavigationStack {
            let archived = sheets.filter { $0.archived }
            List(selection: Binding<NSManagedObjectID?>(
                get: { sheetPath.last },
                set: { id in
                    if let id, id != sheetPath.last, sheets.contains(where: { $0.objectID == id && !$0.isDeleted }) {
                        sheetPath = [id]
                    }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SettingsAvatarButton { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("サイドバーを閉じる", systemImage: "sidebar.left") { sidebarHidden = true }
                }
            }
        }
    }
}
#endif

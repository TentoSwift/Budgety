import SwiftUI

extension View {
    @ViewBuilder
    func siriResultPresentation() -> some View {
        #if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
        if #available(iOS 27.3, macOS 27.3, watchOS 26.2, *) {
            modifier(SiriResultPresentation())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(watchOS) || ((os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2))
@available(iOS 27.3, macOS 27.3, watchOS 26.2, *)
private struct SiriResultPresentation: ViewModifier {
    @ObservedObject private var navigation = SiriExpandedNavigation.shared
    @Environment(\.scenePhase) private var phase
    @State private var presented: SiriExpandedSearch?
    #if os(macOS)
    @Environment(\.appearsActive) private var activeWindow
    #endif

    func body(content: Content) -> some View {
        content
            .sheet(item: $presented) { search in
                SiriExpandedTransactionsView(request: search)
            }
            .onChange(of: navigation.request, initial: true) { takeRequest() }
            .onChange(of: phase) { takeRequest() }
            #if os(macOS)
            .onChange(of: activeWindow) { takeRequest() }
            #endif
    }

    private func takeRequest() {
        #if os(macOS)
        guard activeWindow else { return }
        #endif
        guard phase == .active, let search = navigation.request else { return }
        presented = search
        navigation.request = nil
    }
}
#endif

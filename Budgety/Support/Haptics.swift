//
//  Haptics.swift
//  Expenso
//
//  iOS/visionOS では UIFeedbackGenerator、macOS では NSHapticFeedbackManager。
//

#if canImport(UIKit) && !os(visionOS)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum Haptics {
    static func success() {
        #if canImport(UIKit) && !os(visionOS)
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
        #elseif canImport(AppKit)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    static func warning() {
        #if canImport(UIKit) && !os(visionOS)
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
        #elseif canImport(AppKit)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    static func error() {
        #if canImport(UIKit) && !os(visionOS)
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.error)
        #elseif canImport(AppKit)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    static func light() {
        #if canImport(UIKit) && !os(visionOS)
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
        #elseif canImport(AppKit)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    static func medium() {
        #if canImport(UIKit) && !os(visionOS)
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred()
        #elseif canImport(AppKit)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    static func selection() {
        #if canImport(UIKit) && !os(visionOS)
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
        #elseif canImport(AppKit)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }
}

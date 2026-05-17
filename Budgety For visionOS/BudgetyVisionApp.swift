//
//  BudgetyVisionApp.swift
//  Budgety For visionOS
//
//  visionOS 用エントリポイント。iOS 版とほぼ同じ UX を Window で提供する。
//  (没入モードは一旦無し。後で追加する場合は ImmersiveSpace を生やす)
//

import SwiftUI
import CoreData

@main
struct BudgetyVisionApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            BudgetyVisionContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .task {
                    await UserProfileStore.shared.ensureUserRecordNameLoaded()
                }
        }
        .defaultSize(width: 1100, height: 800)
    }
}

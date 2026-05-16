//
//  BudgetyVisionApp.swift
//  Budgety For visionOS
//
//  visionOS 用エントリポイント。Window (シート一覧 / 詳細) + ImmersiveSpace
//  (3D 可視化) の 2 つの Scene を持つ。
//

import SwiftUI
import CoreData

@main
struct BudgetyVisionApp: App {
    // 共有 Core Data コンテナを iOS ターゲットから流用する想定。
    // ターゲット追加時に Budgety/PersistenceController.swift と Models をこの target にも追加する。
    let persistenceController = PersistenceController.shared

    @State private var immersiveSheetID: NSManagedObjectID?

    var body: some Scene {
        WindowGroup(id: "main") {
            BudgetyVisionContentView(immersiveSheetID: $immersiveSheetID)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.locale, Locale(identifier: "ja_JP"))
        }
        .windowStyle(.plain)
        .defaultSize(width: 880, height: 720)

        ImmersiveSpace(id: "budgety-immersive") {
            ImmersiveBudgetView(sheetID: immersiveSheetID)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

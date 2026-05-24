//
//  ExpensoShortcuts.swift
//  Expenso
//
//  AppShortcutsProvider に登録すると、Shortcuts アプリ・Siri・Spotlight に
//  自動的に表示されるアプリショートカット。「Hey Siri、Expenso で支出を追加」
//  のようなフレーズで `AddExpenseIntent` を起動できる。
//

import AppIntents

struct ExpensoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: [
                "\(.applicationName) で支出を追加",
                "\(.applicationName) に記録",
                "Add an expense to \(.applicationName)"
            ],
            shortTitle: "支出を追加",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: QuickBudgetIntent(),
            phrases: [
                "\(.applicationName) で家計簿操作",
                "Run \(.applicationName) command"
            ],
            shortTitle: "クイック家計簿",
            systemImageName: "yensign.circle.fill"
        )
    }
}

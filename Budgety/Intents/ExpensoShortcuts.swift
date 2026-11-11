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
        #if os(iOS) && canImport(AppIntents, _version: 301.2.7.2)
        if #available(iOS 27.3, *) {
            AppShortcut(
                intent: SiriFindMemberTransactionsIntent(),
                phrases: [
                    "\(.applicationName) でメンバーの収支を調べて",
                    "Find a member’s income and expenses in \(.applicationName)"
                ],
                shortTitle: "メンバーの収支",
                systemImageName: "person.crop.circle"
            )
            AppShortcut(
                intent: SiriRecordIncomeIntent(),
                phrases: [
                    "\(.applicationName) で収入を追加",
                    "Add income to \(.applicationName)"
                ],
                shortTitle: "収入を追加",
                systemImageName: "plus.circle"
            )
        }
        #endif
        AppShortcut(
            intent: QuickBudgetIntent(),
            phrases: [
                "\(.applicationName) で MCP",
                "\(.applicationName) で家計簿操作",
                "Run \(.applicationName) command"
            ],
            shortTitle: "Budgety MCP",
            systemImageName: "yensign.circle.fill"
        )
    }
}

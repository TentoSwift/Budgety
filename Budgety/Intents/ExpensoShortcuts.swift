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
        #if os(watchOS)
        AppShortcut(
            intent: WatchRecordLedgerShortcut(),
            phrases: ["\(.applicationName) で \(\.$operation)", "\(.applicationName) で支出を追加", "Add an expense to \(.applicationName)"],
            shortTitle: "支出を追加", systemImageName: "plus.circle.fill"
        )
        #else
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
        #endif
        #if (os(iOS) || os(macOS)) && canImport(AppIntents, _version: 301.2.7.2)
        if #available(iOS 27.3, macOS 27.3, *) {
            AppShortcut(
                intent: SiriBatchAddTransactionsIntent(),
                phrases: ["\(.applicationName) でまとめて追加", "Add multiple transactions to \(.applicationName)"],
                shortTitle: "まとめて追加", systemImageName: "plus.rectangle.on.rectangle"
            )
            AppShortcut(
                intent: SiriBatchEditTransactionsIntent(),
                phrases: ["\(.applicationName) でまとめて編集", "Edit multiple transactions in \(.applicationName)"],
                shortTitle: "まとめて編集", systemImageName: "pencil.and.list.clipboard"
            )
            #if os(macOS)
            AppShortcut(
                intent: SiriFindExpenseCardsIntent(),
                phrases: ["\(.applicationName) で明細を検索", "\(.applicationName) の収支は", "\(.applicationName) で \(\.$period) の収支を調べて",
                          "\(.applicationName) で \(\.$kind) を調べて", "Search transactions in \(.applicationName)"],
                shortTitle: "明細を検索", systemImageName: "magnifyingglass"
            )
            AppShortcut(
                intent: SiriSettlementStatusIntent(),
                phrases: ["\(.applicationName) で精算を確認", "Check settlements in \(.applicationName)"],
                shortTitle: "精算を確認", systemImageName: "arrow.left.arrow.right.circle"
            )
            #endif
        }
        #endif
        #if os(watchOS) || (os(iOS) && canImport(AppIntents, _version: 301.2.7.2))
        if #available(iOS 27.3, watchOS 26.2, *) {
            AppShortcut(
                intent: SiriSettlementStatusIntent(),
                phrases: ["\(.applicationName) で精算を確認", "Check settlements in \(.applicationName)"],
                shortTitle: "精算を確認", systemImageName: "arrow.left.arrow.right.circle"
            )
            AppShortcut(
                intent: SiriSettleSuggestedTransferIntent(),
                phrases: ["\(.applicationName) で精算済みにする", "Mark a transfer as settled in \(.applicationName)"],
                shortTitle: "精算済みにする", systemImageName: "checkmark.circle"
            )
            AppShortcut(
                intent: SiriLogSettlementTransferIntent(),
                phrases: ["\(.applicationName) で送金を記録", "Log a transfer in \(.applicationName)"],
                shortTitle: "送金を記録", systemImageName: "arrow.right.circle"
            )
            AppShortcut(
                intent: SiriEditSettlementTransferIntent(),
                phrases: ["\(.applicationName) で送金を編集", "Edit a transfer in \(.applicationName)"],
                shortTitle: "送金を編集", systemImageName: "pencil.circle"
            )
            #if os(watchOS)
            AppShortcut(
                intent: WatchSheetActionShortcut(),
                phrases: ["\(.applicationName) で \(\.$operation)", "\(.applicationName) でメンバーの収支を調べて",
                          "Find a member’s income and expenses in \(.applicationName)", "\(\.$operation) in \(.applicationName)"],
                shortTitle: "シートの操作", systemImageName: "person.2"
            )
            #else
            AppShortcut(
                intent: SiriFindMemberTransactionsIntent(),
                phrases: [
                    "\(.applicationName) でメンバーの収支を調べて",
                    "Find a member’s income and expenses in \(.applicationName)"
                ],
                shortTitle: "メンバーの収支",
                systemImageName: "person.crop.circle"
            )
            #endif
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
        #if os(watchOS)
        AppShortcut(
            intent: SiriFindExpenseCardsIntent(),
            phrases: [
                "\(.applicationName) で明細を検索",
                "\(.applicationName) で \(\.$period) の支出を調べて",
                "Search transactions in \(.applicationName)"
            ],
            shortTitle: "明細を検索", systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: WatchEditLedgerShortcut(),
            phrases: ["\(.applicationName) で \(\.$operation)", "\(.applicationName) で明細を編集", "Edit a transaction in \(.applicationName)"],
            shortTitle: "明細を編集", systemImageName: "pencil"
        )
        AppShortcut(
            intent: SiriRecurringTransactionIntent(),
            phrases: ["\(.applicationName) で繰り返しを追加", "Add a recurring transaction in \(.applicationName)"],
            shortTitle: "繰り返しを追加", systemImageName: "repeat"
        )
        #else
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
        #endif
    }
}

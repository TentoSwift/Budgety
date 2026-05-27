//
//  ClaudeIntegrationView.swift
//  Budgety
//
//  Claude と Budgety を MCP 経由で連携させるためのワンタップ設定画面。
//  バンドル同梱の .shortcut ファイルを Shortcuts.app に開かせ、続いて
//  MCP server インストール用のコマンドをコピーさせる。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ClaudeIntegrationView: View {
    @State private var copiedKey: String? = nil

    /// バンドル同梱の Shortcut ファイル (要事前 export & Xcode 追加)
    private static let shortcutFileName = "クイック支出追加"

    private static let npmCommand = "npm install -g budgety-mcp"
    private static let claudeMCPAddCommand = "claude mcp add budgety -s user -- budgety-mcp"

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple.gradient)
                            .font(.title2)
                        Text("Claude から支出を記録")
                            .font(.headline)
                    }
                    Text("「コーヒー 350 円を追加」のような自然言語で Claude に頼むと、Budgety に直接記録されます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                stepRow(
                    number: 1,
                    title: "ショートカットを追加",
                    detail: "Budgety 用の Shortcut「クイック支出追加」を Shortcuts.app に追加します。"
                ) {
                    Button {
                        installShortcut()
                    } label: {
                        Label("Shortcuts.app で開く", systemImage: "arrow.up.forward.app.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } footer: {
                Text("Shortcuts.app が開いたら「ショートカットを追加」をタップ。")
                    .font(.caption)
            }

            Section {
                stepRow(
                    number: 2,
                    title: "MCP サーバーをインストール",
                    detail: "Mac のターミナルで以下のコマンドを実行 (Node.js 18+ が必要)。"
                ) {
                    copyableCommand(Self.npmCommand, key: "npm")
                }
            }

            Section {
                stepRow(
                    number: 3,
                    title: "Claude Code に登録",
                    detail: "ターミナルで以下のコマンドを実行。Claude Code を再起動して反映。"
                ) {
                    copyableCommand(Self.claudeMCPAddCommand, key: "claude")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("登録後、Claude Code 内で `mcp__budgety__add_expense` `mcp__budgety__get_expenses` が使えるようになります。")
                    Text("Claude Code 未インストールの場合: `brew install anthropic/cli/claude-code`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Section("使い方の例") {
                exampleRow("今月の支出を見せて", "→ get_expenses(thisMonth)")
                exampleRow("コーヒー 350 円を追加", "→ add_expense(amount: 350, title: \"コーヒー\")")
                exampleRow("昨日のラーメン 1200 円", "→ add_expense(..., date: \"...\")")
            }
        }
        .navigationTitle("Claude と連携")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Subviews

    @ViewBuilder
    private func stepRow<Content: View>(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func copyableCommand(_ command: String, key: String) -> some View {
        Button {
            copy(command, key: key)
        } label: {
            HStack {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copiedKey == key ? .green : .secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.gray.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func exampleRow(_ phrase: String, _ result: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("「\(phrase)」")
                .font(.callout)
            Text(result)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospaced()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    /// バンドル同梱の `.shortcut` ファイルを開いて Shortcuts.app に追加させる。
    private func installShortcut() {
        guard let url = Bundle.main.url(
            forResource: Self.shortcutFileName,
            withExtension: "shortcut"
        ) else {
            // .shortcut が同梱されていない場合は Shortcuts.app だけ開く
            openShortcutsApp()
            return
        }
        openExternal(url)
    }

    private func openShortcutsApp() {
        if let url = URL(string: "shortcuts://") {
            openExternal(url)
        }
    }

    /// プラットフォーム共通の外部 URL オープン。
    /// iOS は UIApplication 経由、macOS は NSWorkspace 経由。
    private func openExternal(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func copy(_ text: String, key: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copiedKey = key
        #if canImport(UIKit)
        // macOS では Haptics モジュールが含まれないので iOS でのみフィードバック。
        Haptics.success()
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedKey == key { copiedKey = nil }
        }
    }
}

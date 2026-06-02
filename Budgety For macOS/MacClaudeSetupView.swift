//
//  MacClaudeSetupView.swift
//  Budgety For macOS
//
//  macOS 用の Claude / MCP 連携セットアップ画面。
//  外部 npm パッケージのインストールは不要で、**アプリ本体 (審査済みバイナリ) を MCP サーバー
//  として Claude Code に登録するだけ** (App Store Guideline 2.4.5(ii) 準拠)。
//  `claude mcp add budgety -- "<app>" --mcp` を表示・コピーさせる。
//

import SwiftUI
import AppKit

struct MacClaudeSetupView: View {
    @State private var copiedKey: String? = nil

    /// Claude Code への登録コマンド。アプリ本体バイナリ (= 実行中のパス) を MCP サーバーとして登録する。
    private var registerCommand: String {
        let path = Bundle.main.executablePath
            ?? "/Applications/Budgety.app/Contents/MacOS/Budgety"
        return "claude mcp add budgety -- \"\(path)\" --mcp"
    }

    private static let claudeInstallCommand = "brew install anthropic/cli/claude-code"

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
                    Text("「コーヒー 350 円を追加」のように自然言語で Claude に頼むと、Budgety に直接記録されます。Budgety アプリ自体が MCP サーバーになるので、追加のインストールは不要です。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                stepRow(
                    number: 1,
                    title: "Claude Code を用意",
                    detail: "未インストールならターミナルで以下を実行 (既に入っていれば不要)。"
                ) {
                    copyableCommand(Self.claudeInstallCommand, key: "brew")
                }
            }

            Section {
                stepRow(
                    number: 2,
                    title: "Budgety を MCP サーバーとして登録",
                    detail: "ターミナルで以下を実行。Budgety アプリ本体をそのまま MCP サーバーとして登録します。"
                ) {
                    copyableCommand(registerCommand, key: "register")
                }
            } footer: {
                Text("登録後、Claude Code を再起動すると `mcp__budgety__add_expense` `mcp__budgety__get_expenses` が使えます。")
                    .font(.caption)
            }

            Section("使い方の例") {
                exampleRow("今月の支出を見せて", "→ get_expenses(thisMonth)")
                exampleRow("コーヒー 350 円を追加", "→ add_expense(amount: 350, title: \"コーヒー\")")
                exampleRow("今日の給料 25万", "→ add_expense(..., kind: \"income\")")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Claude と連携")
        .frame(minWidth: 460, minHeight: 520)
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copiedKey = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if copiedKey == key { copiedKey = nil }
            }
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
            Text("「\(phrase)」").font(.callout)
            Text(result).font(.caption).foregroundStyle(.secondary).monospaced()
        }
        .padding(.vertical, 2)
    }
}

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
                    Text("「コーヒー 350 円を追加」のように自然言語で Claude に頼むと、Budgety に直接記録できます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Budgety アプリ自体が MCP サーバーです。MCP サーバーやその他のソフトウェアを新たにインストールすることはありません。お使いの Claude クライアントに、この Budgety を登録するだけです。", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section {
                copyableCommand(registerCommand, key: "register")
            } header: {
                Text("Claude に Budgety を登録")
            } footer: {
                Text("お使いの Claude クライアント (Claude Code など) で上記コマンドを実行すると、この Budgety アプリ本体が MCP サーバーとして登録されます。新しいソフトウェアはインストールされません。登録後にクライアントを再起動すると mcp__budgety__add_expense / get_expenses / list_categories が使えます。")
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

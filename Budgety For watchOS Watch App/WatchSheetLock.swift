//
//  WatchSheetLock.swift
//  Budgety Watch
//
//  watchOS 版のシートロック UI。
//  - パスワードが設定されているシートを開く前に WatchSheetLockView で入力を求める
//  - 解錠後は子コンテンツ (WatchSheetPage) を表示
//  - 画面から離れたら再ロック (iOS の LockedSheetGate と同じ挙動)
//

import SwiftUI
import WatchKit

/// パスワードロック付きシートの開封ゲート。watch 用。
struct WatchLockedSheetGate<Content: View>: View {
    @ObservedObject var sheet: ExpenseSheet
    @ViewBuilder let content: () -> Content
    @StateObject private var lockManager = SheetLockManager.shared

    var body: some View {
        Group {
            if lockManager.isUnlocked(sheet) {
                content()
            } else {
                WatchSheetLockView(sheet: sheet)
            }
        }
        .onDisappear {
            // 次回開く時にもう一度パスワード要求する
            if lockManager.hasPassword(for: sheet) {
                lockManager.lock(sheet)
            }
        }
    }
}

/// パスワード入力 UI（数字キーパッド）。
/// watchOS の SecureField / TextField は数字のみのパスワードが入力できない（反映
/// されない）ことがあるため、タップ式の数字キーパッドで確実に入力できるようにする。
/// （Apple Watch 標準のパスコード入力と同じ方式。英字を含むパスワードは iPhone 側で
/// 解錠してください。）
struct WatchSheetLockView: View {
    @ObservedObject var sheet: ExpenseSheet
    @StateObject private var lockManager = SheetLockManager.shared

    @State private var password: String = ""
    @State private var errorMessage: String?

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["⌫", "0", "→"],
    ]

    var body: some View {
        // ScrollView は使わない。verticalPage の TabView ページ内では ScrollView が
        // レイアウトされず中身が表示されないことがあるため。画面いっぱいに収め、
        // キーパッドが残りの高さを埋めるようにする。
        VStack(spacing: 3) {
            Text(sheet.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // 入力状況を 1 行で表示 (未入力=案内 / 入力中=● / エラー=赤)。
            // 行を固定にしてレイアウトがずれないようにする。
            Text(statusText)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
            // 数字キーパッド: 4 行で残りの高さを均等に埋める。
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(sheet.tint.opacity(0.25).gradient, for: .navigation)
    }

    /// 入力状況の 1 行表示 (案内 / ● / エラー)。
    private var statusText: String {
        if let errorMessage { return errorMessage }
        return password.isEmpty ? "パスワードを入力" : String(repeating: "●", count: password.count)
    }
    private var statusColor: Color {
        if errorMessage != nil { return .red }
        return password.isEmpty ? .secondary : .primary
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        Button {
            handle(key)
        } label: {
            Group {
                switch key {
                case "⌫": Image(systemName: "delete.left.fill")
                case "→": Image(systemName: "lock.open.fill")
                default:  Text(key).font(.body)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(key == "→" ? sheet.tint : .gray)
        .disabled(key == "→" && password.isEmpty)
    }

    private func handle(_ key: String) {
        errorMessage = nil
        switch key {
        case "⌫": if !password.isEmpty { password.removeLast() }
        case "→": attemptUnlock()
        default:  password.append(key)
        }
    }

    private func attemptUnlock() {
        guard !password.isEmpty else { return }
        if lockManager.unlock(sheet, withPassword: password) {
            WKInterfaceDevice.current().play(.success)
            password = ""
            errorMessage = nil
        } else {
            WKInterfaceDevice.current().play(.failure)
            errorMessage = "パスワードが違います"
            password = ""
        }
    }
}

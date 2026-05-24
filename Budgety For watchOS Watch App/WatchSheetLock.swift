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
        ScrollView {
            VStack(spacing: 8) {
                Text(sheet.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // 入力済みは伏せ字（●）で桁数だけ表示。未入力時は案内。
                Text(password.isEmpty ? "パスワードを入力" : String(repeating: "●", count: password.count))
                    .font(password.isEmpty ? .caption2 : .title3)
                    .foregroundStyle(password.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(minHeight: 22)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { key in
                            keyButton(key)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(sheet.tint.opacity(0.25).gradient, for: .navigation)
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
                default:  Text(key).font(.title3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
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

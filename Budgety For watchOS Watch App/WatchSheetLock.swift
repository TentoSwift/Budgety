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
        // 注意: 以前は `Group { if/else }.onDisappear { lock }` だったが、Group に付けた
        // modifier は各ブランチに適用されるため、解錠してロック画面ブランチが消える
        // 瞬間に onDisappear が発火し即再ロックされ、解錠しても支出が表示されなかった。
        // 再ロックは WatchHomeView 側でシート切替 (onChange) を見て行う。
        if lockManager.isUnlocked(sheet) {
            content()
        } else {
            WatchSheetLockView(sheet: sheet)
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
        // GeometryReader で実際の表示領域を測り、3 列 × 4 行のキーパッドが画面ちょうどに
        // 収まるようボタン寸法を算出する。ScrollView は使わない (verticalPage TabView
        // 内では中身が表示されないことがあるため)。シート名はナビバーのタイトルに出して
        // 本文はステータス行 + キーパッドだけにし、キーパッドの面積を最大化する。
        GeometryReader { geo in
            let spacing: CGFloat = 6
            let statusHeight: CGFloat = 22
            let rowCount = CGFloat(rows.count)            // 4
            let buttonWidth = (geo.size.width - spacing * 2) / 3
            // ボタン高さ = 「均等割り」と「幅の 0.72 倍」の小さい方。大きい画面で
            // ボタンが縦長・巨大になりすぎないよう上限を設け、余りは上下中央寄せで吸収。
            let evenHeight = (geo.size.height - statusHeight - spacing * rowCount) / rowCount
            let buttonHeight = max(20, min(evenHeight, buttonWidth * 0.72))
            VStack(spacing: spacing) {
                // 入力状況を 1 行で表示 (未入力=案内 / 入力中=● / エラー=赤)。
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(height: statusHeight)
                Spacer(minLength: 0)
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(row, id: \.self) { key in
                            keyButton(key, width: buttonWidth, height: buttonHeight)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .navigationTitle(sheet.displayName)
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
    private func keyButton(_ key: String, width: CGFloat, height: CGFloat) -> some View {
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
        .frame(width: width, height: height)
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

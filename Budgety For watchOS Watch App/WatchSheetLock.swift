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

/// パスワード入力 UI。SecureField で watch のスクリブル / 音声入力経由で入力可。
struct WatchSheetLockView: View {
    @ObservedObject var sheet: ExpenseSheet
    @StateObject private var lockManager = SheetLockManager.shared

    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(sheet.tint)
                    .padding(.top, 4)
                Text(sheet.displayName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("パスワードを入力")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // watchOS では textContentType(.password) を付けると Keychain の
                // AutoFill 経路になりキーボード入力ができない（入力が反映されない）。
                // 付けずに通常入力（キーボード/手書き/音声）で受け付けるようにする。
                SecureField("パスワード", text: $password)
                    .submitLabel(.go)
                    .onSubmit(attemptUnlock)
                Button {
                    attemptUnlock()
                } label: {
                    Label("解錠", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(sheet.tint)
                .disabled(password.isEmpty)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
        }
        .containerBackground(sheet.tint.opacity(0.25).gradient, for: .navigation)
    }

    private func attemptUnlock() {
        let ok = lockManager.unlock(sheet, withPassword: password)
        if ok {
            WKInterfaceDevice.current().play(.success)
            password = ""
            errorMessage = nil
        } else {
            WKInterfaceDevice.current().play(.failure)
            errorMessage = "パスワードが違います"
        }
    }
}

//
//  SheetLockView.swift
//  Budgety
//
//  ロック済みシートを開く時に表示するパスワード入力モーダル。
//  パスワードは数字のみなので、タップ式の数字キーパッドで入力する
//  (watchOS の WatchSheetLockView と同じ方式)。
//  Face ID / Touch ID が有効な場合は生体認証も提案する。
//

import SwiftUI

struct SheetLockView: View {
    let record: ExpenseSheet
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @State private var password: String = ""
    @State private var shake: Bool = false
    @State private var errorMessage: String?
    @State private var displayUnlocked: Bool = false

    @StateObject private var lockManager = SheetLockManager.shared

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["⌫", "0", "→"],
    ]

    var body: some View {
        VStack(spacing: 20) {
            // Hero
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.15))
                        .frame(width: 84, height: 84)
                    Image(systemName: displayUnlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(record.displayName)
                    .font(.title3.bold())
                Text("このシートはロックされています")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            // 入力済みの桁数を伏せ字 (●) で表示。未入力時は案内。
            passwordDots
                .offset(x: shake ? -6 : 0)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // 数字キーパッド
            VStack(spacing: 16) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 28) {
                        ForEach(row, id: \.self) { key in
                            keyButton(key)
                        }
                    }
                }
            }
            .padding(.top, 4)

            // Biometric option
            if lockManager.isBiometricEnabled(for: record) {
                Button {
                    Task { await tryBiometric() }
                } label: {
                    Label("Face ID / Touch ID で開く", systemImage: "faceid")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }

            Spacer()

            Button("キャンセル") { onCancel() }
                .padding(.bottom, 24)
        }
        .background(Color.platformSystemBackground)
        .onAppear {
            // 起動時に自動で生体認証を試す
            if lockManager.isBiometricEnabled(for: record) {
                Task { await tryBiometric() }
            }
        }
    }

    @ViewBuilder
    private var passwordDots: some View {
        if password.isEmpty {
            Text("パスワードを入力")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 28)
        } else {
            Text(String(repeating: "●", count: password.count))
                .font(.title2)
                .kerning(6)
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(height: 28)
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        Button {
            handle(key)
        } label: {
            ZStack {
                Circle().fill(keyBackground(key))
                keyLabel(key)
                    .foregroundStyle(keyForeground(key))
            }
            .frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
        .disabled(key == "→" && password.isEmpty)
    }

    @ViewBuilder
    private func keyLabel(_ key: String) -> some View {
        switch key {
        case "⌫": Image(systemName: "delete.left").font(.title2)
        case "→": Image(systemName: "lock.open.fill").font(.title2.weight(.semibold))
        default:  Text(key).font(.title.weight(.regular))
        }
    }

    private func keyBackground(_ key: String) -> Color {
        switch key {
        case "⌫": return .clear
        case "→": return password.isEmpty ? Color.platformSecondarySystemBackground : tint
        default:  return Color.platformSecondarySystemBackground
        }
    }

    private func keyForeground(_ key: String) -> Color {
        switch key {
        case "→": return password.isEmpty ? .secondary : .white
        default:  return .primary
        }
    }

    private func handle(_ key: String) {
        errorMessage = nil
        switch key {
        case "⌫": if !password.isEmpty { password.removeLast() }
        case "→": tryUnlock()
        default:  password.append(key)
        }
    }

    private var tint: Color {
        Color(hex: record.colorHex ?? "#5B8DEF") ?? .blue
    }

    private func tryUnlock() {
        guard !password.isEmpty else { return }
        if lockManager.verify(record, password: password) {
            Haptics.success()
            finishUnlock()
        } else {
            errorMessage = "パスワードが違います"
            withAnimation(.spring(response: 0.2, dampingFraction: 0.35)) {
                shake = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                shake = false
            }
            password = ""
            Haptics.warning()
        }
    }

    private func tryBiometric() async {
        // verifyBiometric は解錠状態を変更しないので、アニメーション完了後に
        // setUnlocked + onUnlock を呼ぶ。これで親 (LockedSheetGate) の即時切替を回避。
        if await lockManager.verifyBiometric(record) {
            Haptics.success()
            finishUnlock()
        }
    }

    /// パスワード検証成功時の共通処理: アニメーションを見せてから親へ完了を通知。
    private func finishUnlock() {
        displayUnlocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            lockManager.setUnlocked(record)
            onUnlock()
        }
    }
}

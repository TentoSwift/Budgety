//
//  MacSheetLockView.swift
//  Budgety For macOS
//
//  macOS 版のシートロック解除画面。
//  iOS のタップ式数字キーパッド (SheetLockView) ではなく、物理キーボードで
//  入力できるよう SecureField を使う。Return で解錠。
//  Touch ID が有効なシートでは生体認証ボタンも出す (対応 Mac のみ)。
//

import SwiftUI

struct MacSheetLockView: View {
    let record: ExpenseSheet
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var displayUnlocked: Bool = false
    @FocusState private var fieldFocused: Bool

    @StateObject private var lockManager = SheetLockManager.shared

    private var tint: Color {
        Color(hex: record.colorHex ?? "#5B8DEF") ?? .blue
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

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
                    .font(.title2.bold())
                Text("このシートはロックされています")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // パスワード入力 (キーボード)。Return で解錠。
            VStack(spacing: 8) {
                SecureField("パスワードを入力", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .focused($fieldFocused)
                    .onSubmit { attemptUnlock() }
                    .onChange(of: password) { _, _ in errorMessage = nil }

                Text(errorMessage ?? " ")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .opacity(errorMessage == nil ? 0 : 1)
            }

            Button {
                attemptUnlock()
            } label: {
                Text("解錠")
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)

            // Touch ID (有効時のみ)。
            if lockManager.isBiometricEnabled(for: record) {
                Button {
                    Task { await tryBiometric() }
                } label: {
                    Label("Touch ID で開く", systemImage: "touchid")
                }
                .buttonStyle(.link)
            }

            Spacer()

            Button("キャンセル") { onCancel() }
                .padding(.bottom, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            fieldFocused = true
            // 起動時に自動で Touch ID を試す (有効時のみ)。
            if lockManager.isBiometricEnabled(for: record) {
                Task { await tryBiometric() }
            }
        }
    }

    private func attemptUnlock() {
        guard !password.isEmpty else { return }
        if lockManager.verify(record, password: password) {
            Haptics.success()
            finishUnlock()
        } else {
            errorMessage = "パスワードが違います"
            password = ""
            fieldFocused = true
            Haptics.warning()
        }
    }

    private func tryBiometric() async {
        // verifyBiometric は解錠状態を変えないので、アニメーション後に setUnlocked する。
        if await lockManager.verifyBiometric(record) {
            Haptics.success()
            finishUnlock()
        }
    }

    /// 検証成功時の共通処理: 解錠アニメーションを見せてから親へ完了を通知。
    private func finishUnlock() {
        displayUnlocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            lockManager.setUnlocked(record)
            onUnlock()
        }
    }
}

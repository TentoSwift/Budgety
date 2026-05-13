//
//  SheetLockView.swift
//  Budgety
//
//  ロック済みシートを開く時に表示するパスワード入力モーダル。
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
    @FocusState private var focused: Bool

    @StateObject private var lockManager = SheetLockManager.shared

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

            // Password field
            SecureField("パスワード", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal, 16)
                .offset(x: shake ? -6 : 0)
                .onSubmit { tryUnlock() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Unlock button
            Button {
                tryUnlock()
            } label: {
                Text("ロックを解除")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .padding(.horizontal, 16)
            .disabled(password.isEmpty)

            // Biometric option
            if lockManager.isBiometricEnabled(for: record) {
                Button {
                    Task { await tryBiometric() }
                } label: {
                    Label("Face ID / Touch ID で開く", systemImage: "faceid")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("キャンセル") { onCancel() }
                .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .onAppear {
            focused = true
            // 起動時に自動で生体認証を試す
            if lockManager.isBiometricEnabled(for: record) {
                Task { await tryBiometric() }
            }
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

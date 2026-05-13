//
//  SetSheetPasswordView.swift
//  Budgety
//
//  シートにパスワードを設定/変更/削除する画面。Premium 機能。
//

import SwiftUI
import LocalAuthentication

struct SetSheetPasswordView: View {
    let record: ExpenseSheet

    @Environment(\.dismiss) private var dismiss
    @StateObject private var lockManager = SheetLockManager.shared

    @State private var currentPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var enableBiometric: Bool = true
    @State private var errorMessage: String?
    @State private var showRemoveConfirm: Bool = false
    /// hero の SF Symbol を `lock.open.fill` ↔ `lock.fill` で切替するための表示用フラグ。
    /// 保存成功時に true へ切り替え、`symbolEffect(.replace)` でアニメーション後に dismiss する。
    @State private var displayLocked: Bool = false

    private var hasExistingPassword: Bool {
        lockManager.hasPassword(for: record)
    }

    private var biometricSupported: Bool {
        let ctx = LAContext()
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private var biometricLabel: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID で開けるようにする"
        case .touchID: return "Touch ID で開けるようにする"
        case .opticID: return "Optic ID で開けるようにする"
        default: return "生体認証で開けるようにする"
        }
    }

    var body: some View {
        if !record.isOwnedByCurrentUser {
            notOwnerView
        } else {
            ownerForm
        }
    }

    /// 非オーナー向け。CloudKit Share の参加者はパスワードを共有して開錠することはできるが、
    /// 設定/変更/解除はできない。
    private var notOwnerView: some View {
        Form {
            Section {
                hero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Label("このシートのオーナーのみがパスワードを設定・変更できます。",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("シートロック")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var ownerForm: some View {
        Form {
            Section {
                hero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            // 既存ロック済シートの場合: 生体認証 ON/OFF を独立トグルで即時切替できるようにする。
            // (パスワード再入力なしで Face ID だけ ON にしたいケースに対応)
            if hasExistingPassword, biometricSupported {
                Section {
                    Toggle(biometricLabel, isOn: Binding(
                        get: { lockManager.isBiometricEnabled(for: record) },
                        set: { lockManager.setBiometricEnabled($0, for: record) }
                    ))
                } header: {
                    Text("生体認証")
                } footer: {
                    Text("オンにするとパスワードを入力しなくてもこの端末で素早く開けます。生体認証が失敗した場合はパスワードで開けます。")
                }
            }

            if hasExistingPassword {
                Section {
                    SecureField("現在のパスワード", text: $currentPassword)
                        .textContentType(.password)
                } header: {
                    Text("本人確認")
                } footer: {
                    Text("変更や解除には現在のパスワードが必要です。")
                }
            }

            Section {
                SecureField("新しいパスワード", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("確認用パスワード (もう一度)", text: $confirmPassword)
                    .textContentType(.newPassword)
            } header: {
                Text(hasExistingPassword ? "パスワードを変更" : "パスワードを設定")
            } footer: {
                Text("4 文字以上の任意の文字列。忘れるとシートを再ロックできなくなる以外の影響はありませんが、念のため安全な場所に控えておくことを推奨します。")
            }

            // 新規ロック設定時: パスワード設定と同時に生体認証を有効化するかの選択
            if !hasExistingPassword, biometricSupported {
                Section {
                    Toggle(biometricLabel, isOn: $enableBiometric)
                } footer: {
                    Text("生体認証が失敗した場合はパスワードで開けます。")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(hasExistingPassword ? "変更を保存" : "ロックを設定",
                          systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .disabled(!canSave)
            }

            if hasExistingPassword {
                Section {
                    Button(role: .destructive) {
                        showRemoveConfirm = true
                    } label: {
                        Label("ロックを解除", systemImage: "lock.open.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(currentPassword.count < 4)
                } footer: {
                    Text("解除には上で入力した現在のパスワードが必要です。")
                }
            }
        }
        .navigationTitle(hasExistingPassword ? "シートロック" : "シートロックを設定")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("ロックを解除しますか?", isPresented: $showRemoveConfirm) {
            Button("解除", role: .destructive) {
                removeLock()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("「\(record.displayName)」のパスワードロックを解除します。現在のパスワードを入力してから実行してください。")
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: displayLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(record.displayName)
                .font(.headline)
            Text(displayLocked
                 ? "現在パスワードで保護されています"
                 : "パスワードでこのシートを保護します")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .onAppear { displayLocked = hasExistingPassword }
    }

    private var tint: Color {
        Color(hex: record.colorHex ?? "#5B8DEF") ?? .blue
    }

    private var canSave: Bool {
        guard newPassword.count >= 4, newPassword == confirmPassword else { return false }
        // 既存ロックがある場合は現在のパスワードも 4 文字以上 (実検証は save 時)
        if hasExistingPassword { return currentPassword.count >= 4 }
        return true
    }

    private func save() {
        guard record.isOwnedByCurrentUser else {
            errorMessage = "このシートのオーナーのみが変更できます。"
            return
        }
        guard newPassword.count >= 4, newPassword == confirmPassword else {
            errorMessage = "パスワードが一致しないか、短すぎます。"
            return
        }
        if hasExistingPassword {
            guard lockManager.unlock(record, withPassword: currentPassword) else {
                errorMessage = "現在のパスワードが違います。"
                currentPassword = ""
                Haptics.warning()
                return
            }
        }
        lockManager.setPassword(newPassword, for: record, enableBiometric: enableBiometric)
        Haptics.success()
        // 鍵が閉まる symbolEffect(.replace) のアニメーションを見せてから閉じる。
        // .replace のデフォルト所要時間は約 0.5〜0.6 秒なので 1.1 秒待ってから dismiss。
        // (withAnimation で囲んでも contentTransition のタイミングは変わらないので不要)
        displayLocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            dismiss()
        }
    }

    private func removeLock() {
        guard record.isOwnedByCurrentUser else {
            errorMessage = "このシートのオーナーのみが解除できます。"
            return
        }
        guard lockManager.unlock(record, withPassword: currentPassword) else {
            errorMessage = "現在のパスワードが違います。"
            currentPassword = ""
            Haptics.warning()
            return
        }
        lockManager.clearPassword(for: record)
        Haptics.success()
        // 鍵が開くアニメーションを見せてから閉じる
        displayLocked = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            dismiss()
        }
    }
}

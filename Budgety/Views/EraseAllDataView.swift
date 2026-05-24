//
//  EraseAllDataView.swift
//  Budgety
//
//  「全データを削除」専用画面。設定から push 遷移してここで実行する。
//  事故防止のため、以下の二重ガードを設ける:
//    1. 2 段階の確認アラート (削除する → 本当に削除する)
//    2. ロックされたシートが 1 つでもあれば、削除前に各シートのパスワード解錠を必須にする
//       (= ロックを知っている本人だけが全消去できる)
//

import SwiftUI
import CoreData

struct EraseAllDataView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var showFirstConfirm = false
    @State private var showSecondConfirm = false

    /// 削除前に解錠が必要なロック済みシート (全て解錠できたら削除実行)。
    @State private var lockedSheets: [ExpenseSheet] = []
    @State private var unlockIndex = 0
    @State private var showPasswordGate = false

    /// 画面表示用: 現在ロックされているシート件数。
    @State private var lockedCount = 0
    @State private var isErasing = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("すべてのデータを削除します")
                        .font(.headline)
                    Text("シート・支出・カテゴリ・メンバー・繰り返し項目・テンプレート・プロフィール (名前 / 写真 / 色)・設定 (シートロック等) を含む全データを削除し、アプリを初期状態に戻します。自分が作成した共有は解除され、iCloud 上のデータからも削除されます。受信した共有シートはオーナー側のデータには影響しません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("この操作は元に戻せません。")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 4)
            }

            if lockedCount > 0 {
                Section {
                    Label {
                        Text("ロックされたシートが \(lockedCount) 件あります。削除するには、それぞれのパスワードを入力する必要があります。")
                    } icon: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                }
            }

            Section {
                Button(role: .destructive) {
                    showFirstConfirm = true
                } label: {
                    if isErasing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("削除中…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("全データを削除", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isErasing)
            }
        }
        .navigationTitle("全データを削除")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { lockedCount = fetchLockedSheets().count }
        // 1 段目の確認
        .alert("全データを削除しますか?", isPresented: $showFirstConfirm) {
            Button("削除する", role: .destructive) {
                // アラートを連続表示すると 1 段目の dismiss と競合するため次の runloop へ。
                DispatchQueue.main.async { showSecondConfirm = true }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("シート・支出・プロフィール・設定を含む全データを削除します。")
        }
        // 2 段目の確認
        .alert("本当に削除しますか?", isPresented: $showSecondConfirm) {
            Button("完全に削除", role: .destructive) { beginErase() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は元に戻せません。削除後はアプリを再起動してください。")
        }
        // ロック解錠ゲート (ロック済みシートがある場合のみ)
        .fullScreenCover(isPresented: $showPasswordGate) {
            passwordGate
        }
    }

    /// ロック済みシートを 1 件ずつ解錠させるゲート。全て解錠したら削除を実行する。
    @ViewBuilder
    private var passwordGate: some View {
        if unlockIndex < lockedSheets.count {
            let sheet = lockedSheets[unlockIndex]
            SheetLockView(
                record: sheet,
                subtitle: gateSubtitle,
                onUnlock: { advanceUnlock() },
                onCancel: { cancelGate() }
            )
            // シートが切り替わるたびにキーパッドの入力状態をリセットする。
            .id(sheet.objectID)
        } else {
            // 想定外 (空) の場合は安全側に閉じる。
            Color.clear.onAppear { showPasswordGate = false }
        }
    }

    private var gateSubtitle: String {
        lockedSheets.count > 1
            ? "全データ削除のためロックを解除 (\(unlockIndex + 1)/\(lockedSheets.count))"
            : "全データ削除のためロックを解除してください"
    }

    // MARK: - Actions

    private func beginErase() {
        let sheets = fetchLockedSheets()
        lockedSheets = sheets
        unlockIndex = 0
        // アラートの dismiss と競合しないよう、提示/実行は次の runloop へ。
        DispatchQueue.main.async {
            if sheets.isEmpty {
                performErase()
            } else {
                showPasswordGate = true
            }
        }
    }

    private func advanceUnlock() {
        if unlockIndex + 1 < lockedSheets.count {
            unlockIndex += 1
        } else {
            showPasswordGate = false
            // カバーを閉じてから削除を実行 (UI 競合回避)。
            DispatchQueue.main.async { performErase() }
        }
    }

    private func cancelGate() {
        showPasswordGate = false
        lockedSheets = []
        unlockIndex = 0
    }

    private func performErase() {
        guard !isErasing else { return }
        isErasing = true
        Task { @MainActor in
            Haptics.warning()
            await PersistenceController.shared.eraseAllData()
            isErasing = false
            dismiss()
        }
    }

    /// パスワードロックが設定されているシートを取得する (hash + salt の両方を確認)。
    private func fetchLockedSheets() -> [ExpenseSheet] {
        let req = NSFetchRequest<ExpenseSheet>(entityName: "ExpenseSheet")
        req.predicate = NSPredicate(format: "lockPasswordHash != nil AND lockPasswordHash != ''")
        let sheets = (try? viewContext.fetch(req)) ?? []
        return sheets.filter { SheetLockManager.shared.hasPassword(for: $0) }
    }
}

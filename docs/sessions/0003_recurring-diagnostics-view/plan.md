# 0003_recurring-diagnostics-view — 実装計画

- ブランチ: `feature/recurring-diagnostics-view`
- 日付: 2026-06-02
- 関連 PR: (作成後に記入) / 前提: #262, #263 (定期項目リファクタ)

## 目的
定期項目 (RecurringRule) が正しく動作しているか確認するための **読み取り専用 診断ビュー**。
編集済み・削除済みの occurrence を可視化したい、というユーザー要望。

## 設計 (挙動変更なし)
現状、生成済み occurrence の削除はハード削除で記録が残らない。そこで **「ルールが期待する
occurrence 列 (drift-free 計算) × 実在する Expense 行」を突き合わせて状態を推定**する:
- 正常   : 期待日に行があり値もルールと一致
- 編集済み: 期待日に行があるが値がルールと異なる (override) — 違うフィールド名を表示
- 削除済み: 期待日 (≤ lastGeneratedDate) に行が無い (= 生成後に削除された)
- 重複   : 同じ予定日に行が 2 件以上 (= 冪等が破れている異常検知)
- 想定外 : 期待列に無い予定日の行 (startDate/間隔の変更後の取り残し等)

挙動は一切変えない (削除は従来どおり hard delete のまま、tombstone 化しない)。

## 変更
- 新規 `Budgety/Views/RecurringDiagnosticsView.swift`: 全 RecurringRule を一覧、ルールごとに
  上記ステータスをサマリ＋明細表示 (新しい順、最大80件)。
- `Budgety/Views/SettingsView.swift`: `BuildInfo.isInternalBuild` (DEBUG/TestFlight) 限定で
  「デバッグ」セクションに「定期項目の診断」への NavigationLink を追加。
- **iOS 限定**: SettingsView は iOS 専用ターゲット (macOS 例外セットに無い) なので、新規ビューも
  iOS のみに入る。macOS/visionOS/watchOS のターゲット membership 変更は不要。

## 動作確認
- [x] iOS `** BUILD SUCCEEDED **`
- [x] macOS `** BUILD SUCCEEDED **` (両ファイルとも iOS 専用＝macOS は不変、回帰なしを確認)
- App Store 版では非表示 (`isInternalBuild == false`)。

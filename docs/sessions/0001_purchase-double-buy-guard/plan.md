# 0001_purchase-double-buy-guard — 実装計画

- ブランチ: `fix/purchase-double-buy-guard`
- 日付: 2026-05-29
- 関連 PR: (作成後に記入)

## 目的 / 背景
買い切り (`premium.lifetime`, 非消耗型) とサブスク (月額/年額) を併売している。
Apple ネイティブでは買い切り×サブスクの相互排他は不可（非消耗型はサブスクリプション
グループに入れられない）。アプリ内の排他は `PaywallView` の UI ゲートに依存しており、
`PurchaseManager.purchase()` 自体にはガードが無かった。

## 変更方針
- 変更ファイル: `Budgety/PurchaseManager.swift`
- `purchase(_:)` の先頭で `guard !isPremium else { return false }` を追加し、
  既に Premium 所有時はモデル層でも購入を弾く（防御的多重化）。

## 手順
- [x] 1. `purchase(_:)` にガード追加
- [x] 2. ビルド確認
- [ ] 3. PR 作成 (base: develop)

## リスク・注意点
- `isPremium` は DEBUG の `EXPENSO_PREMIUM=1` を含む。プレミアム擬似ON中は購入も
  弾かれるが、その状態で実購入をテストすることは無いので許容。
- UI ゲート (`PaywallView.swift:26, 215`) は従来どおり維持。今回はその裏当て。

## 動作確認
- [x] ビルド (iOS Simulator)
- [ ] 実機操作スクショ: 不要（購入フローの見た目変更なし、ガードは不可視）

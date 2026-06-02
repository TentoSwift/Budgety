# 0004_recurring-virtualization — 実装計画

- ブランチ: `feature/recurring-virtualization`
- 日付: 2026-06-02
- 関連 PR: (作成後に記入) / 前提: #262, #263, #264
- 方針転換: ハイブリッド(生成して保存) → **完全仮想化(保存せず、表示時にルールから算出してマージ)**。
  ユーザーの当初からの希望「Expenses に増やさず定期項目から表示」を実装する。

## 最終形
- 定期 occurrence は **Expense として保存しない**。一覧・合計・割り勘・グラフ・MCP取得を
  表示/計算するたびに、ルールから occurrence を算出して実支出にマージして見せる。
- **例外だけ実体化**（実 Expense 行、キー `(generatedFromRuleID, scheduledDate)`）:
  - 単発編集 = override 行（編集後の値を保存）
  - 単発削除 = skip tombstone（`isSkipped = true`）
  - 「今後」編集 = ルール分割（旧 `endDate` を編集日で打ち切り + 新ルールを編集日から）
- **マージ条件**: その `(ruleID, scheduledDate)` に実在行がある日付は仮想を出さない
  （= 既存の生成済み行・override・skip を尊重）。FX は現行レート（凍結なし、合意済み）。

## 安全な切替順（各段階で壊れない）
- [ ] **Phase 1: マージ基盤**（挙動変更なし）
  - 値型 `RecurringOccurrence`（ルールから派生: date/amount/title/kind/category/payer/beneficiaries/currency）。
  - `RecurringOccurrenceService.virtualOccurrences(for:in:includeFuture:)`: 各ルールの occurrence を
    算出し、実在行がある日付を除外して返す。
  - 誰も呼ばない段階＝無影響。iOS/macOS ビルド確認。
- [ ] **Phase 2: consumer に仮想を合流**（generator はまだ実体化中なので、過去=実行・未来のみ仮想＝二重計上なし）
  - SettlementCalculator（割り勘・カテゴリ集計）＝**最難所**。`sheet.expenses` のループに加えて
    仮想 occurrence も同じロジックで集計（payer/beneficiaries/現行FX）。
  - 一覧（SheetDetailView 165/964 など）＝実 Expense と仮想を結合した表示配列に。
  - 合計/グラフ（StatsView, StatsInsightsGenerator）/ MCP get（QuickIntentLogic.get）/ エクスポート（SheetExporter）。
  - 各 consumer が属するターゲット（macOS/visionOS）に `RecurringOccurrenceService` を追加（pbxproj 例外セット）。
- [ ] **Phase 3: generator の実体化を停止**（ここで実際に仮想へ切替）
  - `generateAll` の行作成を停止（起動/前面/保存トリガを撤去 or no-op 化）。既存の生成済み行は
    残す（非破壊）。past=実行(legacy)・future=仮想 のクリーン・カットオーバー。
  - （任意・別判断）未編集の legacy 生成行を削除して過去も仮想化する「フルクリーン移行」は
    破壊的＋過去 split が現行FXで再計算されるため、まず非破壊で進める。
- [ ] **Phase 4: 例外（編集/削除/今後）**
  - 仮想 occurrence をタップ→編集 = その場で override 行に実体化して保存。
  - 仮想 occurrence を削除 = skip tombstone 行を作成。
  - 「今後」= ルール分割。3択ダイアログを新モデルに載せ替え。
- [ ] **Phase 5: 診断ビュー(#264)更新 + 全ターゲットビルド**
  - 診断ビューを「仮想/実行/override/skip」を反映する形に更新。
  - iOS / macOS / watchOS / visionOS すべて `BUILD SUCCEEDED` 確認。

## リスク・注意点
- **Core Data / @FetchRequest との相性**: 仮想は managed object ではないため、SwiftUI 一覧は
  @FetchRequest 結果と仮想配列を結合した union を描画する必要がある（リストの作り替え）。
- **精算が核**: payer/beneficiary 正規化・FX・カテゴリ集計のロジックを仮想にも適用する。バグを入れやすい。
- **マルチターゲット**: 新規ファイル/利用は macOS・visionOS の例外セット追記が必要。各フェーズで
  iOS だけでなく macOS（必要なら visionOS）もビルド確認（#262→#263 の教訓）。
- **見た目**: ユーザー画面はほぼ不変（一覧に定期支出が出るのは同じ）。違いは内部。
- **チェックポイント**: Phase 1 完了で一旦報告。Phase 2（精算含む invasive）着手前に確認。

## 動作確認
- [ ] 各フェーズで iOS / macOS ビルド
- [ ] Phase 5 で4ターゲット全ビルド
- [ ] 診断ビューで重複ゼロ・仮想/実行の区別を確認

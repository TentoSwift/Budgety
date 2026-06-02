# 0002_recurring-virtual-occurrences — 実装計画

- ブランチ: `feature/recurring-virtual-occurrences`
- 日付: 2026-06-02
- 関連 PR: (作成後に記入)

## 目的 / 背景
定期項目 (RecurringRule) の現行実装には次の問題がある（調査: 本セッション）:
1. **マルチデバイス重複生成（最重大）**: 生成は各端末の起動/前面復帰で独立に走り、進捗は
   `lastGeneratedDate` だけ。`(ruleID, date)` の存在チェックが無く、CloudKit 同期前に
   別端末が同じ回を生成すると重複する。
2. **月末ドリフト**: `nextDate = 前回生成日 + interval` の積み上げで、1/31→2/28→3/28…と
   31日が永久に28日へずれる。
3. **編集セマンティクスが場当たり**: 「この項目のみ/今後/全て」を generatedFromRuleID 一括
   fetch で再実装しており、各 occurrence に予定日アンカーが無いため「今後」が曖昧。

## 決定事項（ユーザー確認済み 2026-06-02）
- 方向: **定期は「ルールを真実とし、例外だけ実体化」する設計**（iCalendar の RRULE +
  override/EXDATE と同型）に作り替える。最終形は完全仮想化を志向するが、序盤フェーズは
  ハイブリッド（期日到来で実体化）と共通なので共通核を先に作り、表示方式の分岐は Phase 3 に隔離。
- **FX 方針**: 定期 occurrence は **凍結しない（現行レート）**。通常支出は従来どおり
  `captureFXSnapshot()` で凍結。実装規則 = 「`generatedFromRuleID != nil` の行は
  スナップショットを取らない」。精算は既存の「スナップショット無し→現行FXフォールバック」
  (`SettlementCalculator` 262-267) にそのまま乗るため無改修。

## 設計概要
- **occurrence キー** = `(ruleID, scheduledDate)`。`scheduledDate` は予定スロット日（不変）。
- **例外 = 実体化した Expense 1行**:
  - オーバーライド（単発編集）: 値を持つ実 Expense（`generatedFromRuleID` + `scheduledDate` セット）。
  - スキップ（単発削除）: `isSkipped = true` の tombstone 行（同キー）。
  - 「同キーの実行が在れば、その日付の occurrence は出さない」=重複/削除を1規則で統一。
    CloudKit のマージにも強い（モデル側に別フラグ集合を持たない）。
- **drift 修正**: occurrence 日付は `startDate + n×interval`（基準日アンカー）で各回独立に算出。
  クランプしても基準日（例: 31日）に復帰する。
- **編集モデル**:
  - 全体 → ルールを変更。
  - 今後のみ → **ルール分割**: `oldRule.endDate = 編集日`、`newRule = コピー＋新値, startDate = 編集日`。
    過去は旧ルールのまま、行を量産しない（O(1)）。
  - 単発編集 → その occurrence を override 行として実体化。
  - 単発削除 → skip tombstone 行。

## モデル変更（Phase 1）
`Expense` エンティティに追加（いずれも optional = CloudKit 加算スキーマで後方互換）:
- `scheduledDate: Date?` — occurrence スロット日。
- `isSkipped: Bool`（optional/既定 false）— 単発削除の tombstone。
- マイグレーション: 既存の `generatedFromRuleID != nil` 行は `scheduledDate = date` をバックフィル
  （= 既に実体化済みの履歴として扱い、再生成を抑制）。既存の FX スナップショットはそのまま温存
  （履歴は書き換えない。新規定期分のみ凍結しない）。

## フェーズ
- [x] Phase 0: ブランチ + plan.md/prompt.md（本コミット）
- [ ] Phase 1 **共通核（低リスク・両方式共通）**
  - [ ] モデルに `scheduledDate` / `isSkipped` 追加 + バックフィル
  - [ ] `RecurringOccurrenceService`: ルール→occurrence 日付列（drift-free）＋同キー実体化の抑制
  - [ ] `RecurringExpenseGenerator` を冪等化（同キー存在ならスキップ）＋ drift 修正
  - [ ] 定期 occurrence は `captureFXSnapshot()` を呼ばない
  - [ ] ビルド確認
  - → この時点で重複・ドリフトは解消
- [ ] Phase 2 **編集モデル**
  - [ ] 今後のみ = ルール分割、単発 = override、単発削除 = skip tombstone
  - [ ] `EditRecurringRuleView` / `AddExpenseView` の3択を新モデルへ載せ替え
  - [ ] ビルド確認
- [ ] Phase 3 **表示方式（分岐・ユーザー確認ポイント）**
  - 案A ハイブリッド: 期日到来で実体化を継続（generateAll 維持）。occurrence service は
    「今後の予定」プレビューのみ。改修最小。
  - 案B 完全仮想化: 自動実体化を止め、読み取り点（SheetDetailView 一覧 165/964・
    `SettlementCalculator`・`QuickIntentLogic.get` 319・カテゴリ集計）に仮想 occurrence を
    マージ。データは最クリーンだが精算含む改修大。
  - [ ] 着手前にユーザーと最終確認

## リスク・注意点
- **CloudKit**: 追加属性はすべて optional → 既存スキーマと後方互換。`NSPersistentCloudKitContainer`
  はユニーク制約不可なので、重複防止は「冪等 upsert＋収束 dedup（同キー重複は最小 recordName/UUID を
  正として残し他を削除＝全端末が同じ勝者に収束）」で担保。
- **既存生成済み行**: 破壊しない。`scheduledDate` バックフィルで再生成だけ抑制。
- **精算 FX**: 新規定期は現行レート、過去の既存行は凍結済みのまま（混在を許容＝履歴非改変）。
- **perf**: occurrence 日付算出は算術のみで軽量。

## 動作確認
- [ ] ビルド (iOS Simulator)
- [ ] シミュレータ操作スクショ（定期作成→展開、編集3択、削除・スキップ）※操作時は各ステップ撮影
- [ ] 重複シナリオ（同キー二重生成が起きないこと）
- [ ] 精算が定期 occurrence を現行FXで正しく取り込むこと

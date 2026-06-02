# 0002_recurring-virtual-occurrences — やりとり要点

> 生トランスクリプトはコピペしない。後から検索したい要点だけ。

## 効いた指示 / 決定
- 「実装方法を変える。改善点は？」→ 現行定期項目を調査し問題点を提示。
- 重大度順: ①マルチデバイス重複生成（`(ruleID,date)` 存在チェック無し）②月末ドリフト
  ③編集セマンティクスが場当たり。
- ユーザー提案: 「Expenses に増やさず定期項目から表示。編集は 全体=ルール変更／今後=過去を
  保存して以降変更／単発・削除=その分だけ保存し重複しないようモデルに記録」
  → これは calendar の RRULE+override パターンそのもの。採用。
- FX 方針確定: **定期は凍結しない（現行レート）／通常支出は従来どおり凍結**。

## 方針転換
- 当初「今後のみ=過去を実体化」案 → **ルール分割（旧 endDate を編集日で打ち切り＋新ルール）**
  の方が行を量産せず綺麗、と洗練。
- override/skip は別フラグ群でなく「occurrence キー付き実 Expense 1行」に一本化
  （CloudKit マージ耐性）。
- 完全仮想化は精算が各 Expense の凍結 FX を合算する設計（`SettlementCalculator` 262-267）と
  衝突する点を実測指摘 → ただし「定期は凍結しない」決定で現行FXフォールバックに乗るため、
  ハイブリッド（期日 materialize）が最小コストで成立。序盤共通・分岐は Phase 3 に隔離。

## ハマった点と解決
- Phase 1 で生成を「materialized 集合に無ければ作る」だけにした結果、生成済み
  occurrence を**単発削除すると次回生成で復活する**リグレッションが発生。
  → Phase 2 で `lastGeneratedDate` 下限 (floor) を復活させ「floor 以下は再生成しない」
  ようにして解決（削除を尊重）。冪等は materialized 集合、削除尊重は floor、と役割分担。
- シミュレータ動作確認は **シート作成が iCloud サインイン必須**でブロック（方針上
  サインインしない）。`CODE_SIGNING_ALLOWED=NO` のコンパイル専用ビルドは CloudKit
  エンタイトルメント欠落で `CKContainer` init が EXC_BREAKPOINT する点も確認
  （実行するなら署名付きビルドが必要）。ユーザー判断でシミュレータ確認は中止。

## 学び（→ MEMORY.md 反映候補）
- 定期項目の冪等化キー = `(ruleID, scheduledDate)`。`NSPersistentCloudKitContainer` は
  ユニーク制約不可 → 冪等 upsert＋収束 dedup で担保。
  → memory: budgety_recurring_design.md（実装確定後に作成）

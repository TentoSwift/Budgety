# セッション記録 (docs/sessions/)

機能開発ごとに「実装計画」と「やりとりの要点」を残すディレクトリ。
出典: daikimkw「大規模プロダクトでのAI実装」
(speakerdeck.com/daikimkw/implementing-ai-in-large-scale-products)

## ディレクトリ構成

```
docs/sessions/
├── README.md          ← この説明
├── _template/         ← コピー元の雛形
│   ├── plan.md
│   └── prompt.md
└── NNNN_feature-name/
    ├── plan.md        ← 実装計画
    └── prompt.md      ← やりとり履歴（要点のみ）
```

## 命名規則

- `NNNN` … 4桁連番。次番号 = 既存の最大番号 + 1（例: 0001, 0002, …）
- `feature-name` … git ブランチ名から `feature/` を除いた名前に合わせる
  （例: ブランチ `feature/recurring-split` → `0001_recurring-split`）

## 各ファイルの役割

### plan.md — 実装計画
作業を始める前（ブランチを切るタイミング）に書く。
目的 / 背景・変更するファイルと方針・手順（チェックリスト）・リスク・動作確認。

### prompt.md — やりとり履歴（要点のみ）
**生のトランスクリプトはコピペしない。** 全文は Claude Code の `.jsonl` に残るので重複する。
ここには「効いた指示」「方針転換」「ハマった点と解決」など、
後から検索したい要点だけを残す。

## 運用ルール

1. 機能着手時に `_template/` をコピーして `NNNN_feature-name/` を作り、plan.md を書く
2. 作業中、重要な判断や方針転換があれば prompt.md に追記
3. タスク終了時、永続的な学び・設計判断があれば
   `~/.claude/.../memory/` の memory ファイル + MEMORY.md にも反映する
   （→ memory: `budgety_session_workflow.md`）
4. コミットは feature ブランチで、その機能の PR に含める

## コミットするかどうか
このディレクトリはリポジトリにコミットして履歴に残す前提。
コミットしたくない場合は `.gitignore` に `docs/sessions/` を追加する。

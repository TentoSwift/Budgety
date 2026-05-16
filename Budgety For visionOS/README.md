# Budgety For visionOS

visionOS 用ターゲットのソース一式。**pbxproj へのターゲット定義は Xcode UI から追加する必要があります**（コードジェンが入っていないため）。

## Xcode UI でのセットアップ手順

### 1. visionOS ターゲットを追加

1. Xcode で `Budgety.xcodeproj` を開く
2. プロジェクトナビゲータ → プロジェクト名（青いアイコン）を選択
3. 左下「+」→ **Add Target...**
4. visionOS タブ → **App** を選択 → Next
5. 設定値：
   - Product Name: `Budgety For visionOS`
   - Team / Organization Identifier: iOS と同じ
   - Bundle Identifier: `com.tento.budgety.vision`（または好み）
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Initial Scene: **Window**（後で Immersive 追加するので何でも可）
   - Include Tests: お好み
6. Finish

### 2. 自動生成された雛形ファイルを削除

新ターゲット生成時に作られる `ContentView.swift` `BudgetyVisionOSApp.swift` 等は不要なので削除（または上書きされるので無視）。

### 3. このディレクトリのファイルをターゲットに追加

`Budgety For visionOS/` 配下の以下ファイルを **新しい visionOS ターゲットの Compile Sources** に追加：

- `BudgetyVisionApp.swift`
- `BudgetyVisionContentView.swift`
- `BudgetyVisionSheetView.swift`
- `ImmersiveBudgetView.swift`

Info.plist / Assets.xcassets / Preview Content も new target の **Build Settings** から指す（Xcode が自動でやる場合あり）。

### 4. 共有ファイルをターゲットに追加

iOS ターゲット用に書かれた以下も visionOS ターゲットで使うため、各ファイルの **File Inspector → Target Membership** で `Budgety For visionOS` にチェックを入れる：

**Models**
- `Budgety/Models/Expense+Extensions.swift`
- `Budgety/Models/ExpenseSheet+Extensions.swift`
- `Budgety/Models/Member+Extensions.swift`
- `Budgety/Models/ExpenseCategory+Extensions.swift`
- `Budgety/Models/ParticipantProfile+Extensions.swift`
- `Budgety/Models/RecurringRule+Extensions.swift`
- `Budgety/Models/TransactionKind.swift`
- `Budgety/Models/CategorySeeds.swift`

**Stores / Support**
- `Budgety/PersistenceController.swift`
- `Budgety/UserProfileStore.swift`
- `Budgety/ShareCoordinator.swift`
- `Budgety/Support/Currency.swift`
- `Budgety/Support/Color+Hex.swift`
- `Budgety/Support/Notifications.swift`
- `Budgety/Support/BuildInfo.swift`
- `Budgety/Support/SettlementCalculator.swift`（任意）
- `Budgety/Expenso.xcdatamodeld`（CoreData モデル — 必須）

依存があるものは Xcode のエラーを見て随時 Target Membership を増やす。

### 5. Capabilities

visionOS ターゲットの **Signing & Capabilities** で：
- **iCloud** → CloudKit にチェック、コンテナ `iCloud.com.tento.budgety` を選択
- **Background Modes** → Remote notifications

### 6. Run

Run Destinations から **Apple Vision Pro (Simulator)** を選んでビルド → 実行。

---

## 構成

| ファイル | 役割 |
|---|---|
| `BudgetyVisionApp.swift` | `@main` App。Window + ImmersiveSpace の 2 Scene |
| `BudgetyVisionContentView.swift` | NavigationSplit でシート一覧 + 詳細 |
| `BudgetyVisionSheetView.swift` | シート詳細。月合計、カテゴリ別棒グラフ、最近の支出、Immersive 起動ボタン |
| `ImmersiveBudgetView.swift` | RealityKit で支出を 3D オービット球として可視化 |

## 機能

- **Window モード**: 通常の家計簿 UI（シート一覧 + 詳細サマリ）
- **没入モード**: 「没入モードで可視化」を押すと前方 1.5m に：
  - 中央リング + 月合計テキスト
  - 各支出を **カテゴリ別の高さレーン + 軌道上の球** として配置
  - 球サイズ = 金額の対数スケール、色 = カテゴリ tint
  - ゆっくり Y 軸回転、SpatialTap で球がパルス
- iOS 版とデータ共有（同じ Core Data + CloudKit コンテナ）

## カスタマイズ余地

- `ImmersiveBudgetView.buildScene` でレイアウトを変更
- カテゴリごとに 3D シンボル（コイン、紙幣、レシート）を `generatePlane` + テクスチャに置換
- `pulse()` を選択ハイライト → 詳細パネル表示に拡張
- 月間推移を時間軸として螺旋状に配置

//
//  AppTips.swift
//  Budgety
//
//  Created by Tento Ishino on 2026/07/02.
//  Copyright © 2026 Tento Ishino. All rights reserved.
//
//  TipKit を使った「気づきにくい便利機能」の紹介。
//  各 Tip は初回表示後に自動で invalidate される標準挙動でよい。
//  文言は日本語 (ソース言語)。英訳は Localizable.xcstrings 側で管理する。
//

import TipKit

// MARK: - フィルタ (シート詳細)

/// シート詳細の検索バー横にあるフィルタボタンの紹介。
/// カテゴリ / 人 / 受益者 / 割り勘 で絞り込めることに気づきにくいため。
struct FilterTip: Tip {
    var title: Text {
        Text("まとめて絞り込み")
    }

    var message: Text? {
        Text("カテゴリ・人・受益者・割り勘でシートの項目を素早く絞り込めます。")
    }

    var image: Image? {
        Image(systemName: "line.3.horizontal.decrease")
    }
}

// MARK: - レシートスキャン (支出追加)

/// 支出追加画面のレシート読み取り (カメラ / 写真ライブラリ) の紹介。
/// メニューに畳まれていて気づきにくいため。
struct ReceiptScanTip: Tip {
    var title: Text {
        Text("レシートから自動入力")
    }

    var message: Text? {
        Text("レシートを撮影・選択すると、金額や日付を自動で読み取って入力できます。")
    }

    var image: Image? {
        Image(systemName: "text.viewfinder")
    }
}

// MARK: - もっと見る メニュー (シート詳細)

/// シート詳細の「…」メニューの紹介。
/// AI チャット・精算・統計・エクスポートなど主要機能がここに集約されているが、
/// アイコンだけでは中身が伝わりにくいため。
struct MoreMenuTip: Tip {
    var title: Text {
        Text("便利な機能はこちら")
    }

    var message: Text? {
        Text("AI チャットや精算・統計・エクスポートなどの機能をここから開けます。")
    }

    var image: Image? {
        Image(systemName: "ellipsis.circle")
    }
}

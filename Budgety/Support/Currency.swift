//
//  Currency.swift
//  Expenso
//

import Foundation

struct CurrencyOption: Identifiable, Hashable {
    let code: String
    let displayName: String
    let symbol: String

    var id: String { code }
}

enum CurrencyCatalog {
    /// アプリで選択可能な通貨。先頭は JPY。
    ///
    /// 注意: 為替レート提供元 frankfurter.dev (ECB 由来) が対応していない通貨を
    /// ここに含めると換算ができず合計から落ちる。TWD / VND は ECB が公表していないので
    /// 含めない。既存データに TWD / VND が残っていても option(for:) のフォールバックで
    /// 表示は維持される。
    static let all: [CurrencyOption] = [
        .init(code: "JPY", displayName: "日本円",     symbol: "¥"),
        .init(code: "USD", displayName: "米ドル",     symbol: "$"),
        .init(code: "EUR", displayName: "ユーロ",     symbol: "€"),
        .init(code: "GBP", displayName: "英ポンド",   symbol: "£"),
        .init(code: "CHF", displayName: "スイスフラン", symbol: "CHF"),
        .init(code: "CNY", displayName: "人民元",     symbol: "¥"),
        .init(code: "KRW", displayName: "韓国ウォン",  symbol: "₩"),
        .init(code: "HKD", displayName: "香港ドル",   symbol: "HK$"),
        .init(code: "SGD", displayName: "シンガポールドル", symbol: "S$"),
        .init(code: "AUD", displayName: "豪ドル",     symbol: "A$"),
        .init(code: "CAD", displayName: "加ドル",     symbol: "C$"),
        .init(code: "NZD", displayName: "NZドル",     symbol: "NZ$"),
        .init(code: "THB", displayName: "タイバーツ",  symbol: "฿"),
        .init(code: "IDR", displayName: "インドネシアルピア", symbol: "Rp"),
        .init(code: "INR", displayName: "インドルピー", symbol: "₹"),
        .init(code: "PHP", displayName: "フィリピンペソ", symbol: "₱"),
        .init(code: "MXN", displayName: "メキシコペソ", symbol: "$"),
        .init(code: "BRL", displayName: "ブラジルレアル", symbol: "R$"),
        .init(code: "MYR", displayName: "マレーシアリンギット", symbol: "RM"),
        .init(code: "SEK", displayName: "スウェーデンクローナ", symbol: "kr"),
        .init(code: "NOK", displayName: "ノルウェークローネ", symbol: "kr"),
        .init(code: "DKK", displayName: "デンマーククローネ", symbol: "kr"),
        .init(code: "PLN", displayName: "ポーランドズウォティ", symbol: "zł"),
        .init(code: "CZK", displayName: "チェココルナ",   symbol: "Kč"),
        .init(code: "HUF", displayName: "ハンガリーフォリント", symbol: "Ft"),
        .init(code: "RON", displayName: "ルーマニアレウ", symbol: "lei"),
        .init(code: "BGN", displayName: "ブルガリアレフ", symbol: "лв"),
        .init(code: "ISK", displayName: "アイスランドクローナ", symbol: "kr"),
        .init(code: "TRY", displayName: "トルコリラ",     symbol: "₺"),
        .init(code: "ILS", displayName: "イスラエルシェケル", symbol: "₪"),
        .init(code: "ZAR", displayName: "南アフリカランド", symbol: "R")
    ]

    /// ピッカー表示用の並び。システムの地域の通貨を先頭に出す。
    /// (地域の通貨が対応一覧に無ければ既定の並び = JPY 先頭のまま)
    static var allOrderedByLocale: [CurrencyOption] {
        guard let code = Locale.current.currency?.identifier,
              let idx = all.firstIndex(where: { $0.code == code }) else {
            return all
        }
        var list = all
        list.insert(list.remove(at: idx), at: 0)
        return list
    }

    /// 設定で明示選択された既定通貨を保存する UserDefaults キー。
    /// 空文字 / 未設定なら "自動 (システムの地域)" を意味する。
    static let preferredCurrencyKey = "preferredDefaultCurrency"

    /// アプリの既定通貨コード。
    /// 1. 設定でユーザーが明示選択した通貨があればそれを使う
    /// 2. なければシステムの地域設定 (`Locale.current.currency`) から判定
    /// 3. それも未対応なら JPY
    static var defaultCode: String {
        let supported = Set(all.map(\.code))
        if let override = UserDefaults.standard.string(forKey: preferredCurrencyKey),
           !override.isEmpty, supported.contains(override) {
            return override
        }
        return localeDefaultCode
    }

    /// 設定の override を無視した、システムの地域設定由来の既定通貨。
    /// 設定画面の「自動」表示に使う。
    static var localeDefaultCode: String {
        let supported = Set(all.map(\.code))
        if let id = Locale.current.currency?.identifier, supported.contains(id) {
            return id
        }
        return "JPY"
    }

    static func option(for code: String) -> CurrencyOption {
        all.first { $0.code == code } ?? .init(code: code, displayName: code, symbol: code)
    }

    static func format(_ amount: Decimal, code: String) -> String {
        amount.formatted(.currency(code: code).locale(Locale.current))
    }

    /// 通貨の小数桁数 (JPY / KRW = 0、USD / EUR 等 = 2)。
    /// watchOS の金額入力ステップや表示桁数の判定に使う。
    static func fractionDigits(for code: String) -> Int {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return f.maximumFractionDigits
    }

    static func formatPlain(_ amount: Decimal, code: String) -> String {
        let opt = option(for: code)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ja_JP")
        let n = f.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
        return "\(opt.symbol)\(n)"
    }
}

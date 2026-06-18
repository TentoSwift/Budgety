//
//  FXRatesService.swift
//  Expenso
//
//  毎日 1 回 frankfurter.dev (ECB 公式由来、API key 不要) から為替レートを取得し、
//  ローカルにキャッシュする。換算 API は同期で計算する。
//

import Foundation
import Combine

@MainActor
final class FXRatesService: ObservableObject {
    static let shared = FXRatesService()

    @Published private(set) var rates: [String: Decimal] = [:]   // 1 base = X target
    @Published private(set) var baseCurrency: String = "USD"
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastRateDate: String?            // ECB 発表日 (YYYY-MM-DD)
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastError: String?

    private let cacheFile: URL
    private let symbols = "AUD,BGN,BRL,CAD,CHF,CNY,CZK,DKK,EUR,GBP,HKD,HUF,IDR,ILS,INR,ISK,JPY,KRW,MXN,MYR,NOK,NZD,PHP,PLN,RON,SEK,SGD,THB,TRY,USD,ZAR"

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheFile = dir.appendingPathComponent("fx_rates.json")
        loadFromDisk()
    }

    /// アプリ起動時 / フォアグラウンド復帰時に呼ぶ。当日中なら何もしない。
    func refreshIfStale() async {
        if let last = lastUpdated, Calendar.current.isDateInToday(last) { return }
        await refresh()
    }

    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        let urlString = "https://api.frankfurter.dev/v1/latest?base=\(baseCurrency)&symbols=\(symbols)"
        guard let url = URL(string: urlString) else {
            lastError = String(localized: "URL の構築に失敗しました")
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = String(localized: "為替サーバから応答がありません")
                return
            }
            let decoded = try JSONDecoder().decode(Frankfurter.self, from: data)
            self.rates = decoded.rates
            self.lastRateDate = decoded.date
            self.lastUpdated = .now
            saveToDisk()
        } catch {
            lastError = String(localized: "為替の取得に失敗しました: \(error.localizedDescription)")
        }
    }

    /// 任意の通貨間で金額を換算する。レートが無い場合は nil。
    func convert(_ amount: Decimal, from: String, to: String) -> Decimal? {
        if from == to { return amount }
        let fromRate: Decimal = (from == baseCurrency) ? 1 : (rates[from] ?? 0)
        let toRate: Decimal = (to == baseCurrency) ? 1 : (rates[to] ?? 0)
        guard fromRate > 0, toRate > 0 else { return nil }
        return amount * toRate / fromRate
    }

    /// 換算可能かどうか。両方がベース通貨か、両方のレートがキャッシュにあれば可。
    func canConvert(from: String, to: String) -> Bool {
        if from == to { return true }
        let fromOK = (from == baseCurrency) || (rates[from] ?? 0) > 0
        let toOK = (to == baseCurrency) || (rates[to] ?? 0) > 0
        return fromOK && toOK
    }

    // MARK: - Persistence

    private struct Cache: Codable {
        let base: String
        let rates: [String: Decimal]
        let lastUpdated: Date
        let date: String?
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return
        }
        baseCurrency = cache.base
        rates = cache.rates
        lastUpdated = cache.lastUpdated
        lastRateDate = cache.date
    }

    private func saveToDisk() {
        let cache = Cache(base: baseCurrency, rates: rates, lastUpdated: lastUpdated ?? .now, date: lastRateDate)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: [.atomic])
    }

    // MARK: - Frankfurter response

    private struct Frankfurter: Decodable {
        let amount: Decimal
        let base: String
        let date: String
        let rates: [String: Decimal]
    }
}

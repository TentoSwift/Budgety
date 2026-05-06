//
//  CategoryAISuggestor.swift
//  Expenso
//
//  ユーザーが入力した支出/収入のタイトルから、シート内のカテゴリ一覧の中で
//  最も適切なものを FoundationModels (iOS 26+ オンデバイス LLM) で推測する。
//  端末で利用できなければ `nil` を返す。
//

import Foundation
import FoundationModels

/// LLM の出力。指定リスト内の名前そのものを返してもらう。
@Generable
struct CategoryGuess {
    @Guide(description: "提供されたカテゴリ一覧の中から、タイトルに最も適切な 1 つの名前。リストに無い場合は空文字。憶測しないこと。")
    var categoryName: String
}

enum CategoryAISuggestor {
    /// FoundationModels が利用可能か。
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// タイトルからカテゴリを推測する。
    /// - Parameters:
    ///   - title: ユーザー入力の支出/収入タイトル
    ///   - kind: "支出" / "収入"
    ///   - categories: 候補カテゴリ名 (シート内の同 kind のもの)
    /// - Returns: 一致したカテゴリ名。マッチしない / 利用不可 / エラーで `nil`。
    static func suggest(title: String, kind: TransactionKind, categories: [String]) async -> String? {
        guard isAvailable else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !categories.isEmpty else { return nil }

        let listing = categories
            .enumerated()
            .map { "  [\($0.offset)] \($0.element)" }
            .joined(separator: "\n")

        let instructions = """
        あなたは家計簿アプリのカテゴリ分類アシスタントです。
        ユーザーが入力した支出/収入のタイトルから、与えられたカテゴリリストの
        **中だけ**から 1 つを選んで返します。

        絶対ルール:
        - 出力 categoryName は **必ずリストにある名前そのもの** をコピーする。
        - リストに無い名前を作らない / 翻訳しない / 改変しない。
        - 適切なものが無い場合は空文字 "" を返す。
        - 種別 (支出 / 収入) に合うカテゴリだけを候補から選ぶ。
        """

        let prompt = """
        以下のカテゴリリストの中から、入力タイトルに最も適切な 1 つの名前を選んでください。

        種別: \(kind.label)
        入力タイトル: \(trimmed)

        カテゴリリスト (この中から選ぶこと):
        \(listing)

        最適なものが無ければ "" を返してください。
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: CategoryGuess.self)
            let raw = response.content.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            // 厳密一致 → 大文字/小文字 + 全角/半角空白を正規化したマッチも許容する
            if categories.contains(raw) { return raw }
            let normalize: (String) -> String = {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased()
            }
            let target = normalize(raw)
            return categories.first(where: { normalize($0) == target })
        } catch {
            #if DEBUG
            print("⚠️ CategoryAISuggestor: failed: \(error)")
            #endif
            return nil
        }
    }
}

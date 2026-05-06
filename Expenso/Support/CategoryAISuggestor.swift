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

        let instructions = """
        あなたは家計簿アプリのカテゴリ分類アシスタントです。
        ユーザーが入力した支出/収入のタイトルから、提供されたカテゴリ一覧の中で
        最も適切なものを 1 つだけ選んでください。

        ルール:
        - 必ず提供された一覧の文字列を **そのまま** 返すこと (大文字小文字も同じ)。
        - 一覧に含まれない名前は決して返さない。
        - どれも明確に当てはまらない場合は空文字を返す。
        - 種別 (支出 / 収入) に合うカテゴリだけ候補から選ぶ。
        """

        let prompt = """
        種別: \(kind.label)
        タイトル: \(trimmed)
        利用可能なカテゴリ:
        \(categories.map { "- \($0)" }.joined(separator: "\n"))
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: CategoryGuess.self)
            let raw = response.content.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            // LLM がリスト外の名前を返したらフィルタアウト
            guard !raw.isEmpty, categories.contains(raw) else { return nil }
            return raw
        } catch {
            #if DEBUG
            print("⚠️ CategoryAISuggestor: failed: \(error)")
            #endif
            return nil
        }
    }
}

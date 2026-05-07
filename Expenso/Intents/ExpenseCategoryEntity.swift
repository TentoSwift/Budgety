//
//  ExpenseCategoryEntity.swift
//  Expenso
//
//  AppIntents で「カテゴリ」を選ぶための AppEntity ラッパー。
//  Core Data の `ExpenseCategory` を objectID URI で安定識別する。
//  Shortcuts 編集時にユーザーが任意で選べるようにし、未指定なら
//  FoundationModels で推測する経路に流す。
//

import AppIntents
import CoreData

struct ExpenseCategoryEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "カテゴリ")
    }
    static var defaultQuery = ExpenseCategoryEntityQuery()

    var id: String
    var name: String
    var sheetName: String
    var kindRaw: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(sheetName)"
        )
    }
}

struct ExpenseCategoryEntityQuery: EntityQuery {
    @MainActor
    func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        let ctx = PersistenceController.shared.container.viewContext
        let req = NSFetchRequest<ExpenseCategory>(entityName: "ExpenseCategory")
        req.sortDescriptors = [
            NSSortDescriptor(keyPath: \ExpenseCategory.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \ExpenseCategory.createdAt, ascending: true)
        ]
        // 支出カテゴリのみを候補として表示 (= AddExpenseIntent は支出専用)
        req.predicate = NSPredicate(format: "kindRaw == %@ OR kindRaw == nil OR kindRaw == ''",
                                    TransactionKind.expense.rawValue)
        let cats = (try? ctx.fetch(req)) ?? []
        return cats.map { ExpenseCategoryEntity.from($0) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExpenseCategoryEntity] {
        let pc = PersistenceController.shared
        let ctx = pc.container.viewContext
        var result: [ExpenseCategoryEntity] = []
        for idStr in identifiers {
            guard let url = URL(string: idStr),
                  let oid = pc.container.persistentStoreCoordinator
                    .managedObjectID(forURIRepresentation: url),
                  let cat = try? ctx.existingObject(with: oid) as? ExpenseCategory
            else { continue }
            result.append(ExpenseCategoryEntity.from(cat))
        }
        return result
    }
}

extension ExpenseCategoryEntity {
    @MainActor
    static func from(_ cat: ExpenseCategory) -> ExpenseCategoryEntity {
        ExpenseCategoryEntity(
            id: cat.objectID.uriRepresentation().absoluteString,
            name: cat.displayName,
            sheetName: cat.sheet?.displayName ?? "",
            kindRaw: cat.kindRaw ?? TransactionKind.expense.rawValue
        )
    }
}

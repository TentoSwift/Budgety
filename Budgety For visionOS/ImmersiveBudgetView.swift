//
//  ImmersiveBudgetView.swift
//  Budgety For visionOS
//
//  Immersive Space で支出をオービット (軌道) 上に 3D の球として配置する。
//  - 中央: 月予算 (or 月累計) を示すリングと総計ラベル
//  - オービット: カテゴリごとに高さを変え、球のサイズ = 金額の対数スケール
//  - タップで球をハイライト + 情報パネル (Window 側で表示)
//
//  RealityKit + SwiftUI (RealityView) を使用。
//

import SwiftUI
import RealityKit
import CoreData

struct ImmersiveBudgetView: View {
    @Environment(\.managedObjectContext) private var viewContext

    let sheetID: NSManagedObjectID?

    var body: some View {
        RealityView { content in
            content.add(buildScene())
        } update: { content in
            // sheetID 変化時に再構築
            content.entities.removeAll()
            content.add(buildScene())
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    pulse(entity: value.entity)
                }
        )
    }

    // MARK: - Scene

    @MainActor
    private func buildScene() -> Entity {
        let root = Entity()
        root.name = "BudgetyRoot"
        // ユーザーの少し前 (-1.5m), 目の高さやや下 (-0.2m) に配置
        root.position = SIMD3<Float>(0, -0.2, -1.5)

        // 中央の総計リング
        if let center = centerRing() {
            root.addChild(center)
        }

        // 各 expense を軌道上の球として配置
        for entity in expenseEntities() {
            root.addChild(entity)
        }

        // ゆっくり回転させるアニメーション
        animateRotation(on: root)

        return root
    }

    private func centerRing() -> Entity? {
        let monthly = monthlyTotal()
        let label = ModelEntity(
            mesh: .generateText(
                CurrencyCatalog.format(monthly, code: currencyCode()),
                extrusionDepth: 0.005,
                font: .systemFont(ofSize: 0.12, weight: .bold),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byWordWrapping
            ),
            materials: [UnlitMaterial(color: .white)]
        )
        label.position = SIMD3<Float>(-0.18, 0.02, 0)

        let ring = ModelEntity(
            mesh: .generateCylinder(height: 0.005, radius: 0.18),
            materials: [SimpleMaterial(color: .systemBlue.withAlphaComponent(0.35), isMetallic: false)]
        )
        ring.position = SIMD3<Float>(0, -0.06, 0)

        let container = Entity()
        container.addChild(label)
        container.addChild(ring)
        return container
    }

    private func expenseEntities() -> [Entity] {
        let expenses = currentExpenses()
        guard !expenses.isEmpty else { return [] }
        let maxAmount = expenses.map { $0.amountDecimal }.max() ?? Decimal(1)
        let maxAmountD = NSDecimalNumber(decimal: max(maxAmount, Decimal(1))).doubleValue

        // カテゴリごとに高さレーン分け (最大 6 レーン)
        let categoryOrder = Array(Set(expenses.map { $0.categoryDisplayName })).sorted()
        let lanes = max(categoryOrder.count, 1)

        var entities: [Entity] = []
        let count = expenses.count

        for (i, e) in expenses.enumerated() {
            let angle = Float(i) / Float(count) * .pi * 2
            let categoryIndex = categoryOrder.firstIndex(of: e.categoryDisplayName) ?? 0
            let yOffset = (Float(categoryIndex) - Float(lanes - 1) / 2) * 0.15

            // 半径: 軌道のベース 0.6m + カテゴリで微差
            let radius: Float = 0.6 + Float(categoryIndex) * 0.04

            // 球サイズ: 金額の log スケール
            let amountD = NSDecimalNumber(decimal: e.amountDecimal).doubleValue
            let normalized = log(amountD + 1) / log(maxAmountD + 1)
            let sphereR: Float = 0.025 + Float(normalized) * 0.06

            // 色: カテゴリ tint
            let tintColor: UIColor = UIColor(e.categoryTint)
            let material = SimpleMaterial(color: tintColor, isMetallic: true)

            let sphere = ModelEntity(
                mesh: .generateSphere(radius: sphereR),
                materials: [material]
            )
            sphere.position = SIMD3<Float>(
                cos(angle) * radius,
                yOffset,
                sin(angle) * radius
            )
            sphere.name = "expense-\(e.objectID.uriRepresentation().absoluteString)"
            sphere.components.set(InputTargetComponent())
            sphere.components.set(CollisionComponent(shapes: [.generateSphere(radius: sphereR)]))
            sphere.components.set(HoverEffectComponent())

            // 金額ラベル
            let label = ModelEntity(
                mesh: .generateText(
                    e.formattedAmount,
                    extrusionDepth: 0.001,
                    font: .systemFont(ofSize: 0.025, weight: .medium),
                    containerFrame: .zero,
                    alignment: .center,
                    lineBreakMode: .byTruncatingTail
                ),
                materials: [UnlitMaterial(color: .white)]
            )
            label.position = SIMD3<Float>(0, sphereR + 0.02, 0)
            sphere.addChild(label)

            entities.append(sphere)
        }

        return entities
    }

    private func animateRotation(on entity: Entity) {
        var transform = entity.transform
        transform.rotation = simd_quatf(angle: .pi * 2, axis: SIMD3<Float>(0, 1, 0))
        entity.move(
            to: transform,
            relativeTo: entity.parent,
            duration: 60,
            timingFunction: .linear
        )
        // 完了時に再度回し続ける (簡易ループ)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak entity] in
            guard let entity else { return }
            animateRotation(on: entity)
        }
    }

    private func pulse(entity: Entity) {
        var inflated = entity.transform
        inflated.scale = SIMD3<Float>(repeating: 1.4)
        entity.move(to: inflated, relativeTo: entity.parent, duration: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak entity] in
            guard let entity else { return }
            var normal = entity.transform
            normal.scale = SIMD3<Float>(repeating: 1.0)
            entity.move(to: normal, relativeTo: entity.parent, duration: 0.18)
        }
    }

    // MARK: - Data

    private func currentSheet() -> ExpenseSheet? {
        guard let id = sheetID else { return nil }
        return try? viewContext.existingObject(with: id) as? ExpenseSheet
    }

    private func currentExpenses() -> [Expense] {
        guard let sheet = currentSheet(),
              let set = sheet.expenses as? Set<Expense> else { return [] }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: .now)
        return set
            .filter { e in
                guard e.kind == .expense, let d = e.date else { return false }
                let c = cal.dateComponents([.year, .month], from: d)
                return c.year == comps.year && c.month == comps.month
            }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    private func monthlyTotal() -> Decimal {
        currentExpenses().reduce(Decimal(0)) { $0 + $1.amountDecimal }
    }

    private func currencyCode() -> String {
        currentSheet()?.resolvedDefaultCurrencyCode ?? CurrencyCatalog.defaultCode
    }
}

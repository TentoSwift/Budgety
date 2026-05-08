//
//  PaywallView.swift
//  Expenso
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @StateObject private var pm = PurchaseManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlan: PurchaseManager.Plan = .yearly
    @State private var showRestartAlert: Bool = false
    @State private var showThanks: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    featuresList
                    if pm.isPremium { activeStatusCard } else { plansSection }
                    actions
                    legalFooter
                }
                .padding()
            }
            .navigationTitle("Budgety Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                if pm.products.isEmpty { await pm.loadProducts() }
            }
            .alert("購入ありがとうございます", isPresented: $showRestartAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("共有機能が有効になりました。")
            }
            .alert("購入の復元", isPresented: $showThanks) {
                Button("OK") { dismiss() }
            } message: {
                Text("プレミアム特典が復元されました。")
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.yellow.gradient)
            Text("シートを共有するなら Premium")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("家族や友人を招待してシートを共有するのに必要です。\nアプリ本体と iCloud 同期は無料で使えます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private var featuresList: some View {
        VStack(spacing: 14) {
            featureRow(icon: "person.2.fill", title: "シートを共有",
                       subtitle: "家族・友人を招待して同じシートに記録 (招待相手は無料)")
            featureRow(icon: "rectangle.stack.fill.badge.plus", title: "シートを無制限に作成",
                       subtitle: "無料は 5 枚まで。Premium で無制限")
            featureRow(icon: "tag.fill", title: "カテゴリを無制限に追加",
                       subtitle: "無料は 1 シート 20 まで。共有相手の誰か 1 人が Premium ならそのシートは全員無制限")
            featureRow(icon: "doc.text", title: "CSV エクスポート",
                       subtitle: "Excel / Numbers で開けるバックアップ")
            featureRow(icon: "doc.richtext", title: "PDF レポート",
                       subtitle: "月別サマリ + カテゴリ別内訳の集計レポート")
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var activeStatusCard: some View {
        VStack(spacing: 8) {
            Label("Premium 解除済み", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let plan = pm.activePlan {
                Text("現在のプラン: \(plan.label)")
                    .font(.subheadline)
            }
            Text("ありがとうございます。すべての機能を利用できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.green.opacity(0.1)))
    }

    @ViewBuilder
    private var plansSection: some View {
        VStack(spacing: 12) {
            ForEach(PurchaseManager.Plan.allCases) { plan in
                planCard(plan: plan)
            }
        }
    }

    @ViewBuilder
    private func planCard(plan: PurchaseManager.Plan) -> some View {
        let product = pm.product(for: plan)
        let isSelected = selectedPlan == plan
        Button {
            selectedPlan = plan
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.label)
                            .font(.headline)
                        if plan == .yearly {
                            Text("おすすめ")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.orange))
                        }
                    }
                    Text(plan.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let product {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice)
                            .font(.headline.monospacedDigit())
                        if plan == .monthly {
                            Text("/ 月").font(.caption2).foregroundStyle(.secondary)
                        } else if plan == .yearly {
                            Text("/ 年").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if !pm.isPremium {
                Button {
                    Task {
                        guard let product = pm.product(for: selectedPlan) else { return }
                        if await pm.purchase(product) {
                            showRestartAlert = true
                        }
                    }
                } label: {
                    HStack {
                        if pm.isProcessing { ProgressView() }
                        Text(actionTitle)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pm.isProcessing || pm.product(for: selectedPlan) == nil)
            }

            Button {
                Task {
                    let wasPremium = pm.isPremium
                    await pm.restore()
                    if pm.isPremium && !wasPremium {
                        showThanks = true
                    }
                }
            } label: {
                Text("購入を復元")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(pm.isProcessing)

            if let error = pm.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var actionTitle: String {
        if pm.isProcessing { return "処理中..." }
        switch selectedPlan {
        case .lifetime: return "永久ライセンスを購入"
        case .monthly: return "月額プランを開始"
        case .yearly: return "年額プランを開始"
        }
    }

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("購入は Apple ID に紐づきます。")
            Text("サブスクリプションは期間終了の 24 時間前までに解約しないと自動更新されます。")
            Text("解約された場合、自分が作成した共有シートは解除されます。")
            Text("ファミリー共有に対応しています。")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }
}

#Preview {
    PaywallView()
}

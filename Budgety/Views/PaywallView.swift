//
//  PaywallView.swift
//  Expenso
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @StateObject private var pm = PurchaseManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedPlan: PurchaseManager.Plan = .yearly
    @State private var showRestartAlert: Bool = false
    @State private var showThanks: Bool = false
    @State private var showRedeemSheet: Bool = false

    private var isAX: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    if pm.isPremium { activeStatusCard } else {
                        featuresList
                        plansSection
                    }
                    actions
                    legalFooter
                }
                .padding()
            }
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
            .task {
                if pm.products.isEmpty { await pm.loadProducts() }
            }
            .alert("ありがとうございます", isPresented: $showRestartAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("Premium が有効になりました。")
            }
            .alert("復元しました", isPresented: $showThanks) {
                Button("OK") { dismiss() }
            } message: {
                Text("Premium が復元されました。")
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            // カテゴリアイコン風: 単色塗りの円 + 白の SF Symbol
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Color.yellow.gradient))
                .shadow(color: .yellow.opacity(0.45), radius: 14, y: 6)
            Text("Budgety Premium")
                .font(.title.bold())
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Premium でできること")
                .font(.headline)
                .padding(.horizontal)

            featureRow("person.2.fill",
                       color: Color(red: 0.36, green: 0.55, blue: 0.94),
                       title: "シートを共有",
                       detail: "家族やパートナーを招待して、ひとつの家計簿を一緒に管理できます。")
            featureRow("person.crop.circle.badge.plus",
                       color: Color(red: 0.00, green: 0.70, blue: 0.69),
                       title: "バーチャルメンバー",
                       detail: "アプリを使っていない人も追加して、旅行や食事会の割り勘対象にできます。")
            // Claude / MCP 連携は macOS では提供しない (App Store Guideline 2.4.5(ii)) ので訴求も出さない。
            #if !os(macOS)
            featureRow("sparkles",
                       color: Color(red: 0.69, green: 0.32, blue: 0.87),
                       title: "Claude / MCP と連携",
                       detail: "「コーヒー 350 円」と話しかけるだけで支出を記録できます。")
            #endif
            featureRow("lock.fill",
                       color: Color(red: 0.96, green: 0.26, blue: 0.33),
                       title: "パスワードでロック",
                       detail: "大事なシートをパスワードと Face ID / Touch ID で保護できます。")
            featureRow("rectangle.stack.fill.badge.plus",
                       color: Color(red: 0.69, green: 0.32, blue: 0.87),
                       title: "シートを無制限に",
                       detail: "無料プランは 3 個までですが、用途ごとにいくつでも作成できます。")
            featureRow("tag.fill",
                       color: Color(red: 1.00, green: 0.58, blue: 0.00),
                       title: "カテゴリを無制限に",
                       detail: "1 シートあたり 20 個の上限を解除できます。")
            featureRow("doc.richtext",
                       color: Color(red: 0.20, green: 0.78, blue: 0.35),
                       title: "PDF / CSV で書き出し",
                       detail: "家計データを書き出してバックアップや共有ができます。")
            featureRow("paintpalette.fill",
                       color: Color(red: 0.93, green: 0.35, blue: 0.62),
                       title: "プレミアムアイコン",
                       detail: "シートとカテゴリで使える特別なアイコンを利用できます。")
            featureRow("figure.2.and.child.holdinghands",
                       color: Color(red: 0.30, green: 0.69, blue: 0.31),
                       title: "ファミリー共有対応",
                       detail: "ひとつの購入で家族 (最大 6 人) と Premium を共有できます。")
        }
    }

    private func featureRow(_ icon: String, color: Color, title: String, detail: String) -> some View {
        // カテゴリ風アイコン (色付き円 + 白シンボル) + 見出し + 説明。
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal)
    }

    private var activeStatusCard: some View {
        VStack(spacing: 6) {
            Label("Premium 解除済み", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let plan = pm.activePlan {
                Text(plan.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .glassEffect(.regular.tint(.green.opacity(0.20)), in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var plansSection: some View {
        VStack(spacing: 8) {
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
            // AX サイズでは横並びだと price が見切れるので縦積み (= AnyLayout で
            // 通常時 HStack / AX 時 VStack に切替)。
            let layout = isAX
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(.white)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.label)
                            .font(.body.weight(.semibold))
                        // 期間・自動更新の有無を明示 (Guideline 3.1.2)。
                        Text(plan.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !isAX { Spacer() }
                }
                if let product {
                    Text(product.displayPrice)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: isAX ? .infinity : nil, alignment: isAX ? .trailing : .center)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 全体をヒットテスト対象に (= 余白部分をタップしても選択できる)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .glassEffect(
                isSelected
                    ? .regular.interactive().tint(Color.accentColor)
                    : .regular.interactive(),
                in: .rect(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
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
                        Text(pm.isProcessing ? "処理中..." : "購入する")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pm.isProcessing || pm.product(for: selectedPlan) == nil)
            }

            HStack(spacing: 24) {
                Button("購入を復元") {
                    Task {
                        let wasPremium = pm.isPremium
                        await pm.restore()
                        if pm.isPremium && !wasPremium {
                            showThanks = true
                        }
                    }
                }
                .disabled(pm.isProcessing)

                Button("コードを使用") {
                    showRedeemSheet = true
                }
                .disabled(pm.isProcessing)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .controlSize(.regular)
            .offerCodeRedemption(isPresented: $showRedeemSheet)

            if let error = pm.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// サブスクリプションの必須表記 (Guideline 3.1.2): 自動更新の説明 +
    /// 利用規約 (EULA) / プライバシーポリシーへの有効なリンク。
    private var legalFooter: some View {
        VStack(spacing: 10) {
            Text("月額・年額プランは自動更新サブスクリプションです。期間終了の24時間以上前に解約しない限り自動更新され、購入確定時に Apple ID へ請求されます。解約・管理は「設定 > Apple ID > サブスクリプション」から行えます。買い切りプランは一度のお支払いで永続します。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link("利用規約 (EULA)",
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text("·").foregroundStyle(.secondary)
                Link("プライバシーポリシー",
                     destination: URL(string: "https://tentoswift.github.io/budgety-privacy/")!)
            }
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }
}

#Preview {
    PaywallView()
}

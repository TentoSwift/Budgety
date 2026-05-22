//
//  PeriodMenuControl.swift
//  Budgety
//
//  iOS 26 で SwiftUI の Menu / UIButton ベースのメニューは、展開時にソース
//  (= ボタン本体) からモーフィングしてビュー本体が一時的に隠れる挙動になった。
//  サマリカードの期間ピッカーはソースのテキスト ("2026年11月 · シート名") が
//  メニュー展開中も見えていて欲しいので、UIControl を直接使う公開 API の
//  ワークアラウンドで包む。
//
//  ref: https://gist.github.com/vistar941/2d4a120fefa37de73aeb18b6d20f4445
//

import SwiftUI
#if os(iOS)
import UIKit

/// SwiftUI から呼ぶ UIViewRepresentable ラッパー。
struct PeriodMenuControl: UIViewRepresentable {
    @Binding var period: SheetDetailView.Period
    let periodLabel: String

    func makeUIView(context: Context) -> _PeriodMenuUIControl {
        let v = _PeriodMenuUIControl()
        v.onSelect = { newValue in
            // SwiftUI 状態更新は main thread から
            DispatchQueue.main.async { period = newValue }
        }
        return v
    }

    func updateUIView(_ uiView: _PeriodMenuUIControl, context: Context) {
        uiView.update(current: period, periodLabel: periodLabel)
    }

    /// Dynamic Type で拡大した実サイズを SwiftUI に伝える。
    /// これが無いと拡大時に確保枠が足りず、上の行と重なって切れる。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: _PeriodMenuUIControl, context: Context) -> CGSize? {
        uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }
}

/// 実体の UIControl サブクラス。
///
/// iOS 26 の UIButton では `UIMenu` がモーフィング展開してソースが隠れるが、
/// **UIControl 直で `showsMenuAsPrimaryAction` + `isContextMenuInteractionEnabled`
/// + `contextMenuInteraction(_:configurationForMenuAtLocation:)` をオーバーライド**
/// する形にすると旧来通りソースが残ったまま展開される。
final class _PeriodMenuUIControl: UIControl {

    // MARK: - UI parts

    private let stack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.alignment = .center
        s.spacing = 6
        s.isUserInteractionEnabled = false
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let periodLabel: UILabel = {
        let l = UILabel()
        // 20pt をベースに Dynamic Type で拡大縮小する (固定サイズにしない)。
        let base = UIFont.systemFont(ofSize: 20, weight: .semibold)
        l.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: base)
        l.adjustsFontForContentSizeCategory = true
        l.textColor = .secondaryLabel
        return l
    }()

    /// 通常時は `>` (chevron.right)、メニュー展開中は `↓` (chevron.down) になるよう
    /// シンボル画像をスワップする。ラベルに合わせて Dynamic Type で拡大する。
    private let chevron: UIImageView = {
        let cfg = UIImage.SymbolConfiguration(textStyle: .title3, scale: .small)
        let img = UIImage(systemName: "chevron.right", withConfiguration: cfg)
        let v = UIImageView(image: img)
        v.tintColor = .secondaryLabel
        v.preferredSymbolConfiguration = cfg
        v.adjustsImageSizeForAccessibilityContentSizeCategory = true
        return v
    }()

    // MARK: - State

    var onSelect: ((SheetDetailView.Period) -> Void)?
    private var currentPeriod: SheetDetailView.Period = .thisMonth

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        showsMenuAsPrimaryAction = true
        isContextMenuInteractionEnabled = true

        addSubview(stack)
        stack.addArrangedSubview(periodLabel)
        stack.addArrangedSubview(chevron)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Update

    func update(current: SheetDetailView.Period, periodLabel: String) {
        currentPeriod = current
        self.periodLabel.text = periodLabel
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        // 幅・高さとも実レイアウトから求める (Dynamic Type 拡大に追従)。
        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: size.width, height: max(size.height, 22))
    }

    /// 文字サイズ設定が変わったら再計測して枠を更新する。
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Menu

    /// iOS 26 で UIButton ではなく UIControl のメニュー挙動 (= source 残し)
    /// を有効化するためにこのデリゲートメソッドを override する。
    /// `self.menu` は設定せず、ここでメニューを返すことで UIButton 的な
    /// morph 展開を回避する。
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let actions = SheetDetailView.Period.allCases.map { p -> UIAction in
            UIAction(
                title: p.label,
                state: (p == currentPeriod) ? .on : .off
            ) { [weak self] _ in
                self?.onSelect?(p)
            }
        }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: actions)
        })
    }

    // MARK: - Chevron direction transition

    /// メニュー展開時に chevron を `>` → `↓` に切り替える。
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(
            interaction,
            willDisplayMenuFor: configuration,
            animator: animator
        )
        setChevron(open: true)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(
            interaction,
            willEndFor: configuration,
            animator: animator
        )
        setChevron(open: false)
    }

    /// chevron.right を時計回りに 90° 回転して `↓` 方向に向ける。
    /// シンボル画像は同じまま、CGAffineTransform で回転アニメーションする。
    private func setChevron(open: Bool) {
        let angle: CGFloat = open ? .pi / 2 : 0
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) { [weak self] in
            self?.chevron.transform = CGAffineTransform(rotationAngle: angle)
        }
    }
}
#endif

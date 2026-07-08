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
    /// 「カスタム…」を選んだときのコールバック。nil ならメニューに「カスタム」を出さない
    /// (= カスタム範囲編集 UI を持たない呼び出し元。検索用の SheetListView 等)。
    var onCustomSelected: (() -> Void)? = nil

    func makeUIView(context: Context) -> _PeriodMenuUIControl {
        let v = _PeriodMenuUIControl()
        v.onSelect = { newValue in
            // SwiftUI 状態更新は main thread から
            DispatchQueue.main.async { period = newValue }
        }
        return v
    }

    func updateUIView(_ uiView: _PeriodMenuUIControl, context: Context) {
        uiView.onCustomSelected = onCustomSelected
        uiView.update(current: period, periodLabel: periodLabel)
    }

    /// Dynamic Type で拡大した実サイズを SwiftUI に伝える。
    /// これが無いと拡大時に確保枠が足りず、上の行と重なって切れる。
    ///
    /// まず 1 行の自然サイズを求め、提案幅に収まるならそれを返す。収まらない
    /// (AX 拡大 + カスタム期間の長いラベル等) 場合は提案幅で折り返した高さを返し、
    /// 幅が画面外へはみ出さないようにする。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: _PeriodMenuUIControl, context: Context) -> CGSize? {
        let natural = uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        // 提案幅が無い (ideal) か、自然サイズが収まるならそのまま (1 行)。
        guard let maxWidth = proposal.width, maxWidth.isFinite, natural.width > maxWidth else {
            return natural
        }
        // 収まらないときは提案幅 (0 でも 1pt 以上に丸める) で折り返した高さを返す。
        // width 0 の問い合わせでも折り返しサイズを返すことで「最小幅も巨大」に
        // ならず、HStack 内で正しく縮んでカードが画面外へ出るのを防ぐ。
        let target = CGSize(width: max(maxWidth, 1), height: UIView.layoutFittingCompressedSize.height)
        return uiView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
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
        // Dynamic Type 拡大 + カスタム期間の長いラベル ("2026年11月1日〜…") では
        // 1 行固定だと幅が画面を超え、SummaryCard ごと画面外へはみ出す。
        // 複数行に折り返せるようにして幅方向は親の提案に収める (高さは sizeThatFits)。
        l.numberOfLines = 0
        l.lineBreakMode = .byWordWrapping
        return l
    }()

    /// 通常時は `>` (chevron.right)、メニュー展開中は `↓` (chevron.down) になるよう
    /// シンボル画像をスワップする。ラベルに合わせて Dynamic Type で拡大する。
    private let chevron: UIImageView = {
        // Dynamic Type で拡大 (textStyle) しつつ semibold ウェイトにする。
        let cfg = UIImage.SymbolConfiguration(textStyle: .title3, scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        let img = UIImage(systemName: "chevron.right", withConfiguration: cfg)
        let v = UIImageView(image: img)
        v.tintColor = .secondaryLabel
        v.preferredSymbolConfiguration = cfg
        v.adjustsImageSizeForAccessibilityContentSizeCategory = true
        return v
    }()

    // MARK: - State

    var onSelect: ((SheetDetailView.Period) -> Void)?
    /// 「カスタム…」選択時のコールバック。nil ならカスタム項目を出さない。
    var onCustomSelected: (() -> Void)?
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
        // プリセット期間 (今月/先月/今年/全期間)。カスタムは末尾に別項目で出す。
        var actions = SheetDetailView.Period.allCases
            .filter { $0 != .custom }
            .map { p -> UIAction in
                UIAction(
                    title: p.label,
                    state: (p == currentPeriod) ? .on : .off
                ) { [weak self] _ in
                    self?.onSelect?(p)
                }
            }
        // カスタム範囲を扱える呼び出し元でのみ「カスタム…」を出す。
        if let onCustomSelected {
            let title = SheetDetailView.Period.custom.label + "…"
            actions.append(UIAction(
                title: title,
                image: UIImage(systemName: "calendar"),
                state: (currentPeriod == .custom) ? .on : .off
            ) { _ in
                onCustomSelected()
            })
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

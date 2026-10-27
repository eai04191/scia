import SciaCore
import UIKit

/// 投稿の投票。選択肢を縦に並べ、その下に人数と締め切り、ボタンを1行で置く。決まりは`docs/poll.md`。
///
/// 投票する形では、選択肢を押して選び、「投票」で送る。結果の形では、選択肢の後ろに割合の棒を敷き、先頭に割合、末尾に自分が票を入れたチェックマークを出す。
/// 投票すると形が替わるが、行の高さは変えない。先頭の記号と割合、末尾のチェックマークの場所はどちらの形でも同じ幅を取り、選択肢の文字の折り返しをそろえる。
/// 下の行の高さも、「投票」のボタンの高さに固定する。
/// 結果の形の選択肢は押下を受けず、行の押下（スレッドを開く）に渡す。
final class PollView: UIView {
    struct Content: Equatable {
        var pollID: Poll.ID
        var display: PollDisplay
        /// 選択肢の文字。カスタム絵文字を描いたもの。
        var titles: [NSAttributedString]
        var titleFont: UIFont
        /// 票数と締め切りと、その横のボタンの文字。投票のボタンは、目立たせるため選択肢と同じ大きさにする。
        var footerFont: UIFont
        /// 最後の選択肢と、票数と締め切りの行のあいだ。
        var footerSpacing: CGFloat
        /// 選択肢どうしのあいだ。
        var optionSpacing: CGFloat
        /// 選択肢の文字の上下の余白。
        var optionPadding: CGFloat
        /// 選択肢の枠と、記号や割合のあいだの左右の余白。
        var optionHorizontalPadding: CGFloat = 10
        /// 選択肢の枠の角の丸み。
        var optionCornerRadius: CGFloat = 8
        /// 投票したときや読み直したときに、結果の棒が伸びる時間。
        var barDuration: TimeInterval
    }

    enum Action {
        case toggle(Int)
        case submit
        case reveal
        case returnToVoting
        case refresh
    }

    var onAction: ((Action) -> Void)?
    /// 選択肢のアニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら動かさない。
    var emojiImages: EmojiImageStore? {
        didSet {
            for option in optionViews {
                option.titleLabel.emojiImages = emojiImages
            }
        }
    }

    private(set) var content: Content?
    private var optionViews: [PollOptionView] = []
    private let optionsStack = UIStackView()
    private let footer = UIView()
    private let summaryLabel = UILabel()
    private let secondaryButton = UIButton(configuration: .plain())
    private let voteButton = UIButton(configuration: .filled())
    private var secondaryTrailing: [NSLayoutConstraint] = []
    private lazy var footerTop = footer.topAnchor.constraint(equalTo: optionsStack.bottomAnchor)
    private var secondaryAction: Action?

    override init(frame: CGRect) {
        super.init(frame: frame)
        optionsStack.axis = .vertical
        summaryLabel.textColor = .secondaryLabel
        // 文字を大きくして横に入りきらなくなったら、切り詰めずに折り返す。票数や締め切りが読めなくなるため。
        summaryLabel.numberOfLines = 0
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var secondary = UIButton.Configuration.plain()
        secondary.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        secondaryButton.configuration = secondary
        secondaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        secondaryButton.addAction(UIAction { [weak self] _ in
            guard let action = self?.secondaryAction else { return }
            self?.onAction?(action)
        }, for: .primaryActionTriggered)

        var vote = UIButton.Configuration.filled()
        vote.title = "投票"
        vote.cornerStyle = .capsule
        vote.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        voteButton.configuration = vote
        voteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        voteButton.addAction(UIAction { [weak self] _ in self?.onAction?(.submit) }, for: .primaryActionTriggered)

        for view in [optionsStack, footer] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [summaryLabel, secondaryButton, voteButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        secondaryTrailing = [
            secondaryButton.trailingAnchor.constraint(equalTo: voteButton.leadingAnchor, constant: -4),
            secondaryButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: 8),
        ]
        // 下の行は、ボタンと票数の文字が収まる最小の高さに寄せる。
        // 一覧はセルの高さを、高さを譲れる優先度（fittingSizeLevel）で測るので、それより強くする。同じ強さだと高さが決まらず、セルが目安の高さまで伸びる。
        let compactFooter = footer.heightAnchor.constraint(equalToConstant: 0)
        compactFooter.priority = .defaultLow
        compactFooter.isActive = true
        NSLayoutConstraint.activate([
            optionsStack.topAnchor.constraint(equalTo: topAnchor),
            optionsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            optionsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerTop,
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 結果の形では「投票」を隠すが、下の行の高さは変えない。票数が折り返したときは、その高さまで広げる。
            footer.heightAnchor.constraint(greaterThanOrEqualTo: voteButton.heightAnchor),
            summaryLabel.topAnchor.constraint(greaterThanOrEqualTo: footer.topAnchor),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: footer.bottomAnchor),
            voteButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            voteButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            summaryLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            secondaryButton.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 4),
            secondaryButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func fontTransformer(_ font: UIFont) -> UIConfigurationTextAttributesTransformer {
        UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
    }

    func apply(_ content: Content) {
        let previous = self.content
        self.content = content
        let display = content.display
        optionsStack.spacing = content.optionSpacing
        footerTop.constant = content.footerSpacing
        while optionViews.count < display.options.count {
            let option = PollOptionView()
            let index = optionViews.count
            option.titleLabel.emojiImages = emojiImages
            option.addAction(UIAction { [weak self] _ in self?.onAction?(.toggle(index)) }, for: .touchUpInside)
            optionViews.append(option)
            optionsStack.addArrangedSubview(option)
        }
        // 同じ投票で割合が変わったときだけ、棒を前の長さから伸ばす。使い回された行で別の投票に替わったときは、動かさずに出す。
        // 同じ投票で割合も形も変わらない描き直し（送っている途中のインジケーターを外すときなど）では、伸ばしている途中の棒をそのままにする。
        let samePoll = previous?.pollID == content.pollID
        // 投票する形と結果の形が入れ替わるときは、フチ、記号、割合、ボタンが一度に替わるため、投票全体をクロスフェードする。
        // 棒はクロスフェードの中でも伸ばす。一覧は動きを止めて描き直すことがあり、その中ではUIView.transitionが動かないため、レイヤーに直接足す。
        if samePoll, previous?.display.mode != display.mode, window != nil, content.barDuration > 0, !UIAccessibility.isReduceMotionEnabled {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = content.barDuration * 0.5
            layer.add(fade, forKey: "modeChange")
        }
        let keepsBars = samePoll && previous?.display.mode == display.mode && previous?.display.options.map(\.fraction) == display.options.map(\.fraction)
        let animatesBars = samePoll && !keepsBars && display.mode == .results
            && window != nil && content.barDuration > 0 && !UIAccessibility.isReduceMotionEnabled
        for (index, option) in optionViews.enumerated() {
            option.isHidden = index >= display.options.count
            guard index < display.options.count else { continue }
            let start: PollOptionView.BarStart
            if keepsBars {
                start = .keep
            } else if animatesBars, let previous {
                // 投票する形から替わったときは、棒のない状態から伸ばす。
                let fraction = previous.display.mode == .results && previous.display.options.indices.contains(index) ? previous.display.options[index].fraction ?? 0 : 0
                start = .from(CGFloat(fraction))
            } else {
                start = .target
            }
            option.apply(
                display.options[index],
                title: content.titles.indices.contains(index) ? content.titles[index] : NSAttributedString(),
                font: content.titleFont,
                mode: display.mode,
                multiple: display.multiple,
                padding: content.optionPadding,
                horizontalPadding: content.optionHorizontalPadding,
                cornerRadius: content.optionCornerRadius,
                barStart: start
            )
        }
        if animatesBars {
            let fractions = display.options.map(\.fraction)
            // 一覧は動きを止めて描き直すことがあり、その中ではUIView.animateが動かないため、描き直しを終えてから動かす。
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.content, current.pollID == content.pollID, current.display.options.map(\.fraction) == fractions else { return }
                UIView.animate(springDuration: content.barDuration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    for option in self.optionViews where !option.isHidden {
                        option.showTargetFraction()
                    }
                }
            }
        }

        if content.footerFont != previous?.footerFont || content.titleFont != previous?.titleFont {
            summaryLabel.font = content.footerFont
            secondaryButton.configuration?.titleTextAttributesTransformer = Self.fontTransformer(content.footerFont)
            voteButton.configuration?.titleTextAttributesTransformer = Self.fontTransformer(content.titleFont.withWeight(.semibold))
        }
        summaryLabel.text = display.summary
        voteButton.isHidden = display.mode == .results
        voteButton.isEnabled = display.canSubmit
        voteButton.configuration?.showsActivityIndicator = display.isSubmitting
        let secondary: (title: String, action: Action, enabled: Bool)? = switch display.mode {
        case .voting where display.canRevealResults: ("結果を見る", .reveal, !display.isSubmitting)
        case .voting: nil
        case .results where display.canReturnToVoting: ("投票に戻る", .returnToVoting, true)
        case .results where display.canRefresh: ("更新", .refresh, !display.isRefreshing)
        case .results: nil
        }
        secondaryAction = secondary?.action
        secondaryButton.isHidden = secondary == nil
        secondaryButton.configuration?.title = secondary?.title
        secondaryButton.isEnabled = secondary?.enabled ?? false
        NSLayoutConstraint.deactivate(secondaryTrailing)
        secondaryTrailing[voteButton.isHidden ? 1 : 0].isActive = true
    }

    /// 表示中の選択肢ごとの、枠と文字の枠。「投稿の見た目」のプレビューで、選択肢のあいだと上下の余白を示すときに使う。
    func optionPreviewFrames(in space: UIView) -> [(option: CGRect, title: CGRect)] {
        optionViews.compactMap { option in
            guard let frame = option.previewFrame(in: space)?.first, let title = option.titleLabel.previewFrame(in: space)?.first else { return nil }
            return (frame, title)
        }
    }

    /// 票数と締め切りの文字の枠。
    func summaryPreviewFrame(in space: UIView) -> [CGRect]? {
        summaryLabel.previewFrame(in: space)
    }

    /// 選択肢を並べた枠。
    func optionsPreviewFrame(in space: UIView) -> [CGRect]? {
        optionsStack.previewFrame(in: space)
    }

    /// 票数と締め切りの行の枠。「投稿の見た目」のプレビューで場所を示すときに使う。
    func footerPreviewFrame(in space: UIView) -> [CGRect]? {
        footer.previewFrame(in: space)
    }

    /// 読み上げの要素。選択肢、人数と締め切り、ボタンの順。
    var accessibilityParts: [Any] {
        optionViews.filter { !$0.isHidden } + [summaryLabel, secondaryButton, voteButton].filter { !$0.isHidden }
    }
}

/// 投票の選択肢の1行。投票する形では押して選び、結果の形では後ろに割合の棒を敷く。
final class PollOptionView: UIControl {
    let titleLabel = EmojiLabel()
    private let barView = UIView()
    private let indicatorView = UIImageView()
    private let percentLabel = UILabel()
    private let ownVoteView = UIImageView(image: UIImage(systemName: "checkmark"))
    private var variableConstraints: [NSLayoutConstraint] = []
    /// 棒の長さの割合。描いている長さと、伸ばした先の長さ。
    private var drawnFraction: CGFloat = 0
    private var targetFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundColor = .tertiarySystemFill
        isAccessibilityElement = true
        barView.isUserInteractionEnabled = false
        barView.layer.cornerRadius = 8
        barView.layer.cornerCurve = .continuous
        addSubview(barView)
        titleLabel.numberOfLines = 0
        indicatorView.contentMode = .center
        indicatorView.tintColor = .secondaryLabel
        // 割合の桁がそろうよう、先頭の場所の中で後ろに寄せる。
        percentLabel.textAlignment = .right
        percentLabel.textColor = .secondaryLabel
        ownVoteView.contentMode = .center
        ownVoteView.tintColor = .tintColor
        for view in [titleLabel, indicatorView, percentLabel, ownVoteView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        // 枠の色はCGColorで、外観が変わっても描き直されないため、変わったら当て直す。
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.tintColor.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 棒をどの長さから描くか。
    enum BarStart {
        /// 伸ばさずに、目の長さで描く。
        case target
        /// この長さから伸ばす。伸ばすのは置く側が`showTargetFraction()`で行う。
        case from(CGFloat)
        /// 描いている長さのまま。伸ばしている途中なら、そのまま伸ばし続ける。
        case keep
    }

    func apply(_ option: PollDisplay.Option, title: NSAttributedString, font: UIFont, mode: PollDisplay.Mode, multiple: Bool, padding: CGFloat, horizontalPadding: CGFloat, cornerRadius: CGFloat, barStart: BarStart) {
        layer.cornerRadius = cornerRadius
        barView.layer.cornerRadius = cornerRadius
        titleLabel.attributedText = title
        let showsResults = mode == .results
        isUserInteractionEnabled = !showsResults
        indicatorView.isHidden = showsResults
        let symbol = switch (multiple, option.isSelected) {
        case (false, false): "circle"
        case (false, true): "checkmark.circle.fill"
        case (true, false): "square"
        case (true, true): "checkmark.square.fill"
        }
        indicatorView.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))
        indicatorView.tintColor = option.isSelected ? .tintColor : .secondaryLabel
        layer.borderWidth = !showsResults && option.isSelected ? 1.5 : 0
        layer.borderColor = UIColor.tintColor.cgColor
        let percentFont = font.withWeight(option.isLeading ? .semibold : .regular)
        percentLabel.font = percentFont
        percentLabel.isHidden = !showsResults || option.fraction == nil
        percentLabel.text = option.fraction.map { "\(Int(($0 * 100).rounded()))%" }
        percentLabel.textColor = option.isLeading ? .label : .secondaryLabel
        ownVoteView.isHidden = !showsResults || !option.isOwnVote
        ownVoteView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font.withWeight(.semibold), scale: .small)
        barView.isHidden = !showsResults || option.fraction == nil
        barView.backgroundColor = option.isLeading ? UIColor.tintColor.withAlphaComponent(0.25) : .systemFill
        targetFraction = showsResults ? CGFloat(option.fraction ?? 0) : 0
        switch barStart {
        case .target: drawnFraction = targetFraction
        case .from(let fraction): drawnFraction = fraction
        case .keep: break
        }

        // 先頭の場所は、どちらの形でも「100%」が入る幅を取る。投票すると形が替わっても、選択肢の文字の折り返しを変えないため。
        let leadingWidth = ceil(("100%" as NSString).size(withAttributes: [.font: font.withWeight(.semibold)]).width)
        let trailingWidth = ceil(font.pointSize)
        NSLayoutConstraint.deactivate(variableConstraints)
        variableConstraints = [
            // 記号は、割合より細いので、先頭の場所の中央に置く。端に寄せると、文字とのあいだが間延びして見えるため。
            indicatorView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding + leadingWidth / 2),
            indicatorView.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -font.capHeight / 2),
            percentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            percentLabel.widthAnchor.constraint(equalToConstant: leadingWidth),
            percentLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding + leadingWidth + 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(horizontalPadding + trailingWidth + 4)),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: padding),
            ownVoteView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            ownVoteView.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -font.capHeight / 2),
        ]
        NSLayoutConstraint.activate(variableConstraints)
        setNeedsLayout()

        accessibilityLabel = title.string
        switch mode {
        case .voting:
            accessibilityTraits = option.isSelected ? [.button, .selected] : .button
            accessibilityValue = nil
        case .results:
            accessibilityTraits = .staticText
            accessibilityValue = [option.fraction.map { "\(Int(($0 * 100).rounded()))%" }, option.isOwnVote ? "投票済み" : nil].compactMap(\.self).joined(separator: "、")
        }
    }

    /// 棒を伸ばした先の長さにする。アニメーションの中で呼ぶ。
    func showTargetFraction() {
        drawnFraction = targetFraction
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width * drawnFraction
        let x = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - width : 0
        barView.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : 1
        }
    }

}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

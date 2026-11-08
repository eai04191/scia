import SciaCore
import UIKit

/// 投稿の投票。選択肢を縦に並べ、その下に人数と締め切り、ボタンを1行で置く。決まりは`docs/poll.md`。
///
/// 投票する形では、選択肢を押して選び、「投票」で送る。結果の形では、選択肢の後ろに割合の棒を敷き、先頭に割合、末尾に自分が票を入れたチェックマークを出す。
/// 投票すると形が替わるが、行の高さは変えない。先頭の記号と割合、末尾のチェックマークの場所はどちらの形でも同じ幅を取り、選択肢の文字の折り返しをそろえる。
/// 下の行の高さも、「投票」のボタンの高さに固定する。
/// 結果の形の選択肢は押下を受けず、行の押下（スレッドを開く）に渡す。
///
/// 形を入れ替えるときは、投票全体を重ねて切り替えず、要素ごとに動かす。全体を重ねると、先頭の記号と割合、下の行の2つのボタンの文字が、同じ場所に重なって見えるため。
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
        /// 投票したときや読み直したときに、結果の棒が伸びる時間。割合と人数の数字も、この時間で入れ替える。
        var barDuration: TimeInterval
        /// 投票する形と結果の形を入れ替えるときの、割合を浮かび上がらせる時間と、下の行のボタンを入れ替える時間。
        var modeChangeDuration: TimeInterval = 0
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
    var emojiImages: EmojiImageStore<UIImage>? {
        didSet {
            for option in optionViews {
                option.titleLabel.emojiImages = emojiImages
            }
        }
    }

    private(set) var content: Content?
    private var optionViews: [PollOptionView] = []
    private let optionsStack = UIStackView()
    /// 選択肢のない投票で、選択肢の場所に出す文字。
    /// 並べるものがないと`optionsStack`の高さが決まらず、UIKitがセルを測るときの大きな目安の高さがそのまま返って、アプリが落ちる。
    private let emptyLabel = UILabel()
    private let footer = UIView()
    /// 票数と締め切り。大きさと読み上げのために置き、文字は`summaryText`が描く。
    private let summaryLabel = UILabel()
    private let summaryText = NumericTextOverlay(alignment: .leading)
    private let secondaryButton = UIButton(configuration: .plain())
    private let voteButton = TintFollowingButton(configuration: .filled())
    private var secondaryTrailing: [NSLayoutConstraint] = []
    private lazy var footerTop = footer.topAnchor.constraint(equalTo: optionsStack.bottomAnchor)
    private var secondaryAction: Action?

    /// 次に始める棒の動きの時間。タイムラインは行の中身を動きを止めた描き直しの中で当てるため、`apply`の中では始めない。
    private var pendingBarDuration: TimeInterval?
    /// 次に始める下の行のボタンの入れ替え。替える前のボタンの複製と、時間。
    private var pendingFooterSwap: (leaving: [UIView], duration: TimeInterval)?
    /// 消している途中の、替える前のボタンの複製。
    private var leavingButtons: [UIView] = []
    /// 動きを始める処理を積んだ。描き直しが続いても、1回だけ始める。
    private var transitionsScheduled = false
    /// 前に止めてから、同じ投票を描き直して動かしたことがある。止める処理が要るかを決める。
    private var mayHaveTransitions = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        optionsStack.axis = .vertical
        emptyLabel.text = "選択肢がありません"
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0
        optionsStack.addArrangedSubview(emptyLabel)
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
        voteButton.followsFilledForeground()
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
        summaryText.overlay(on: summaryLabel)
        secondaryTrailing = [
            secondaryButton.trailingAnchor.constraint(equalTo: voteButton.leadingAnchor, constant: -4),
            secondaryButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: 8),
        ]
        // 下の行は、ボタンと票数の文字が収まる最小の高さに寄せる。
        // タイムラインはセルの高さを、高さを譲れる優先度（fittingSizeLevel）で測るので、それより強くする。同じ強さだと高さが決まらず、セルが目安の高さまで伸びる。
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
        emptyLabel.isHidden = !display.options.isEmpty
        while optionViews.count < display.options.count {
            let option = PollOptionView()
            let index = optionViews.count
            option.titleLabel.emojiImages = emojiImages
            option.addAction(UIAction { [weak self] _ in self?.onAction?(.toggle(index)) }, for: .touchUpInside)
            optionViews.append(option)
            optionsStack.addArrangedSubview(option)
        }
        // 動かすのは、同じ投票を描き直したときだけ。使い回された行で別の投票に替わったときは、続いている動きをやめて、動かさずに出す。
        let samePoll = previous?.pollID == content.pollID
        let animates = samePoll && window != nil && !UIAccessibility.isReduceMotionEnabled
        if animates {
            mayHaveTransitions = true
        } else {
            cancelTransitions()
        }
        let modeChange: PollOptionView.ModeChange? = if animates, content.modeChangeDuration > 0, let previous, previous.display.mode != display.mode {
            display.mode == .results ? .toResults : .toVoting
        } else {
            nil
        }
        // 同じ投票で割合も形も変わらない描き直し（送っている途中のインジケーターを外すときなど）では、伸ばしている途中の棒をそのままにする。
        let keepsBars = samePoll && previous?.display.mode == display.mode && previous?.display.options.map(\.fraction) == display.options.map(\.fraction)
        // 結果の形で割合が変わったら、棒を今の長さから伸ばす。投票する形に戻るときは、棒を縮めてから隠す。
        let animatesBars = animates && !keepsBars && content.barDuration > 0 && (display.mode == .results || modeChange == .toVoting)
        let transition = PollOptionView.Transition(
            animates: animates,
            modeChange: modeChange,
            animatesBars: animatesBars,
            numberDuration: content.barDuration,
            modeChangeDuration: content.modeChangeDuration
        )
        for (index, option) in optionViews.enumerated() {
            option.isHidden = index >= display.options.count
            guard index < display.options.count else { continue }
            option.apply(
                display.options[index],
                title: content.titles.indices.contains(index) ? content.titles[index] : NSAttributedString(),
                font: content.titleFont,
                mode: display.mode,
                multiple: display.multiple,
                padding: content.optionPadding,
                horizontalPadding: content.optionHorizontalPadding,
                cornerRadius: content.optionCornerRadius,
                barStart: keepsBars ? .keep : animatesBars ? .onScreen : .target,
                transition: transition
            )
        }
        if animatesBars {
            pendingBarDuration = content.barDuration
        }

        if content.footerFont != previous?.footerFont || content.titleFont != previous?.titleFont {
            emptyLabel.font = content.titleFont
            summaryLabel.font = content.footerFont
            secondaryButton.configuration?.titleTextAttributesTransformer = Self.fontTransformer(content.footerFont)
            voteButton.configuration?.titleTextAttributesTransformer = Self.fontTransformer(content.titleFont.withWeight(.semibold))
        }
        summaryLabel.text = display.summary
        summaryText.setStyle(font: content.footerFont, color: .secondaryLabel)
        // 人数や残りの時間が変わったら、変わった数字だけを入れ替える。文全体を入れ替えると、どこが変わったのかが読めないため。
        summaryText.setText(
            display.summary,
            value: Double(display.count),
            animation: animates && content.barDuration > 0 ? (content.barDuration, 0) : nil
        )
        // 形を入れ替えるときは、替える前のボタンの複製を残してから、ボタンを新しい形にする。
        let leaving = modeChange == nil ? [] : snapshotsOfVisibleButtons()
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
        if modeChange != nil {
            // 新しいボタンは、替える前のボタンを消し終えてから浮かび上がらせる。重ねると、2つのボタンの文字が重なって見えるため。
            secondaryButton.alpha = 0
            voteButton.alpha = 0
            // 前の入れ替えをまだ始めていなければ、その複製も一緒に消す。上書きすると、消す動きが始まらずに複製が残るため。
            pendingFooterSwap = ((pendingFooterSwap?.leaving ?? []) + leaving, content.modeChangeDuration)
        }
        scheduleTransitions()
    }

    /// 見えているボタンの複製を、今の見え方のまま下の行に置く。替える前のボタンを、新しいボタンと別に消すため。
    private func snapshotsOfVisibleButtons() -> [UIView] {
        [secondaryButton, voteButton].compactMap { button -> UIView? in
            guard !button.isHidden, let snapshot = button.snapshotView(afterScreenUpdates: false) else { return nil }
            snapshot.frame = button.frame
            snapshot.alpha = CGFloat(button.layer.presentation()?.opacity ?? Float(button.alpha))
            snapshot.isUserInteractionEnabled = false
            footer.addSubview(snapshot)
            leavingButtons.append(snapshot)
            return snapshot
        }
    }

    private func scheduleTransitions() {
        guard !transitionsScheduled else { return }
        transitionsScheduled = true
        // タイムラインは動きを止めて描き直すことがあり、その中ではUIView.animateが動かないため、描き直しを終えてから動かす。
        DispatchQueue.main.async { [weak self] in
            self?.startPendingTransitions()
        }
    }

    /// `apply`で決めた動きを始める。
    private func startPendingTransitions() {
        transitionsScheduled = false
        if let duration = pendingBarDuration {
            pendingBarDuration = nil
            UIView.animate(springDuration: duration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                for option in self.optionViews where !option.isHidden {
                    option.showTargetFraction()
                }
            } completion: { finished in
                // 次の描き直しで取り消された動きの終わりでは、何もしない。取り消した側が、縮める棒を今の長さから動かし直しているため。
                guard finished else { return }
                for option in self.optionViews {
                    option.finishBarTransition()
                }
            }
        }
        for option in optionViews where !option.isHidden {
            option.startPendingTransition()
        }
        summaryText.startPendingTransition()
        if let swap = pendingFooterSwap {
            pendingFooterSwap = nil
            let half = swap.duration / 2
            UIView.animate(springDuration: half, bounce: 0, options: [.allowUserInteraction]) {
                for view in swap.leaving {
                    view.alpha = 0
                    view.transform = CGAffineTransform(scaleX: Self.leavingButtonScale, y: Self.leavingButtonScale)
                }
            } completion: { _ in
                for view in swap.leaving {
                    view.removeFromSuperview()
                }
                self.leavingButtons.removeAll { swap.leaving.contains($0) }
            }
            UIView.animate(springDuration: half, bounce: 0, initialSpringVelocity: 0, delay: half, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.secondaryButton.alpha = 1
                self.voteButton.alpha = 1
            }
        }
    }

    /// 浮かび上がる前の透明なボタンにも、触れたものを渡す。UIKitは透明なビューに触れたものを渡さないため、
    /// そのままでは「結果を見る」を押した直後に「投票に戻る」を押しても効かず、動きの途中の操作が止まる。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for button in [voteButton, secondaryButton] where !button.isHidden && button.isEnabled && button.alpha < Self.hitTestAlphaThreshold {
            if button.point(inside: convert(point, to: button), with: event) {
                return button
            }
        }
        return super.hitTest(point, with: event)
    }

    /// UIKitが触れたものを渡さない透明さ。これより薄いビューは、`hitTest`で飛ばされる。
    private static let hitTestAlphaThreshold: CGFloat = 0.01

    /// 替える前のボタンを消すときに縮める割合。
    private static let leavingButtonScale: CGFloat = 0.9

    /// 続いている動きをやめ、今の形のまま止める。
    /// 何も動かしていなければ何もしない。スクロールで行を使い回すたびに呼ばれ、動きを外す処理を毎回走らせると、流したときに落ちるフレームが増えたため（シミュレーターで測った）。
    private func cancelTransitions() {
        guard mayHaveTransitions else { return }
        mayHaveTransitions = false
        pendingBarDuration = nil
        pendingFooterSwap = nil
        for view in leavingButtons {
            view.removeFromSuperview()
        }
        leavingButtons.removeAll()
        for button in [secondaryButton, voteButton] {
            button.layer.removeAllAnimations()
            button.alpha = 1
        }
        summaryText.cancelTransition()
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
        optionViews.filter { !$0.isHidden } + [emptyLabel, summaryLabel, secondaryButton, voteButton].filter { !$0.isHidden }
    }

    /// 選択肢がないときに出している文字。テストで使う。
    var emptyMessage: String? { emptyLabel.isHidden ? nil : emptyLabel.text }

    /// 消している途中の、替える前のボタンの数。テストで、ボタンを入れ替えているかを確かめるために使う。
    var leavingButtonCount: Int { leavingButtons.count }
    /// 下の行の人数と締め切りの文字。テストで、数字を入れ替えたかを確かめるために使う。
    var summaryTextView: NumericTextOverlay { summaryText }
    /// 選択肢の行。テストで使う。
    var optionRows: [PollOptionView] { optionViews.filter { !$0.isHidden } }
    /// 下の行のボタン。テストで使う。
    var footerButtons: (secondary: UIButton, vote: UIButton) { (secondaryButton, voteButton) }
}

/// 投票の選択肢の1行。投票する形では押して選び、結果の形では後ろに割合の棒を敷く。
final class PollOptionView: UIControl {
    /// 投票する形と結果の形の入れ替わり。
    enum ModeChange {
        case toResults
        case toVoting
    }

    /// 描き直すときの動き。
    struct Transition {
        /// 同じ投票を描き直していて、動かしてよい。falseなら、続いている動きをやめて、動かさずに出す。
        var animates: Bool
        var modeChange: ModeChange?
        /// 棒を前の長さから動かす。動かすのは置く側が`showTargetFraction()`で行う。
        var animatesBars: Bool
        /// 割合の数字を入れ替える時間。棒が伸びる時間と同じ。
        var numberDuration: TimeInterval
        /// 形を入れ替えるときの、割合を浮かび上がらせる時間と、フチを移す時間。
        var modeChangeDuration: TimeInterval

        static let none = Transition(animates: false, modeChange: nil, animatesBars: false, numberDuration: 0, modeChangeDuration: 0)
    }

    let titleLabel = EmojiLabel()
    private let barView = UIView()
    private let indicatorView = UIImageView()
    /// 割合。大きさを決めるために置き、文字は`percentText`が描く。
    private let percentLabel = UILabel()
    private let percentText = NumericTextOverlay(alignment: .trailing)
    private let ownVoteView = UIImageView(image: UIImage(systemName: "checkmark"))
    private var variableConstraints: [NSLayoutConstraint] = []
    /// 棒の長さの割合。描いている長さと、伸ばした先の長さ。
    private var drawnFraction: CGFloat = 0
    private var targetFraction: CGFloat = 0
    private var mode: PollDisplay.Mode = .voting
    /// 次に始める形の入れ替わりと、その時間。
    private var pendingModeChange: (change: ModeChange, duration: TimeInterval)?
    /// 結果の形で、消える動きにかけた先頭の記号。隠すと動きが途中で消えるため、消えた見た目のまま出しておく。
    private var indicatorDisappeared = false
    /// 投票する形に戻るときに、割合を消し終えてから現す先頭の記号。
    private var indicatorAppearing = false
    /// 消える途中で投票する形に戻したので、その場から元に戻す先頭の記号。
    private var indicatorRestoring = false
    /// 投票する形に戻るときに、消している途中の割合。
    private var percentLeaving = false
    /// 結果の形へ替わるときに、現す動きにかけるチェックマーク。
    private var ownVoteAppearing = false
    /// 投票する形に戻るときに、縮めている途中の棒。縮め終えたら隠す。
    private var barShrinking = false
    /// 前に止めてから、同じ投票を描き直して動かしたことがある。止める処理が要るかを決める。
    private var mayHaveTransitions = false

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
        ownVoteView.contentMode = .center
        ownVoteView.tintColor = .tintColor
        for view in [titleLabel, indicatorView, percentLabel, ownVoteView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        percentText.overlay(on: percentLabel)
        // 枠の色はCGColorで、外観やティントカラーが変わっても描き直されないため、変わったら当て直す。
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.tintColor.cgColor
        }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        layer.borderColor = tintColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 棒をどの長さから描くか。
    enum BarStart {
        /// 動かさずに、目の長さで描く。
        case target
        /// 画面に見えている長さから動かす。棒が出ていなければ、棒のない状態から。動かすのは置く側が`showTargetFraction()`で行う。
        case onScreen
        /// 描いている長さのまま。伸ばしている途中なら、そのまま伸ばし続ける。
        case keep
    }

    func apply(_ option: PollDisplay.Option, title: NSAttributedString, font: UIFont, mode: PollDisplay.Mode, multiple: Bool, padding: CGFloat, horizontalPadding: CGFloat, cornerRadius: CGFloat, barStart: BarStart, transition: Transition = .none) {
        // 形が替わったのに入れ替わりの動きがないとき（時間を0にしたとき）も、続いている動きをやめる。消える動きにかけた記号が、そのまま消えて残るため。
        if !transition.animates || mode != self.mode && transition.modeChange == nil {
            cancelTransitions()
        }
        if transition.animates {
            mayHaveTransitions = true
        }
        let change = transition.modeChange
        self.mode = mode
        layer.cornerRadius = cornerRadius
        barView.layer.cornerRadius = cornerRadius
        titleLabel.attributedText = title
        let showsResults = mode == .results
        isUserInteractionEnabled = !showsResults

        // 先頭の記号を戻す動きは、割合を消すのを待つかで変わるので、割合を先に決める。
        let percentFont = font.withWeight(option.isLeading ? .semibold : .regular)
        applyPercent(option, font: percentFont, showsResults: showsResults, transition: transition)
        applyIndicator(option, font: font, multiple: multiple, showsResults: showsResults, change: change)
        applyBorder(selected: !showsResults && option.isSelected, change: change, duration: transition.modeChangeDuration)
        applyOwnVote(option, font: font, showsResults: showsResults, change: change)
        applyBar(option, showsResults: showsResults, start: barStart, transition: transition)
        if let change {
            pendingModeChange = (change, transition.modeChangeDuration)
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
            accessibilityValue = [option.fraction.map { Self.percentText($0) }, option.isOwnVote ? "投票済み" : nil].compactMap(\.self).joined(separator: "、")
        }
    }

    private static func percentText(_ fraction: Double) -> String {
        "\(percent(fraction))%"
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// 先頭の記号。結果の形へ替わるときは消える動きで消し、投票する形に戻るときは、割合を消し終えてから現す。
    private func applyIndicator(_ option: PollDisplay.Option, font: UIFont, multiple: Bool, showsResults: Bool, change: ModeChange?) {
        switch change {
        case .toResults:
            // 記号の画像は替えない。消える動きの途中で画像が替わると、動きが消えて一コマで消えるため。
            indicatorDisappeared = !indicatorView.isHidden
            indicatorAppearing = false
        case .toVoting:
            if indicatorDisappeared, !percentLeaving {
                // 割合が見える前に戻したら、消える途中の記号を、その場から元に戻す。
                indicatorRestoring = true
                indicatorAppearing = false
            } else if indicatorView.isHidden || indicatorDisappeared {
                indicatorView.removeAllSymbolEffects(animated: false)
                indicatorView.addSymbolEffect(.disappear, options: .nonRepeating, animated: false)
                indicatorAppearing = true
            }
            indicatorDisappeared = false
        case nil:
            break
        }
        if !showsResults {
            let symbol = switch (multiple, option.isSelected) {
            case (false, false): "circle"
            case (false, true): "checkmark.circle.fill"
            case (true, false): "square"
            case (true, true): "checkmark.square.fill"
            }
            indicatorView.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))
            indicatorView.tintColor = option.isSelected ? .tintColor : .secondaryLabel
        }
        indicatorView.isHidden = showsResults && !indicatorDisappeared
    }

    /// 選んだ選択肢のフチ。形を入れ替えるときは、今見えている太さから移す。
    private func applyBorder(selected: Bool, change: ModeChange?, duration: TimeInterval) {
        let oldWidth = change == nil ? layer.borderWidth : layer.presentation()?.borderWidth ?? layer.borderWidth
        layer.borderWidth = selected ? 1.5 : 0
        layer.borderColor = UIColor.tintColor.cgColor
        guard change != nil, oldWidth != layer.borderWidth else { return }
        let border = CASpringAnimation(perceptualDuration: duration, bounce: 0)
        border.keyPath = "borderWidth"
        border.fromValue = oldWidth
        border.toValue = layer.borderWidth
        border.duration = border.settlingDuration
        layer.add(border, forKey: Self.borderAnimationKey)
    }

    private static let borderAnimationKey = "pollBorder"
    /// これより薄い割合は、見えていないものとして扱う。
    private static let invisibleAlpha: CGFloat = 0.01

    /// 割合。結果の形へ替わるときは、先頭の記号が消えかけてから浮かび上がらせ、棒と一緒に0%から数字を入れ替える。投票する形に戻るときは消す。
    private func applyPercent(_ option: PollDisplay.Option, font: UIFont, showsResults: Bool, transition: Transition) {
        let color: UIColor = option.isLeading ? .label : .secondaryLabel
        percentText.setStyle(font: font, color: color)
        let shown = showsResults && option.fraction != nil
        let text = option.fraction.map { Self.percentText($0) } ?? ""
        let value = Double(option.fraction.map { Self.percent($0) } ?? 0)
        switch transition.modeChange {
        case .toResults where shown:
            percentLeaving = false
            percentText.setText(Self.percentText(0), value: 0, animation: nil)
            percentAlpha = 0
            percentText.setText(text, value: value, animation: (transition.numberDuration, transition.modeChangeDuration / 2))
        case .toVoting where percentShown:
            // 浮かび上がる前に戻したときは、見えていないので、消すのを待たずに隠す。
            let opacity = percentLabel.layer.presentation()?.opacity ?? Float(percentLabel.alpha)
            percentLeaving = opacity >= Float(Self.invisibleAlpha)
            if !percentLeaving {
                removePercentAnimations()
                percentAlpha = 1
            }
        default:
            if shown {
                percentLeaving = false
                percentText.setText(text, value: value, animation: transition.animates && transition.numberDuration > 0 ? (transition.numberDuration, 0) : nil)
            }
        }
        percentShown = shown || percentLeaving
    }

    /// 割合の濃さ。ふだん文字を描くラベルと、数字を入れ替える間だけ描く重ねた文字の両方に当てる。動きの中で当てると、両方が一緒に動く。
    private var percentAlpha: CGFloat {
        get { percentLabel.alpha }
        set {
            percentLabel.alpha = newValue
            percentText.alpha = newValue
        }
    }

    /// 割合を出している。ラベルと重ねた文字の両方を出し入れする。
    private var percentShown: Bool {
        get { !percentLabel.isHidden }
        set {
            percentLabel.isHidden = !newValue
            percentText.isHidden = !newValue
        }
    }

    private func removePercentAnimations() {
        percentLabel.layer.removeAllAnimations()
        percentText.layer.removeAllAnimations()
    }

    /// 自分が票を入れたチェックマーク。結果の形へ替わるときは、現す動きで出す。
    private func applyOwnVote(_ option: PollDisplay.Option, font: UIFont, showsResults: Bool, change: ModeChange?) {
        ownVoteView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font.withWeight(.semibold), scale: .small)
        let shown = showsResults && option.isOwnVote
        if change == .toResults, shown, ownVoteView.isHidden {
            ownVoteView.removeAllSymbolEffects(animated: false)
            ownVoteView.addSymbolEffect(.disappear, options: .nonRepeating, animated: false)
            ownVoteAppearing = true
        }
        ownVoteView.isHidden = !shown
    }

    private func applyBar(_ option: PollDisplay.Option, showsResults: Bool, start: BarStart, transition: Transition) {
        barView.backgroundColor = option.isLeading ? UIColor.tintColor.withAlphaComponent(0.25) : .systemFill
        let onScreen = start != .onScreen || barView.isHidden ? 0 : (barView.layer.presentation()?.bounds.width ?? barView.bounds.width) / max(bounds.width, 1)
        barShrinking = transition.modeChange == .toVoting && transition.animatesBars && !barView.isHidden || barShrinking && !showsResults
        barView.isHidden = option.fraction == nil || !showsResults && !barShrinking
        targetFraction = showsResults ? CGFloat(option.fraction ?? 0) : 0
        switch start {
        case .target: drawnFraction = targetFraction
        case .onScreen: drawnFraction = onScreen
        case .keep: break
        }
        if start != .keep, barView.layer.animationKeys() != nil {
            barView.layer.removeAllAnimations()
        }
    }

    /// `apply`で決めた形の入れ替わりを始める。並べ終えてから呼ぶ。
    func startPendingTransition() {
        percentText.startPendingTransition()
        guard let pending = pendingModeChange else { return }
        pendingModeChange = nil
        switch pending.change {
        case .toResults:
            if indicatorDisappeared {
                indicatorView.addSymbolEffect(.disappear, options: .nonRepeating, animated: true)
            }
            if ownVoteAppearing {
                ownVoteAppearing = false
                ownVoteView.addSymbolEffect(.appear, options: .nonRepeating, animated: true)
            }
            // 消える途中の記号と重ならないよう、記号が消えかけてから浮かび上がらせる。
            UIView.animate(springDuration: pending.duration, bounce: 0, initialSpringVelocity: 0, delay: pending.duration / 2, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.percentAlpha = 1
            }
        case .toVoting:
            if indicatorRestoring {
                indicatorRestoring = false
                indicatorView.removeAllSymbolEffects(animated: true)
            }
            guard percentLeaving else {
                showAppearingIndicator()
                return
            }
            // 消す時間は、今見えている濃さに合わせて縮める。結果を見た直後に戻したときは割合がまだほとんど見えておらず、
            // 決まった時間だけ待つと、記号も割合もない選択肢が続くため（時間を伸ばした録画で、記号を出すまで空のままだった）。
            let opacity = CGFloat(percentLabel.layer.presentation()?.opacity ?? Float(percentLabel.alpha))
            UIView.animate(springDuration: pending.duration / 2 * opacity, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.percentAlpha = 0
            } completion: { _ in
                // 消している間に結果の形へ戻っていたら、そちらに任せる。
                guard self.percentLeaving, self.mode == .voting else { return }
                self.percentLeaving = false
                self.percentShown = false
                self.percentAlpha = 1
                self.showAppearingIndicator()
            }
        }
    }

    private func showAppearingIndicator() {
        guard indicatorAppearing else { return }
        indicatorAppearing = false
        indicatorView.addSymbolEffect(.appear, options: .nonRepeating, animated: true)
    }

    /// 棒を動かし終えた。投票する形に戻って縮め終えた棒を隠す。
    func finishBarTransition() {
        guard barShrinking, mode == .voting else { return }
        barShrinking = false
        barView.isHidden = true
    }

    /// 続いている動きをやめ、今の形のまま止める。
    /// 何も動かしていなければ何もしない。スクロールで行を使い回すたびに選択肢ごとに呼ばれ、SF Symbolsの動きや層の動きを外す処理を毎回走らせると、流したときに落ちるフレームが増えたため（シミュレーターで測った）。
    private func cancelTransitions() {
        guard mayHaveTransitions else { return }
        mayHaveTransitions = false
        pendingModeChange = nil
        indicatorDisappeared = false
        indicatorAppearing = false
        indicatorRestoring = false
        percentLeaving = false
        ownVoteAppearing = false
        barShrinking = false
        indicatorView.removeAllSymbolEffects(animated: false)
        ownVoteView.removeAllSymbolEffects(animated: false)
        layer.removeAnimation(forKey: Self.borderAnimationKey)
        removePercentAnimations()
        percentAlpha = 1
        percentText.cancelTransition()
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

    /// 先頭の記号を出している。消える動きにかけて、消えた見た目のまま出しているときも含む。テストで使う。
    var showsIndicator: Bool { !indicatorView.isHidden }
    /// 先頭の記号を、消える動きにかけたまま出している。テストで使う。
    var indicatorIsDisappeared: Bool { indicatorDisappeared }
    /// 割合の文字。テストで使う。
    var percentTextView: NumericTextOverlay { percentText }
    /// 割合の棒を出している。テストで使う。
    var showsBar: Bool { !barView.isHidden }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

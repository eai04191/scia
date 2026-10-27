import UIKit

/// 知らせを1件描くガラスのカプセル。並べ方と消えるまでの時計は`NoticeStackView`が持つ。
///
/// UIButtonの構成では、先頭の処理中のインジケーターと末尾の「›」を両方置けず、文言が切れたときに件数と「›」を残せないため、自前で組む。
final class NoticeChip: UIControl {
    /// 押せる範囲の最小の大きさ。見た目より小さければ、外側まで広げる。
    static let minimumHitSize: CGFloat = 44

    /// 出てくるときの濃さと大きさを動かすための包み。ガラスの濃さを変えても、アニメーションにならないため。
    private let appearanceView = UIView()
    private let effectView = UIVisualEffectView(effect: UIGlassEffect())
    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let disclosureView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private(set) var notice: Notice?

    /// 指が触れているか、VoiceOverの読み上げ位置が乗っている。
    private(set) var isHeld = false
    private var isTouching = false {
        didSet { updateHeld() }
    }
    private var isAccessibilityFocused = false {
        didSet { updateHeld() }
    }
    /// 上へスワイプしてしまう途中。指で動かしている間も、触れているものとして扱う。
    var isPanning = false {
        didSet { updateHeld() }
    }
    /// スワイプし始めたときに、チップを上下にずらして見せていた量。戻る途中につかみ直したら、見えている位置から指に合わせる。
    var panStartOffset: CGFloat = 0
    /// `isHeld`が変わったときに呼ぶ。
    var onHoldChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        effectView.cornerConfiguration = .capsule()
        effectView.isUserInteractionEnabled = false
        // 文言を入れ替えながら大きさを変える途中に、古い文言や新しい文言がガラスの外にはみ出さないよう、中身をガラスの形で切り抜く。
        effectView.contentView.clipsToBounds = true
        effectView.contentView.layer.cornerCurve = .continuous
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        iconView.tintColor = .label
        spinner.hidesWhenStopped = true
        // 進み具合の数字が変わるたびに幅が揺れないよう、数字の幅をそろえる。
        titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        // 長い文言は2行まで折り返し、それでも収まらなければ2行目の末尾を切る。
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel
        disclosureView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        disclosureView.tintColor = .secondaryLabel
        // 文言が長くても、件数と「›」は残し、文言だけを切る。
        for view in [iconView, spinner, countLabel, disclosureView] as [UIView] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [iconView, spinner, titleLabel, countLabel, disclosureView])
        stack.spacing = 6
        stack.alignment = .center
        stack.setCustomSpacing(4, after: countLabel)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(stack)
        appearanceView.isUserInteractionEnabled = false
        appearanceView.translatesAutoresizingMaskIntoConstraints = false
        appearanceView.addSubview(effectView)
        addSubview(appearanceView)
        NSLayoutConstraint.activate([
            appearanceView.topAnchor.constraint(equalTo: topAnchor),
            appearanceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            appearanceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            appearanceView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.topAnchor.constraint(equalTo: appearanceView.topAnchor),
            effectView.leadingAnchor.constraint(equalTo: appearanceView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: appearanceView.trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: appearanceView.bottomAnchor),
            stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -16),
        ])
        isAccessibilityElement = true
        addAction(UIAction { [weak self] _ in self?.perform() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 1行に収まればその幅にし、収まらなければ`maxWidth`いっぱいにして、2行まで折り返した高さを返す。
    /// 折り返せるラベルは、1行のときの幅も、幅を決めたときの折り返しも自分では測れないため、1行に限って測ってから、収まらないときだけ文言に使える幅を渡して測り直す。
    func fittingSize(maxWidth: CGFloat) -> CGSize {
        titleLabel.numberOfLines = 1
        titleLabel.preferredMaxLayoutWidth = 0
        let oneLine = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let oneLineTitleWidth = titleLabel.intrinsicContentSize.width
        titleLabel.numberOfLines = 2
        guard oneLine.width > maxWidth else { return oneLine }
        // 文言のほかのアイコン、件数、「›」、余白の幅は、1行のときから変わらない。
        let otherWidth = oneLine.width - oneLineTitleWidth
        titleLabel.preferredMaxLayoutWidth = max(maxWidth - otherWidth, 0)
        let wrapped = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: maxWidth, height: wrapped.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // ガラスのカプセルと同じ丸みで切り抜く。大きさを変える動きの中で呼ばれれば、丸みも一緒に動く。
        effectView.contentView.layer.cornerRadius = bounds.height / 2
    }

    /// 薄く少し小さい状態から出てくる。チップそのものの濃さと変形は、並べる側がスワイプや隠すのに使うため、ガラスの包みに付けて動かす。
    /// チップに付けると、出てくる途中に指で触れたとき、指に合わせる変形で出てくる動きが止まり、大きさや濃さが1コマで替わる。
    func animateAppearance(duration: TimeInterval) {
        appearanceView.alpha = 0
        // 視差効果を減らす設定では、大きさを変えずに薄くするだけにする。
        if !UIAccessibility.isReduceMotionEnabled {
            appearanceView.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.appearanceView.alpha = 1
            self.appearanceView.transform = .identity
        }
    }

    /// 中身を、古い文言を薄くしながら新しい文言に入れ替える。チップ全体ではなくガラスの中身だけを入れ替え、ガラスの形の外には描かない。
    func crossfade(to notice: Notice, duration: TimeInterval) {
        UIView.transition(with: effectView.contentView, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
            self.apply(notice)
        }
    }

    /// 中身を描き直す。読み上げは並べる側が`announce`で行う。
    func apply(_ notice: Notice) {
        self.notice = notice
        titleLabel.text = notice.text
        switch notice.kind {
        case .progress:
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimating()
        case .success, .failure:
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: notice.kind == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        case .info:
            // 成功でも失敗でもないため、どちらのアイコンとも取り違えないようアイコンを付けず、文言だけで伝える。
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = true
        }
        countLabel.text = notice.additionalCount > 0 ? "+\(notice.additionalCount)件" : nil
        countLabel.isHidden = notice.additionalCount == 0
        let hint: String?
        switch notice.action {
        case .none:
            hint = nil
            disclosureView.isHidden = true
        case .disclosure(let text, _):
            hint = text
            disclosureView.isHidden = false
        case .immediate(let text, _):
            hint = text
            disclosureView.isHidden = true
        }
        // 「›」は読ませず、押すと何が起きるかをヒントで伝える。
        accessibilityLabel = notice.additionalCount > 0 ? "\(notice.title)、ほかに\(notice.additionalCount)件" : notice.title
        accessibilityValue = notice.value
        accessibilityHint = hint
        var traits: UIAccessibilityTraits = notice.isActionable ? .button : .staticText
        if notice.kind == .progress {
            traits.insert(.updatesFrequently)
        }
        accessibilityTraits = traits
    }

    /// 初めて出したときと、文言か種類か件数が変わったときに、VoiceOverで読み上げる。進み具合が変わっただけでは読み上げない。
    func announce(changingFrom previous: Notice?) {
        guard let notice else { return }
        guard previous == nil || previous?.title != notice.title || previous?.kind != notice.kind || previous?.additionalCount != notice.additionalCount else { return }
        UIAccessibility.post(notification: .announcement, argument: accessibilityLabel)
    }

    private func perform() {
        switch notice?.action {
        case .some(.disclosure(_, let handler)), .some(.immediate(_, let handler)): handler()
        case .some(.none), nil: break
        }
    }

    override func accessibilityActivate() -> Bool {
        guard notice?.isActionable == true else { return false }
        perform()
        return true
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        isAccessibilityFocused = true
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        isAccessibilityFocused = false
    }

    // MARK: 触れている間

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isTouching = true
        return super.beginTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        let isInside = touch.map { point(inside: $0.location(in: self), with: event) } ?? false
        isTouching = false
        if isInside {
            sendActions(for: .primaryActionTriggered)
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isTouching = false
    }

    /// 押せないチップも、上へスワイプしてしまえるよう触れたものは受ける。押したときに薄くするのは、押せるときだけ。
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, notice?.isActionable == true || !isHighlighted else { return }
            UIView.animate(withDuration: isHighlighted ? 0 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.effectView.contentView.alpha = self.isHighlighted ? 0.5 : 1
            }
        }
    }

    private func updateHeld() {
        let held = isTouching || isAccessibilityFocused || isPanning
        guard held != isHeld else { return }
        isHeld = held
        onHoldChange?()
    }

    /// 見た目が44ptに満たなくても、44pt四方までは押せるようにする。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (Self.minimumHitSize - bounds.width) / 2)
        let dy = max(0, (Self.minimumHitSize - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

import UIKit

/// チップの列の中身。一番上にログインし直しの段、その下に出たままのチップと数秒で消えるチップを縦に並べる。
/// 決まりはdocs/notices.mdの「チップ」と「場面ごと」のログインし直しにある。置く場所は`NoticeOverlay`が決める。
///
/// 幅は置く側が決める。高さはチップの中身によらず、ログインし直しの段の有無だけで決まる。チップのないところは触れても下へ通す。
final class NoticeColumnView: UIView {
    let reauthenticationButton = ReauthenticationButton()
    let stack = NoticeStackView()
    private let spacing: CGFloat = 8
    /// ログインし直しの段の場所を取っているか。消している途中は取らない。
    private(set) var showsReauthentication = false
    /// 指が触れている間に段が出入りして、チップの並べ直しを離すまで待っている。
    private var needsStackPlacement = false
    private var isChromeHidden = false
    var animationDuration: TimeInterval {
        get { stack.animationDuration }
        set { stack.animationDuration = newValue }
    }

    /// どれかに指が触れているか、VoiceOverの読み上げ位置が乗っている。置く側は、この間は列を動かさない。
    var isHeld: Bool { stack.isHeld || reauthenticationButton.isHeldByUser }
    var onHoldChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        reauthenticationButton.isHidden = true
        reauthenticationButton.alpha = 0
        addSubview(reauthenticationButton)
        addSubview(stack)
        stack.onHoldChange = { [weak self] in self?.holdDidChange() }
        reauthenticationButton.onHoldChange = { [weak self] in self?.holdDidChange() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ログインし直しの段を出すか、中身を替える。nilなら消す。出入りでチップの並びが上下するため、動かして詰める。
    func setReauthentication(_ reauthentication: NoticeCenter.Reauthentication?, animated: Bool) {
        if let reauthentication {
            reauthenticationButton.apply(reauthentication)
        }
        let shows = reauthentication != nil
        guard shows != showsReauthentication else { return }
        showsReauthentication = shows
        let animates = animated && window != nil && !UIAccessibility.isReduceMotionEnabled
        if shows {
            reauthenticationButton.isHidden = false
            UIView.performWithoutAnimation {
                placeReauthentication()
            }
        }
        let apply = {
            self.reauthenticationButton.alpha = self.reauthenticationAlpha
            self.placeStackUnlessHeld()
        }
        let completion = { (_: Bool) in
            if !self.showsReauthentication {
                self.reauthenticationButton.isHidden = true
            }
        }
        if animates {
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: apply, completion: completion)
        } else {
            apply()
            completion(true)
        }
    }

    /// ビューアで画面をタップしてボタン類を隠したか、出し直した。ログインし直しの段と出たままの失敗を、場所を空けたまま薄くする。
    func setChromeHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != isChromeHidden else { return }
        isChromeHidden = hidden
        stack.setChromeHidden(hidden, animated: animated)
        reauthenticationButton.isUserInteractionEnabled = !hidden
        let apply = { self.reauthenticationButton.alpha = self.reauthenticationAlpha }
        if animated {
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    private var reauthenticationAlpha: CGFloat {
        showsReauthentication && !isChromeHidden ? 1 : 0
    }

    // MARK: 並べ方

    private func reauthenticationSize(width: CGFloat) -> CGSize {
        let fitting = reauthenticationButton.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: min(fitting.width, width), height: fitting.height)
    }

    private func placeReauthentication() {
        let size = reauthenticationSize(width: bounds.width)
        reauthenticationButton.bounds.size = size
        reauthenticationButton.center = CGPoint(x: bounds.midX, y: size.height / 2)
    }

    /// 指が触れている間は、押そうとしているチップが逃げないよう並べ直さない。離したら並べ直す。
    private func placeStackUnlessHeld() {
        guard !stack.isHeld else {
            needsStackPlacement = true
            return
        }
        needsStackPlacement = false
        placeStack()
    }

    private func holdDidChange() {
        if !stack.isHeld, needsStackPlacement {
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.placeStackUnlessHeld()
            }
        }
        onHoldChange?()
    }

    private func placeStack() {
        let top = showsReauthentication ? reauthenticationSize(width: bounds.width).height + spacing : 0
        let height = stack.intrinsicContentSize.height
        stack.bounds.size = CGSize(width: bounds.width, height: height)
        stack.center = CGPoint(x: bounds.midX, y: top + height / 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeReauthentication()
        placeStackUnlessHeld()
    }

    /// 列の高さ。ログインし直しの段があれば、その分だけ高い。
    func height(forWidth width: CGFloat) -> CGFloat {
        let stackHeight = stack.intrinsicContentSize.height
        guard showsReauthentication else { return stackHeight }
        return reauthenticationSize(width: width).height + spacing + stackHeight
    }

    // MARK: 触れたもの

    /// チップとログインし直しの段の上だけを受け、ほかは下の画面へ通す。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        let button = reauthenticationButton
        if showsReauthentication, button.isUserInteractionEnabled, button.point(inside: convert(point, to: button), with: event) {
            return button
        }
        return stack.hitTest(convert(point, to: stack), with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitTest(point, with: event) != nil
    }
}

/// ログインし直しの段。オレンジのガラスのカプセルに、1行目に「ログインし直してください」、2行目にアカウント名を小さく出す。
/// 1行のチップでは短いアカウント名でも切れるため、チップとは別の形にする。押すとすぐログインし直しを始める。
final class ReauthenticationButton: UIButton {
    private var action: (@MainActor () -> Void)?
    /// 指が触れているか、VoiceOverの読み上げ位置が乗っている。
    private(set) var isHeldByUser = false
    private var isTouching = false {
        didSet { updateHeld() }
    }
    private var isAccessibilityFocused = false {
        didSet { updateHeld() }
    }
    var onHoldChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemOrange
        configuration.image = UIImage(systemName: "person.crop.circle.badge.exclamationmark")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        configuration.imagePadding = 8
        configuration.titleLineBreakMode = .byTruncatingTail
        // アカウント名は省かず、長ければ真ん中を省く。ユーザー名とサーバー名の両方の端を残すため。
        configuration.subtitleLineBreakMode = .byTruncatingMiddle
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        var title = AttributedString("ログインし直してください")
        title.font = .preferredFont(forTextStyle: .subheadline)
        configuration.attributedTitle = title
        self.configuration = configuration
        addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        accessibilityHint = "ログインし直します。"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ reauthentication: NoticeCenter.Reauthentication) {
        action = reauthentication.action
        configuration?.subtitle = reauthentication.handle
        configuration?.showsActivityIndicator = reauthentication.isInProgress
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isTouching = true
        return super.beginTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        isTouching = false
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isTouching = false
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        isAccessibilityFocused = true
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        isAccessibilityFocused = false
    }

    private func updateHeld() {
        let held = isTouching || isAccessibilityFocused
        guard held != isHeldByUser else { return }
        isHeldByUser = held
        onHoldChange?()
    }
}

import os
import SciaCore
import UIKit

/// 投稿の一番下に置く、返信やお気に入りなどのボタンを横に並べたアクションバー。決まりはdocs/post-action-bar.mdにある。
/// タイムラインの投稿は自分で大きさを測るセルの中にあり、投稿ごとに`UIHostingController`を載せるとスクロールのたびに組み立てが重くなるため、UIKitで作る。
struct PostActionBarContent: Equatable {
    var buttons: [PostActionBarButton]
    var iconSize: CGFloat
    /// アイコンの上下の余白。ボタンの押せる高さは、アイコンにこの余白を足したものになる。
    var padding: CGFloat
    var countFont: UIFont
    /// ライトモードで、したお気に入りを黄色で描く。オフなら橙。光と同じ色にする。
    var lightFavouriteIsYellow: Bool
    /// ボタンの押せる範囲を、アイコンの左端から左（右から左へ書く言語では右）へ広げる長さ。左隣のボタンと重なる部分は、このボタンが受ける。
    var leadingHitReach: CGFloat
    /// ボタンを並べている投稿。同じ投稿のまま状態が変わったときだけ、記号を変形でつなぐ。
    var statusID: Status.ID?
}

final class PostActionBarView: UIView {
    /// ボタンが押されたときに、その項目と、押したボタンを渡して呼ぶ。
    var onPress: ((PostActionBarItem, UIView) -> Void)?
    /// ボタンを長押しして出すメニューの対象。長押しでメニューを出す項目（`PostActionBarItem.longPressItems`）でだけ呼ぶ。nilならメニューを出さない。
    var longPressTarget: ((PostActionBarItem) -> (any ObjectActionTarget)?)? {
        didSet { applyLongPressTargets() }
    }

    private let stack = UIStackView()
    private var buttonViews: [PostActionBarButtonView] = []
    private(set) var content: PostActionBarContent?
    /// バーの上と下にある、押せる範囲を広げてよい空きの高さ。
    var hitSpace = PostActionBarButtonView.HitSpace() {
        didSet {
            for view in buttonViews {
                view.hitSpace = hitSpace
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "アクションバー"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: PostActionBarContent) {
        let isSameStatus = self.content?.statusID != nil && self.content?.statusID == content.statusID && window != nil
        self.content = content
        while buttonViews.count < content.buttons.count {
            let view = PostActionBarButtonView()
            view.addAction(UIAction { [weak self, weak view] _ in
                guard let self, let view, let item = view.button?.item else { return }
                let start = AppDependencies.mediaTime()
                onPress?(item, view)
                let end = AppDependencies.mediaTime()
                // 指を離してから押した処理が動くまでと、処理にかかった時間。押しても変わらないと感じたときに、メインスレッドが詰まっていたかを見る。
                let sinceTouchUp = view.consumeTouchEnd().map { start - $0 } ?? -1
                PostActionBarButtonView.logger.info("action bar press item=\(item.rawValue, privacy: .public) sinceTouchUp=\(sinceTouchUp, privacy: .public) work=\(end - start, privacy: .public)")
            }, for: .touchUpInside)
            view.hitSpace = hitSpace
            buttonViews.append(view)
            stack.addArrangedSubview(view)
        }
        for (index, view) in buttonViews.enumerated() {
            guard content.buttons.indices.contains(index) else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            // 並びが変わって別の項目になったボタンは、変形でつながず切り替える。
            let animates = isSameStatus && view.button?.item == content.buttons[index].item
            view.apply(content.buttons[index], style: content, animatesSymbol: animates)
        }
        applyLongPressTargets()
    }

    /// 長押しでメニューを出すボタンにだけ、その対象を付ける。ボタンは持ち上げず、押した位置にメニューだけを出す（docs/menus.mdの「持ち上げ方」）。
    private func applyLongPressTargets() {
        for view in buttonViews {
            guard let item = view.button?.item, !view.isHidden, !item.longPressItems.isEmpty, let target = longPressTarget?(item) else {
                view.longPressInteraction?.target = nil
                continue
            }
            let interaction = view.longPressInteraction ?? ObjectInteraction(on: view, tapsSelf: false, lift: .none)
            view.longPressInteraction = interaction
            interaction.target = target
        }
    }

    /// ボタンのアイコンの枠。「投稿の見た目」のプレビューで示す。`space`の座標で返す。
    func iconFrames(in space: UIView) -> [CGRect] {
        shownButtons.map { $0.iconFrame(in: space) }
    }

    /// ボタンの、アイコンの上と下の余白の帯。
    func paddingBands(in space: UIView) -> [CGRect] {
        shownButtons.flatMap { $0.paddingBands(in: space) }
    }

    /// 添えた件数の枠。件数がなければ空。
    func countFrames(in space: UIView) -> [CGRect] {
        shownButtons.compactMap { $0.countFrame(in: space) }
    }

    /// 画面に出さずに、アクションバーを一度描く。初めて開く前に、記号の画像と文字を描く重さを済ませておくため（`TimelineViewController.prepareActionBarIfNeeded`）。
    func drawForPreparation() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        _ = UIGraphicsImageRenderer(bounds: bounds).image { context in
            layer.render(in: context.cgContext)
        }
    }

    /// 出しているボタン。読み上げの要素に使う。
    var shownButtons: [PostActionBarButtonView] {
        buttonViews.filter { !$0.isHidden }
    }

    /// バーの枠の外も含めて、`point`（`space`の座標）を受けるボタン。
    /// バーの枠の外の点は、親からの`hitTest`がボタンまで降りてこないので、投稿の中身が空きを押されたときにこれで探す。
    func button(at point: CGPoint, in space: UIView, with event: UIEvent?) -> UIView? {
        // 左へ広げた範囲は左隣のボタンと重なる。親の`hitTest`と同じく、あとに並ぶボタンから探して、広げた側が受ける。
        shownButtons.reversed().lazy.compactMap { $0.hitTest(space.convert(point, to: $0), with: event) }.first
    }
}

/// アクションバーの1つのボタン。アイコンを左に寄せ、件数を右に添える。
final class PostActionBarButtonView: UIControl {
    static let logger = SciaLog.logger(category: "actionBar")
    private let iconView = UIImageView()
    private let countLabel = UILabel()
    private var iconTop: NSLayoutConstraint?
    private var iconBottom: NSLayoutConstraint?
    private(set) var button: PostActionBarButton?
    private var lightFavouriteIsYellow = false
    private var leadingHitReach: CGFloat = 0
    /// ボタンを長押しして出すメニュー。長押しでメニューを出す項目のボタンにだけ付ける。
    var longPressInteraction: ObjectInteraction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isUserInteractionEnabled = false
        // 件数が幅に入りきらないときは、文字を縮める。縮めても入らなければ、切れた数を見せないよう、件数を出さない（layoutSubviews）。
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.6
        countLabel.baselineAdjustment = .alignCenters
        countLabel.lineBreakMode = .byClipping
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(iconView)
        addSubview(countLabel)
        let top = iconView.topAnchor.constraint(equalTo: topAnchor)
        let bottom = bottomAnchor.constraint(equalTo: iconView.bottomAnchor)
        iconTop = top
        iconBottom = bottom
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            top,
            bottom,
            countLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.countTrailingInset),
            countLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PostActionBarButtonView, _) in view.applyColor() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 件数が、文字を一番小さくしても幅に入らなければ隠す。隠しても並べ方は変わらないので、並べ直しは起きない。読み上げでは件数を読む。
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let text = countLabel.text, let font = countLabel.font, button?.count != nil else {
            countLabel.isHidden = true
            return
        }
        let smallest = font.withSize(font.pointSize * countLabel.minimumScaleFactor)
        let needed = ceil((text as NSString).size(withAttributes: [.font: smallest]).width)
        let available = bounds.width - countLabel.frame.minX - Self.countTrailingInset
        countLabel.isHidden = needed > available
    }

    /// 件数の右端と、ボタンの右端のあいだ。
    private static let countTrailingInset: CGFloat = 4

    /// VoiceOverで実行したときも、押したときと同じ処理を送る。自作の`UIControl`は、実行しても何も送らないため。
    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    private var touchBeganAt: TimeInterval?
    /// 指を離した時刻（`UITouch.timestamp`と同じ、起動からの秒）。押した処理が1回だけ読む。
    /// VoiceOverの実行はタッチを通らないので、前のタップの時刻を読まないよう、読んだら消す。
    private var touchEndedAt: TimeInterval?

    func consumeTouchEnd() -> TimeInterval? {
        defer { touchEndedAt = nil }
        return touchEndedAt
    }
    private var lastDeceleratingTouch: TimeInterval?

    /// ボタンの上と下にある、押せる範囲を広げてよい空きの高さ。
    struct HitSpace: Equatable {
        var above: CGFloat = 0
        var below: CGFloat = 0
    }

    var hitSpace = HitSpace()
    /// 押せる高さの上限。HIGの最小のタップ領域に合わせる。
    private static let maximumHitHeight: CGFloat = 44

    /// 指を離した位置の判定にも使うので、`hitTest`だけでなくここで広げる。アイコンはボタンの上下の中央にあるので、中央から同じ長さまで広げる。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let reach = max(Self.maximumHitHeight - bounds.height, 0) / 2
        // ボタンが多くて狭いときは、アイコンの横の空きの半分で止める。右隣のボタンも同じだけ広げてくるので、止めないとアイコンの右に押せる範囲が残らない。
        let leadingReach = min(leadingHitReach, max(bounds.width - iconView.frame.width, 0) / 2)
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return bounds
            .inset(by: UIEdgeInsets(
                top: -min(hitSpace.above, reach),
                left: isRightToLeft ? 0 : -leadingReach,
                bottom: -min(hitSpace.below, reach),
                right: isRightToLeft ? -leadingReach : 0
            ))
            .contains(point)
    }

    /// 慣性で流れているタイムラインに触れると、UIKitはスクロールを止めるだけで、ボタンにタッチを渡さないことがある。押しても何も起きなかったときに、このあとに押した記録が続くかで見分ける。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self, let event, event.type == .touches, event.timestamp != lastDeceleratingTouch, enclosingScrollView?.isDecelerating == true {
            lastDeceleratingTouch = event.timestamp
            Self.logger.notice("action bar touch landed while scrolling decelerates item=\(self.button?.item.rawValue ?? "nil", privacy: .public)")
        }
        return hit
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchBeganAt = touch.timestamp
        return super.beginTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        touchEndedAt = touch?.timestamp
        super.endTracking(touch, with: event)
    }

    /// スクロールや長押しにタッチを取られると、指を離しても押したことにならない。どれに取られたかを残す。
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        let heldFor = touchBeganAt.map { AppDependencies.mediaTime() - $0 } ?? -1
        let active: Set<UIGestureRecognizer.State> = [.began, .changed, .ended]
        let gestures = (gestureRecognizers ?? []).filter { active.contains($0.state) }.map { String(describing: type(of: $0)) }
        Self.logger.notice("action bar touch cancelled item=\(self.button?.item.rawValue ?? "nil", privacy: .public) heldFor=\(heldFor, privacy: .public) scrolling=\(self.enclosingScrollView?.isDragging == true, privacy: .public) gestures=\(gestures.joined(separator: ","), privacy: .public)")
    }

    private var enclosingScrollView: UIScrollView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? UIScrollView }.first
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.4 : 1 }
    }

    func apply(_ button: PostActionBarButton, style: PostActionBarContent, animatesSymbol: Bool) {
        let previous = self.button
        self.button = button
        lightFavouriteIsYellow = style.lightFavouriteIsYellow
        leadingHitReach = style.leadingHitReach
        iconTop?.constant = style.padding
        iconBottom?.constant = style.padding
        let configuration = UIImage.SymbolConfiguration(pointSize: style.iconSize)
        if let image = UIImage(systemName: button.symbolName, withConfiguration: configuration) {
            if animatesSymbol, previous?.symbolName != button.symbolName, !UIAccessibility.isReduceMotionEnabled {
                // 状態を表すアイコンなので、同じものの状態が変わったと分かるよう変形させる（docs/vision.mdの「画面の中のものの振る舞い」）。
                iconView.setSymbolImage(image, contentTransition: .replace)
            } else {
                iconView.image = image
            }
        }
        countLabel.font = style.countFont
        countLabel.text = button.count.map(PostActionBarButton.countText)
        countLabel.isHidden = button.count == nil
        setNeedsLayout()
        applyColor()
        accessibilityLabel = button.title
        accessibilityValue = [button.isOn ? "済み" : nil, button.count.map { "\($0.formatted())件" }].compactMap(\.self).joined(separator: "、")
        accessibilityTraits = button.isOn ? [.button, .selected] : .button
    }

    private func applyColor() {
        guard let button else { return }
        let color: UIColor = if !button.isAvailable {
            .tertiaryLabel
        } else {
            switch button.tint {
            case .none: .secondaryLabel
            case .reblog: .systemGreen
            // 光と同じく、ダークでは黄色、ライトでは選んだ色にする（ReactionGlowView）。
            case .favourite: traitCollection.userInterfaceStyle == .dark || lightFavouriteIsYellow ? .systemYellow : .systemOrange
            case .bookmark: .systemRed
            }
        }
        iconView.tintColor = color
        countLabel.textColor = color
    }

    func iconFrame(in space: UIView) -> CGRect {
        iconView.convert(iconView.bounds, to: space)
    }

    func paddingBands(in space: UIView) -> [CGRect] {
        let icon = iconView.frame
        let top = CGRect(x: icon.minX, y: 0, width: icon.width, height: icon.minY)
        let bottom = CGRect(x: icon.minX, y: icon.maxY, width: icon.width, height: bounds.height - icon.maxY)
        return [top, bottom].map { convert($0, to: space) }
    }

    func countFrame(in space: UIView) -> CGRect? {
        countLabel.isHidden ? nil : countLabel.convert(countLabel.bounds, to: space)
    }
}

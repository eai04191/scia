import SciaCore
import UIKit

/// 動画のページに重ねる、再生の操作の部品。中央に10秒戻る・再生と一時停止・10秒進むのボタン、下にシークバー、
/// シークバーの右上に消音と再生速度のボタンを並べる。長押しで速く再生している間は、シークバーの上の中央に知らせる。
/// 部品を出している間は、ボタンが映像に埋もれないよう、映像を暗くする。大きさや間隔は標準の再生画面に合わせる。
///
/// 標準の再生画面（`AVPlayerViewController`）の操作の部品は、閉じるボタンやAirPlayを個別に消せず、自動で消えた状態も外から分からないため、
/// ビューアのボタンや説明と並べられるよう自前で描く。プレイヤーは知らず、状態を受け取って描き、操作を呼び出し側へ伝えるだけにする。
/// 部品のないところへのタッチは受けず、下の動画のタップや長押しに渡す。
final class VideoControlsView: UIView {
    struct State: Equatable {
        var isPlaying = false
        var time = PlaybackTime(elapsed: 0, duration: 0)
        var isMuted = false
        /// 音声のない動画では、消音のボタンを出さない。
        var hasAudio = false
    }

    enum ScrubPhase {
        case began, changed, ended
    }

    var onPlayPause: (() -> Void)?
    /// 秒数だけ進める。負なら戻す。
    var onSkip: ((Double) -> Void)?
    /// シークバーを動かした。値は長さのうちの割合で、0から1。
    var onScrub: ((ScrubPhase, Double) -> Void)?
    var onMuteToggle: (() -> Void)?
    /// 再生速度のボタンで開くメニューの項目。開くたびに作り直す。
    var speedMenuElements: (() -> [UIMenuElement])?
    /// 部品に触れた。再生中に隠すまでの時間を数え直すために使う。
    var onInteraction: (() -> Void)?

    /// 画面の下で、ほかの表示（ビューアの説明）に覆われている高さ。シークバーをこれより上に出す。
    var coveredBottom: CGFloat = 0 {
        didSet { updateBarPosition() }
    }

    /// シークバーを指で動かしている。この間は、届いた再生位置でつまみを動かさない。
    private(set) var isScrubbing = false

    /// 再生速度のメニューを開いている。この間は、隠す時間を数えない。
    var isMenuOpen: Bool { speedButton.isMenuOpen }

    /// シークバーを動かしているか、メニューを開いている。この間は、隠す時間を数えない。
    var isInteracting: Bool { isScrubbing || isMenuOpen }

    private(set) var state = State()

    private let dimmingView = UIView()
    // 映像の上に置く中央のボタンは、標準の再生画面と同じく、下の映像の色を透かす透明なガラスにする。
    private let backButton = VideoControlsView.circleButton(systemImage: nil, pointSize: 25, diameter: 63, glass: .clearGlass())
    private let playButton = VideoControlsView.circleButton(systemImage: "play.fill", pointSize: 36, diameter: 92, glass: .clearGlass())
    private let forwardButton = VideoControlsView.circleButton(systemImage: nil, pointSize: 25, diameter: 63, glass: .clearGlass())
    /// 10秒のボタンの記号。10秒戻ったり進んだりしたときに矢印を回すため、ボタンの記号ではなく、矢印と数字を分けて描く部品を重ねる。
    private let backGlyph = SkipGlyphView(forward: false)
    private let forwardGlyph = SkipGlyphView(forward: true)
    private let muteButton = VideoControlsView.circleButton(systemImage: "speaker.wave.2.fill", pointSize: 18, diameter: 44)
    private let speedButton = VideoControlsView.circleButton(systemImage: "gauge.with.dots.needle.67percent", pointSize: 18, diameter: 44, button: MenuButton())
    private let bar = UIVisualEffectView(effect: UIGlassEffect())
    private let slider = ScrubBar()
    private let elapsedLabel = VideoControlsView.timeLabel()
    private let remainingLabel = VideoControlsView.timeLabel()
    private let fastForwardChip = FastForwardChip()
    private let backSkipEffect = SkipEffect(forward: false)
    private let forwardSkipEffect = SkipEffect(forward: true)
    private lazy var barBottom = bar.bottomAnchor.constraint(equalTo: bottomAnchor)

    /// 隠すときに薄くする部品。長押しで速く再生している知らせは、部品を隠していても出す。
    private var controls: [UIView] { [backButton, playButton, forwardButton, muteButton, speedButton, bar] }
    /// 隠すときに薄くするもの。暗くする下地はタッチを受けないため、タッチを受ける部品とは分ける。
    private var fadingViews: [UIView] { controls + [dimmingView] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpActions()
        setUpLayout()
        apply(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: State) {
        self.state = state
        var play = playButton.configuration
        play?.image = UIImage(systemName: state.isPlaying ? "pause.fill" : "play.fill")
        playButton.configuration = play
        playButton.accessibilityLabel = state.isPlaying ? "一時停止" : "再生"
        var mute = muteButton.configuration
        mute?.image = UIImage(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        muteButton.configuration = mute
        muteButton.accessibilityLabel = state.isMuted ? "消音を解除" : "消音"
        muteButton.isHidden = !state.hasAudio
        elapsedLabel.text = state.time.elapsedText
        remainingLabel.text = state.time.remainingText
        slider.accessibilityValue = "\(state.time.elapsedText) / \(PlaybackTime(elapsed: state.time.duration, duration: state.time.duration).elapsedText)"
        if !isScrubbing {
            slider.value = state.time.progress
        }
    }

    /// 部品か暗くする下地が見えている。隠す途中も含む。
    var isShowingControls: Bool {
        fadingViews.contains { $0.alpha > 0.01 }
    }

    /// 部品を隠す。隠している間はタッチを受けず、下の動画に渡す。動いている途中でも、その場から向きを変える。
    func setControlsHidden(_ hidden: Bool, animated: Bool) {
        let changes = {
            for view in self.fadingViews {
                view.alpha = hidden ? 0 : 1
            }
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    /// シークバーを動かしている間は、標準の再生画面と同じく、映像を見ながら位置を決められるよう、バーのほかの部品と暗くする下地を消し、バーを少し大きくする。
    private func setScrubbingAppearance(_ scrubbing: Bool) {
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            for view in self.fadingViews where view !== self.bar {
                view.alpha = scrubbing ? 0 : 1
            }
            self.bar.transform = scrubbing ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
        }
    }

    /// 長押しで速く再生している間、そのことを知らせる。
    func setFastForwarding(_ isFastForwarding: Bool) {
        fastForwardChip.setShown(isFastForwarding)
    }

    /// 10秒戻ったか進んだことを、矢印を`duration`秒で1回転させて知らせる。ボタンを押したときも、ダブルタップしたときも呼ぶ。
    /// 部品を出しているときは、そのボタンの矢印を回す。ボタンは押されたようには動かさない。指で押したときの反応は、ボタン自身に任せる。
    /// 部品を隠しているときは、ほかの部品は出さず、同じ場所に10秒のボタンと同じ形の表示を`duration`秒だけ出して矢印を回す。
    func showSkipEffect(forward: Bool, duration: TimeInterval) {
        let button = forward ? forwardButton : backButton
        guard button.alpha < 0.01 else {
            (forward ? forwardGlyph : backGlyph).spin(duration: duration)
            return
        }
        (forward ? forwardSkipEffect : backSkipEffect).flash(duration: duration)
    }

    /// 見えている部品の上だけタッチを受け、ほかは下の動画に渡す。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        controls.contains { control in
            !control.isHidden && control.alpha > 0.01 && control.convert(control.bounds, to: self).contains(point)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateBarPosition()
    }

    /// 下の安全領域と、ほかの表示に覆われている高さのうち大きい方の上に、シークバーを置く。
    private func updateBarPosition() {
        barBottom.constant = -(max(coveredBottom, safeAreaInsets.bottom) + 8)
    }

    private func setUpActions() {
        backButton.accessibilityLabel = "10秒戻る"
        forwardButton.accessibilityLabel = "10秒進む"
        speedButton.accessibilityLabel = "再生速度"
        playButton.addAction(UIAction { [weak self] _ in
            self?.onPlayPause?()
            self?.onInteraction?()
        }, for: .primaryActionTriggered)
        backButton.addAction(UIAction { [weak self] _ in
            self?.onSkip?(-10)
            self?.onInteraction?()
        }, for: .primaryActionTriggered)
        forwardButton.addAction(UIAction { [weak self] _ in
            self?.onSkip?(10)
            self?.onInteraction?()
        }, for: .primaryActionTriggered)
        muteButton.addAction(UIAction { [weak self] _ in
            self?.onMuteToggle?()
            self?.onInteraction?()
        }, for: .primaryActionTriggered)
        // 開くたびに、今の速さにチェックマークを付け直す。
        speedButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.speedMenuElements?() ?? [])
        }])
        speedButton.showsMenuAsPrimaryAction = true
        // 開いたときと閉じたときに知らせ、開いている間は隠さず、閉じたところから数え直させる。項目を選んだときも閉じる。
        speedButton.onMenuOpenChange = { [weak self] _ in self?.onInteraction?() }

        slider.accessibilityLabel = "再生位置"
        slider.addAction(UIAction { [weak self] _ in self?.scrub(.began) }, for: .touchDown)
        slider.addAction(UIAction { [weak self] _ in self?.scrub(.changed) }, for: .valueChanged)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            slider.addAction(UIAction { [weak self] _ in self?.scrub(.ended) }, for: event)
        }
    }

    private func scrub(_ phase: ScrubPhase) {
        switch phase {
        case .began:
            isScrubbing = true
            setScrubbingAppearance(true)
        case .changed:
            break
        case .ended:
            isScrubbing = false
            setScrubbingAppearance(false)
        }
        onScrub?(phase, slider.value)
        onInteraction?()
    }

    private func setUpLayout() {
        for (button, glyph) in [(backButton, backGlyph), (forwardButton, forwardGlyph)] {
            glyph.isUserInteractionEnabled = false
            glyph.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.topAnchor.constraint(equalTo: button.topAnchor),
                glyph.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                glyph.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                glyph.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        let center = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        center.spacing = 26
        center.alignment = .center
        let trailing = UIStackView(arrangedSubviews: [muteButton, speedButton])
        trailing.spacing = 12
        bar.cornerConfiguration = .capsule()
        let barContent = UIStackView(arrangedSubviews: [elapsedLabel, slider, remainingLabel])
        barContent.spacing = 14
        barContent.alignment = .center
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        remainingLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        remainingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimmingView.isUserInteractionEnabled = false
        for view in [dimmingView, center, trailing, bar, fastForwardChip, barContent, backSkipEffect, forwardSkipEffect] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        bar.contentView.addSubview(barContent)
        for view in [dimmingView, center, trailing, bar, fastForwardChip, backSkipEffect, forwardSkipEffect] {
            addSubview(view)
        }
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -22),
            barBottom,
            barContent.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 6),
            barContent.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -6),
            barContent.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 16),
            barContent.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -16),
            trailing.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            trailing.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),
            // 10秒のボタンと同じ場所に出し、どのボタンと同じ操作をしたかが分かるようにする。
            backSkipEffect.centerXAnchor.constraint(equalTo: backButton.centerXAnchor),
            backSkipEffect.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            forwardSkipEffect.centerXAnchor.constraint(equalTo: forwardButton.centerXAnchor),
            forwardSkipEffect.centerYAnchor.constraint(equalTo: forwardButton.centerYAnchor),
            fastForwardChip.centerXAnchor.constraint(equalTo: centerXAnchor),
            fastForwardChip.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
        ])
        updateBarPosition()
    }

    private static func circleButton<Button: UIButton>(
        systemImage: String?,
        pointSize: CGFloat,
        diameter: CGFloat,
        glass: UIButton.Configuration = .glass(),
        button: Button = UIButton()
    ) -> Button {
        var configuration = glass
        configuration.image = systemImage.flatMap { UIImage(systemName: $0) }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: diameter),
            button.heightAnchor.constraint(equalToConstant: diameter),
        ])
        return button
    }

    /// 再生中に桁が揃って幅が揺れないよう、数字の幅をそろえる。標準の再生画面と同じく、バーより目立たない灰色にする。
    private static func timeLabel() -> UILabel {
        let label = UILabel()
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedDigitSystemFont(ofSize: 14, weight: .regular))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.isAccessibilityElement = false
        return label
    }
}

/// 長押しで速く再生している間、そのことを知らせる小さな表示。触れても下の操作を妨げないよう、タッチを受けない。
private final class FastForwardChip: UIView {
    private let effectView = UIVisualEffectView(effect: UIGlassEffect())

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        effectView.cornerConfiguration = .capsule()
        let icon = UIImageView(image: UIImage(systemName: "forward.fill"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .small)
        icon.tintColor = .label
        let label = UILabel()
        label.text = "2倍速"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        let stack = UIStackView(arrangedSubviews: [label, icon])
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(stack)
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setShown(_ shown: Bool) {
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = shown ? 1 : 0
        }
        if shown {
            UIAccessibility.post(notification: .announcement, argument: "2倍速")
        }
    }
}

/// メニューを開いているかを知らせるボタン。`UIButton`は、メニューを開いているかを外から読めないため、メニューの出入りを受けて覚える。
final class MenuButton: UIButton {
    private(set) var isMenuOpen = false
    var onMenuOpenChange: ((Bool) -> Void)?

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        isMenuOpen = true
        onMenuOpenChange?(true)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        isMenuOpen = false
        onMenuOpenChange?(false)
    }
}

/// 10秒戻る・進むの記号。数字を回さずに矢印だけを回せるよう、矢印と数字を分けて描く。10秒のボタンと、ダブルタップの表示で使う。
/// ガラスのボタンが記号を置くのと同じ大きさ・位置に描き、ボタンの記号と見た目をそろえる。
private final class SkipGlyphView: UIView {
    /// 数字を除いた、円の矢印。数字を回さずに矢印だけを回すため、数字とは分けて描く。
    private let arrow: UIImageView
    /// 10秒のボタンの記号から、矢印の部分を消した「10」。
    private let number: UIImageView
    private let forward: Bool
    /// 記号の揃え用の枠。ボタンは記号を、絵の枠ではなくこの枠の中心で置くため、同じ位置に置くのに使う。
    private let alignmentInsets: UIEdgeInsets
    /// 矢印の絵の中の、円の中心の位置。絵の大きさに対する割合。
    private var ringCenter = CGPoint(x: 0.5, y: 0.5)

    init(forward: Bool) {
        self.forward = forward
        // ボタンと同じ大きさの設定で描く。ガラスのボタンは記号を一回り大きく描くため、`.large`にする。
        let configuration = UIImage.SymbolConfiguration(pointSize: 25, weight: .medium, scale: .large)
        let arrowImage = UIImage(systemName: forward ? "goforward" : "gobackward", withConfiguration: configuration) ?? UIImage()
        let fullImage = UIImage(systemName: forward ? "goforward.10" : "gobackward.10", withConfiguration: configuration) ?? UIImage()
        // 矢印は記号のまま表示せず、自分で描いた絵にする。記号のまま表示すると描かれる位置が描いた絵とわずかに違い、
        // 描いた絵で求めた円の中心とずれて、回す中心が約0.4pt外れた。測る絵と表示する絵を同じにする。
        let arrowBitmap = Self.bitmap(of: arrowImage)
        arrow = UIImageView(image: arrowBitmap)
        number = UIImageView(image: Self.digits(of: fullImage, removing: arrowImage))
        alignmentInsets = fullImage.alignmentRectInsets
        super.init(frame: .zero)
        // 円の中心で回すよう、回す中心を円の中心に合わせる。矢印の絵は矢じりの分だけ上に出っ張り、円の中心が絵の枠の中心より下にあるため。
        ringCenter = Self.ringCenter(of: arrowBitmap)
        arrow.layer.anchorPoint = ringCenter
        addSubview(arrow)
        addSubview(number)
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 記号を白で、画面の解像度の絵に描く。
    private static func bitmap(of symbol: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: symbol.size, format: .preferred()).image { _ in
            symbol.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
    }

    /// 矢印の絵から、円の中心の位置を絵の大きさに対する割合で求める。
    /// 円の左右の端と下端は円だけが作り、矢じりは上にあるため、左右の端の真ん中と、下端から半径だけ上を中心とする。
    /// 記号の大きさや太さで割合が変わり、決め打ちの値では回す中心がずれたため、描く絵から求める。
    private static func ringCenter(of image: UIImage) -> CGPoint {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let width = cgImage.width, height = cgImage.height, rowBytes = cgImage.bytesPerRow, pixelBytes = cgImage.bitsPerPixel / 8
        let alphaOffset = cgImage.alphaInfo == .premultipliedFirst || cgImage.alphaInfo == .first ? 0 : pixelBytes - 1
        var minX = width, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * rowBytes + x * pixelBytes + alphaOffset] > 127 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX > minX else { return CGPoint(x: 0.5, y: 0.5) }
        let radius = Double(maxX - minX + 1) / 2
        return CGPoint(
            x: (Double(minX + maxX + 1) / 2) / Double(width),
            y: (Double(maxY + 1) - radius) / Double(height)
        )
    }

    /// 10付きの記号から矢印の部分を消し、数字だけを白で描いた絵にする。2つの記号は矢印の形と位置が同じため、重ねて消せる。
    private static func digits(of full: UIImage, removing arrow: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: full.size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: full.size)
            full.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect)
            // 縁のにじみが残らないよう、消す矢印を少しだけ太らせる。
            for dx in [-0.5, 0, 0.5] { for dy in [-0.5, 0, 0.5] {
                arrow.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect.offsetBy(dx: dx, dy: dy), blendMode: .destinationOut, alpha: 1)
            } }
        }
    }

    /// 矢印と数字を、ボタンが記号を置くのと同じく、揃え用の枠の中心を丸い表示の中心にそろえて置く。
    /// 絵の枠の中心でそろえると、ボタンの記号より少し下にずれた。
    /// 矢印は回す中心を円の中心にしたため、`position`には円の中心が来るようにずらす。
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = arrow.image?.size ?? .zero
        let insets = alignmentInsets
        let center = CGPoint(
            x: bounds.midX - (insets.left - insets.right) / 2,
            y: bounds.midY - (insets.top - insets.bottom) / 2
        )
        arrow.bounds = CGRect(origin: .zero, size: size)
        arrow.layer.position = CGPoint(
            x: center.x + (ringCenter.x - 0.5) * size.width,
            y: center.y + (ringCenter.y - 0.5) * size.height
        )
        number.bounds = CGRect(origin: .zero, size: size)
        number.center = center
    }

    /// 矢印を、戻るなら左回り、進むなら右回りに、`duration`秒で1回転させる。
    func spin(duration: TimeInterval) {
        // 矢印だけを、戻るなら左回り、進むなら右回りに1回まわし、出している間に回り終えて、消え始める前に止まって見えるようにする。
        // SF Symbolsの回転の効果は速さを上げても1回転に約0.5秒かかり、短い知らせでは回りきらずに消えたため、矢印の絵を自分で回す。
        // 素早く回り始めて、消える前にゆっくり止まるよう、ease-out-cubicにする。
        // より急なexpo-outでは最初の0.1秒足らずで回りきってしまい、回ったと分からなかった。
        // 続けて10秒動いたら、0度に戻さず今の角度から回し直し、元の向きで止める。
        if !UIAccessibility.isReduceMotionEnabled {
            let current = (arrow.layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
            arrow.layer.removeAnimation(forKey: "rotation")
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = current
            let target = SkipArrowSpin.target(from: current, forward: forward)
            rotation.toValue = target
            rotation.duration = duration
            rotation.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
            arrow.layer.add(rotation, forKey: "rotation")
            arrow.layer.setValue(target, forKeyPath: "transform.rotation.z")
        }
    }
}

/// ダブルタップで10秒戻ったか進んだことを知らせる、短く出て消える丸い表示。10秒のボタンと同じ見た目にする。触れても下の操作を妨げないよう、タッチを受けない。
private final class SkipEffect: UIView {
    /// 10秒のボタンと同じガラスにするため、押せないボタンを下地に使う。
    private let background = UIButton(configuration: .clearGlass())
    private let glyph: SkipGlyphView
    private var hideTask: Task<Void, Never>?
    /// 時間をおく処理の時計。テストでは手で進める時計に差し替える。
    var clock: any Clock<Duration> = AppDependencies.clock

    init(forward: Bool) {
        glyph = SkipGlyphView(forward: forward)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        background.isUserInteractionEnabled = false
        background.configuration?.cornerStyle = .capsule
        for view in [background, glyph] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 63),
            heightAnchor.constraint(equalToConstant: 63),
        ])
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// すぐに出して`duration`秒見せ、薄くして消す。続けてダブルタップしたら、その場から見せ直して数え直す。
    func flash(duration: TimeInterval) {
        hideTask?.cancel()
        // 何もないところから湧いて見えないよう、ほぼ元の大きさから出す。
        if alpha == 0, !UIAccessibility.isReduceMotionEnabled {
            transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }
        glyph.spin(duration: duration)
        hideTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.alpha = 0
            }
        }
    }
}

/// 10秒の矢印を回す行き先の角度。
enum SkipArrowSpin {
    /// 今の角度から、進むなら右回り、戻るなら左回りに、少なくとも半回転先にある元の向き（1回転の倍数）を返す。
    /// 回っている途中で続けて押されたときに、今の角度に1回転を足すと、途中の角度のまま止まったため、止まる向きをそろえる。
    static func target(from current: Double, forward: Bool) -> Double {
        let turn = 2 * Double.pi
        if forward {
            return ((current + Double.pi) / turn).rounded(.up) * turn
        }
        return ((current - Double.pi) / turn).rounded(.down) * turn
    }
}

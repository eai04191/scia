import SciaCore
import UIKit

/// 画面の上端の、ステータスバーが使っている場所の形。ステータスバーの通知を、この形に合わせて描く。
enum StatusBarCutout: Equatable {
    /// Dynamic Island。枠は画面の座標。
    case island(CGRect)
    /// ノッチ。枠は画面の座標で、上端は画面の上端。
    case notch(CGRect)
    /// 切り欠きがなく、ステータスバーが横幅いっぱいにある（iPhone SE、iPad）。
    case none(height: CGFloat)

    /// 今の画面の形。ステータスバーが出ない向き（iPhoneの横向き）ではnil。
    /// アイランドとノッチの位置を返すAPIはないため、上の安全領域の高さから機種の形を見分け、測った値を当てる。
    /// アイランドの上端は、iPhone 16 Pro（安全領域62pt）で14pt、iPhone 14 Proから16（59pt）で11ptと、安全領域の下端から48pt上にある。
    /// 安全領域がこれと違う機種（iPhone Airなど）では、アイランドとずれて描くことがある。試作のため、機種ごとの値は測っていない。
    @MainActor
    static func current(in window: UIWindow) -> StatusBarCutout? {
        let width = window.bounds.width
        let top = window.safeAreaInsets.top
        guard window.traitCollection.userInterfaceIdiom == .phone else {
            return .none(height: max(top, 24))
        }
        guard window.traitCollection.verticalSizeClass != .compact else { return nil }
        if top >= 51 {
            let size = CGSize(width: 125.33, height: 36.67)
            return .island(CGRect(origin: CGPoint(x: (width - size.width) / 2, y: top - 48), size: size))
        }
        if top > 24 {
            // iPhone 13と14のノッチは11と12より細いが、広いほうに合わせる。狭く見積もると、文字がノッチに潜るため。
            let size = CGSize(width: 210, height: 32)
            return .notch(CGRect(origin: CGPoint(x: (width - size.width) / 2, y: 0), size: size))
        }
        return .none(height: max(top, 20))
    }
}

/// ステータスバーの場所に出す、1件の通知。左に誰が何をしたか、右に対象の投稿の文頭かサムネイルを出す。
/// アイランドとノッチは黒いので、同じ黒を切り欠きから左右に広げ、切り欠きが広がったように見せる。
/// アイランドの機種では、アイランドと同じ丸みのカプセルを浮かせる。画面の外形を、アイランドの上から画面の上端までの余白（iPhone 16 Proで14pt）だけ内側へ縮めた範囲に、
/// カプセルの縦の真ん中の左右の端が収まるところまで広げる。左右の余白が上より狭いと、黒い板が画面の上に貼ってあるように見えたため。
/// 切り欠きのない画面では、黒い帯を張らず、ステータスバーの文字を入れ替えたように、地を透かしてふだんの文字の色で描く。
/// 次の通知へは、文字を上へ送って入れ替える。
final class StatusBarTickerView: UIView {
    /// 押されたとき。
    var onTap: (() -> Void)?
    /// 出入りの時間。
    var animationDuration: TimeInterval = 0.35

    private(set) var cutout: StatusBarCutout
    private let capsule = UIView()
    private var content: ContentViews?
    /// 背景を広げたり縮めたりしている動き。背景の枠と丸み、中身の位置と濃さを、UIKitと同じばねの進み具合から前もって計算し、
    /// 同じ時刻表のキーフレームのアニメーションにして描画に任せる。
    /// 中身は背景の子なので、背景をUIKitのアニメーションで動かして毎コマ中身を合わせると、置いた位置が画面に出るときには背景がもう1コマ動いていて、
    /// その分だけ中身が横にも縦にもずれる。毎コマ自分で動かすと、メインスレッドが重いときにコマが落ち、UIKitのばねとも曲線が変わる。
    private var motion: Motion?
    /// 背景の端に合わせて置く中身。広げている途中に次の通知が来ると、入れ替わる2つの中身が並ぶ。
    private var trackedContents: [ContentViews] = []
    /// 入れ替えで薄くなって出ていく途中の中身。入れ替わりの途中に消すときも、背景の端に合わせて置くために持つ。
    private var leavingContents: [ContentViews] = []
    /// 背景と一緒に出入りする中身。濃さも進み具合で決める。広げている途中に入れ替わったらnilにし、入れ替えの薄くする動きに任せる。
    private var fadingContent: ContentViews?
    private(set) var item: StatusBarTickerItem?
    private(set) var isExpanded = false
    /// 出している通知を読み上げる文。
    var accessibilityText: String? { capsule.accessibilityLabel }

    init(cutout: StatusBarCutout) {
        self.cutout = cutout
        super.init(frame: .zero)
        applyCutoutAppearance()
        capsule.clipsToBounds = true
        capsule.layer.cornerCurve = .continuous
        capsule.alpha = 0
        capsule.isAccessibilityElement = true
        capsule.accessibilityTraits = .button
        capsule.accessibilityHint = "通知タブを開きます"
        capsule.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addSubview(capsule)
        AppDependencies.emojiImages.addListener(owner: self) { [weak self] _ in
            self?.content?.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCutout(_ cutout: StatusBarCutout) {
        guard cutout != self.cutout else { return }
        self.cutout = cutout
        applyCutoutAppearance()
        setNeedsLayout()
    }

    /// アイランドとノッチの黒に合わせ、文字と記号の色はダークモードの色にする。切り欠きのない画面では、地を透かしてふだんの色にする。
    private func applyCutoutAppearance() {
        if case .none = cutout {
            overrideUserInterfaceStyle = .unspecified
            capsule.backgroundColor = .clear
        } else {
            overrideUserInterfaceStyle = .dark
            capsule.backgroundColor = .black
        }
    }

    /// `point`（このビューの座標）を受けるビュー。出ていて、見えているカプセルの上なら、カプセルを返す。ほかの場所の指は、下の画面に通すためnilを返す。
    /// 広げている途中は、カプセルの枠（モデルの値）が先に広がり終わった大きさになっているため、描いている途中の枠で決める。
    func tapTarget(at point: CGPoint) -> UIView? {
        let visible = capsule.layer.presentation()?.frame ?? capsule.frame
        guard isExpanded, visible.contains(point) else { return nil }
        return capsule
    }

    /// 通知を出す。出ていれば、文字を上へ送って入れ替える。
    /// 「視差効果を減らす」がオンなら、動かさずに薄くして入れ替え、カプセルも広げずに浮かび上がらせる。
    func show(_ item: StatusBarTickerItem, animated: Bool) {
        self.item = item
        let incoming = ContentViews(item: item, metrics: metrics)
        capsule.addSubview(incoming.left)
        capsule.addSubview(incoming.right)
        capsule.accessibilityLabel = incoming.accessibilityLabel
        let outgoing = content
        content = incoming
        let wasExpanded = isExpanded
        isExpanded = true
        guard animated else {
            outgoing?.removeFromSuperview()
            capsule.alpha = 1
            setNeedsLayout()
            layoutIfNeeded()
            return
        }
        let reducesMotion = UIAccessibility.isReduceMotionEnabled
        if wasExpanded, let motion {
            // 広げている途中に次の通知が来たら、新しい中身も残りの動きに合わせて背景の端に沿わせ、上へ送らずに薄くして入れ替える。
            // 上へ送る動きは、背景の端に沿わせる位置の動きとぶつかるため。
            layoutContent(incoming, in: expandedFrame)
            if tracksEdges {
                trackedContents.append(incoming)
                follow(incoming, along: motion)
            }
            fadingContent = nil
            startLeaving(outgoing)
            incoming.setAlpha(0)
            UIView.animate(withDuration: animationDuration * 0.6, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                incoming.setAlpha(1)
                outgoing?.setAlpha(0)
            } completion: { [weak self] _ in
                self?.finishLeaving(outgoing)
            }
            return
        }
        if wasExpanded {
            layoutContent(incoming, in: expandedFrame)
            let shift = reducesMotion ? 0 : metrics.height * 0.7
            incoming.offset(by: shift)
            incoming.setAlpha(0)
            startLeaving(outgoing)
            UIView.animate(withDuration: animationDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                incoming.offset(by: -shift)
                incoming.setAlpha(1)
                outgoing?.offset(by: -shift)
                outgoing?.setAlpha(0)
            } completion: { [weak self] _ in
                self?.finishLeaving(outgoing)
            }
            return
        }
        outgoing?.removeFromSuperview()
        removeLeavingContents()
        if reducesMotion {
            capsule.frame = expandedFrame
            layoutContent(incoming, in: expandedFrame)
            capsule.layer.cornerRadius = cornerRadius(for: expandedFrame)
            capsule.alpha = 0
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.capsule.alpha = 1
            }
            return
        }
        // 切り欠きの大きさから広げる。中身は背景の端と一緒に、切り欠きの中から外へ出る。切り欠きのない画面では、上から下ろす。
        // 縮めている途中なら、今の見た目の枠から広げ直す。
        if motion == nil {
            setCapsule(frame: collapsedFrame, cornerRadius: cornerRadius(for: collapsedFrame))
        }
        capsule.alpha = 1
        layoutContent(incoming, in: expandedFrame)
        trackedContents = [incoming]
        fadingContent = incoming
        animateCapsule(to: expandedFrame, dampingRatio: 0.85, contentAlpha: { progress in min(max(progress / 0.25, 0), 1) }) {}
    }

    /// 切り欠きへ縮めて消す。「視差効果を減らす」がオンなら、その場で薄くして消す。
    func hide(animated: Bool, completion: (() -> Void)? = nil) {
        guard isExpanded else {
            completion?()
            return
        }
        isExpanded = false
        item = nil
        let finished = { [weak self] in
            guard let self, !self.isExpanded else { return }
            self.capsule.alpha = 0
            self.content?.removeFromSuperview()
            self.content = nil
            self.removeLeavingContents()
            completion?()
        }
        guard animated else {
            finished()
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.capsule.alpha = 0
            } completion: { _ in
                finished()
            }
            return
        }
        // 中身は背景の端と一緒に切り欠きの中へしまわれる。濃さは、ほとんど縮み終わるまで保つ。アイランドに重なった分は実機では見えないため。
        // 入れ替わりの途中なら、出ていく途中の中身も背景の端に合わせて置く。置かないと、縮む背景に置いていかれて端で切れる。
        trackedContents = (content.map { [$0] } ?? []) + leavingContents
        fadingContent = content
        animateCapsule(to: collapsedFrame, dampingRatio: 1, contentAlpha: { progress in min(max((1 - progress) / 0.25, 0), 1) }) {
            finished()
        }
    }

    private func startLeaving(_ content: ContentViews?) {
        guard let content else { return }
        leavingContents.append(content)
    }

    private func finishLeaving(_ content: ContentViews?) {
        guard let content else { return }
        content.removeFromSuperview()
        leavingContents.removeAll { $0 === content }
        trackedContents.removeAll { $0 === content }
    }

    private func removeLeavingContents() {
        for content in leavingContents {
            content.removeFromSuperview()
            trackedContents.removeAll { $0 === content }
        }
        leavingContents = []
    }

    /// 背景を広げたり縮めたりしている動きの、始まった時刻と、始まりと行き先の枠と丸み。途中から加わる中身の動きを、残りの時間に合わせて作るために持つ。
    private struct Motion {
        let id: UUID
        let startTime: CFTimeInterval
        let spring: UIKitSpring
        let fromFrame: CGRect
        let toFrame: CGRect
        let fromRadius: CGFloat
        let toRadius: CGFloat

        func frame(at progress: CGFloat) -> CGRect {
            CGRect(
                x: fromFrame.minX + (toFrame.minX - fromFrame.minX) * progress,
                y: fromFrame.minY + (toFrame.minY - fromFrame.minY) * progress,
                width: fromFrame.width + (toFrame.width - fromFrame.width) * progress,
                height: fromFrame.height + (toFrame.height - fromFrame.height) * progress
            )
        }

        func radius(at progress: CGFloat) -> CGFloat {
            max(fromRadius + (toRadius - fromRadius) * progress, 0)
        }
    }

    /// キーフレームの間隔。線でつないでも、120Hzの画面でばねの曲線と見分けがつかない細かさにする。
    private static let keyframeInterval: TimeInterval = 1.0 / 240
    private static let animationKeyPrefix = "statusBarTicker."

    /// 背景を、今の見た目の枠から`target`へ、UIKitと同じばねで動かす。中身も同じ時刻表で背景の端に沿わせ、背景と一緒に出入りする中身の濃さも同じ進み具合で決める。
    private func animateCapsule(to target: CGRect, dampingRatio: CGFloat, contentAlpha: @escaping (CGFloat) -> CGFloat, completion: @escaping () -> Void) {
        // 動いている途中なら、今の見た目で止めてから動かし直す。
        let presentation = capsule.layer.presentation()
        let fromFrame = presentation?.frame ?? capsule.frame
        let fromRadius = presentation?.cornerRadius ?? capsule.layer.cornerRadius
        removeMotionAnimations()
        let spring = UIKitSpring.make(duration: animationDuration, dampingRatio: dampingRatio)
        let motion = Motion(
            id: UUID(),
            startTime: CACurrentMediaTime(),
            spring: spring,
            fromFrame: fromFrame,
            toFrame: target,
            fromRadius: fromRadius,
            toRadius: cornerRadius(for: target)
        )
        self.motion = motion
        let times = keyframeTimes(from: 0, to: spring.duration)
        let progresses = times.map { CGFloat(spring.progress(at: $0)) }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.motion?.id == motion.id else { return }
            self.motion = nil
            self.trackedContents = []
            self.fadingContent = nil
            completion()
        }
        setCapsule(frame: target, cornerRadius: motion.toRadius)
        let frames = progresses.map(motion.frame(at:))
        addKeyframes(to: capsule.layer, keyPath: "position", values: frames.map { NSValue(cgPoint: CGPoint(x: $0.midX, y: $0.midY)) }, times: times, beginTime: motion.startTime)
        addKeyframes(to: capsule.layer, keyPath: "bounds", values: frames.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.size)) }, times: times, beginTime: motion.startTime)
        addKeyframes(to: capsule.layer, keyPath: "cornerRadius", values: progresses.map { motion.radius(at: $0) }, times: times, beginTime: motion.startTime)
        if tracksEdges {
            for content in trackedContents {
                follow(content, along: motion)
            }
        }
        if let fadingContent {
            let alphas = progresses.map(contentAlpha)
            fadingContent.setAlpha(alphas.last ?? 1)
            for layer in [fadingContent.left.layer, fadingContent.right.layer] {
                addKeyframes(to: layer, keyPath: "opacity", values: alphas.map { Float($0) }, times: times, beginTime: motion.startTime)
            }
        }
        CATransaction.commit()
    }

    /// 中身を、`motion`の残りの時間、背景の端から余白だけ内側に沿わせる。動き終わったときの位置を、中身の置き場所にする。
    private func follow(_ content: ContentViews, along motion: Motion) {
        let elapsed = max(CACurrentMediaTime() - motion.startTime, 0)
        guard elapsed < motion.spring.duration else { return }
        let times = keyframeTimes(from: elapsed, to: motion.spring.duration)
        let placements = times.map { edgeFrames(content, visible: motion.frame(at: CGFloat(motion.spring.progress(at: $0)))) }
        guard let last = placements.last else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.left.frame = last.left
        content.right.frame = last.right
        let beginTime = motion.startTime + elapsed
        let shiftedTimes = times.map { $0 - elapsed }
        addKeyframes(to: content.left.layer, keyPath: "position", values: placements.map { NSValue(cgPoint: CGPoint(x: $0.left.midX, y: $0.left.midY)) }, times: shiftedTimes, beginTime: beginTime)
        addKeyframes(to: content.right.layer, keyPath: "position", values: placements.map { NSValue(cgPoint: CGPoint(x: $0.right.midX, y: $0.right.midY)) }, times: shiftedTimes, beginTime: beginTime)
        CATransaction.commit()
    }

    private func keyframeTimes(from start: TimeInterval, to end: TimeInterval) -> [TimeInterval] {
        let count = max(Int(((end - start) / Self.keyframeInterval).rounded(.up)), 1)
        return (0...count).map { start + (end - start) * Double($0) / Double(count) }
    }

    /// `values`を`times`（`beginTime`からの経過時間）に置いたキーフレームを足す。モデルの値は呼ぶ前に行き先にしておく。
    private func addKeyframes(to layer: CALayer, keyPath: String, values: [Any], times: [TimeInterval], beginTime: CFTimeInterval) {
        guard let duration = times.last, duration > 0 else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / duration) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = layer.convertTime(beginTime, from: nil)
        animation.fillMode = .backwards
        layer.add(animation, forKey: Self.animationKeyPrefix + keyPath)
    }

    /// 背景と中身の、今の見た目の位置で止める。中身の動き（上へ送る途中のUIKitのアニメーションを含む）も、背景に沿わせ直すので外す。
    private func removeMotionAnimations() {
        motion = nil
        for layer in [capsule.layer] + (trackedContents + leavingContents).flatMap({ [$0.left.layer, $0.right.layer] }) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.animationKeyPrefix) || key == "position" {
                layer.removeAnimation(forKey: key)
            }
        }
    }

    private func setCapsule(frame: CGRect, cornerRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = frame
        capsule.layer.cornerRadius = cornerRadius
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isExpanded, motion == nil else { return }
        capsule.frame = expandedFrame
        capsule.layer.cornerRadius = cornerRadius(for: expandedFrame)
        if let content {
            layoutContent(content, in: expandedFrame)
        }
    }

    @objc private func tapped() {
        onTap?()
    }

    // MARK: - 形

    private struct Metrics {
        let height: CGFloat
        let fontSize: CGFloat
        let avatarSide: CGFloat
        let thumbnailSide: CGFloat
        /// 何をされたかの記号を、アイコンの右下に重ねる。名前の前に並べると、名前の入る幅が狭いとき。
        let badgesSymbol: Bool
    }

    private var metrics: Metrics {
        let badges = AppDependencies.tuning.value(of: TuningCatalog.statusBarTickerBadgesSymbol)
        return switch cutout {
        case .island(let rect): Metrics(height: rect.height, fontSize: 13, avatarSide: 20, thumbnailSide: 24, badgesSymbol: badges)
        case .notch(let rect): Metrics(height: rect.height, fontSize: 12, avatarSide: 18, thumbnailSide: 22, badgesSymbol: true)
        case .none(let height): Metrics(height: height, fontSize: 12, avatarSide: 15, thumbnailSide: 16, badgesSymbol: badges)
        }
    }

    /// アイランドの機種で、カプセルの左右の余白。画面の外形を14pt内側へ縮めた範囲の、カプセルの縦の真ん中の高さ（上端から32.33pt）での左の縁。
    /// 画面の角の形を返すAPIはないため、iPhone 16 Proのシミュレーターの画面の形（機種の定義のframebufferMask）から測った値を当てる。
    /// 画面の角の大きさが違う機種では、範囲からはみ出したり、余白が広すぎたりすることがある。試作のため、機種ごとの値は測っていない。
    private static let islandSideMargin: CGFloat = 24.06

    /// 広げたときのカプセルの枠。
    private var expandedFrame: CGRect {
        switch cutout {
        case .island(let rect):
            CGRect(x: Self.islandSideMargin, y: rect.minY, width: bounds.width - Self.islandSideMargin * 2, height: rect.height)
        case .notch(let rect):
            CGRect(x: 0, y: 0, width: bounds.width, height: rect.maxY)
        case .none(let height):
            CGRect(x: 0, y: 0, width: bounds.width, height: height)
        }
    }

    private var collapsedFrame: CGRect {
        switch cutout {
        case .island(let rect), .notch(let rect): rect
        case .none(let height): CGRect(x: 0, y: -height, width: bounds.width, height: height)
        }
    }

    private func cornerRadius(for frame: CGRect) -> CGFloat {
        switch cutout {
        case .island:
            capsule.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            return frame.height / 2
        case .notch:
            capsule.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            return 12
        case .none:
            capsule.layer.maskedCorners = []
            return 0
        }
    }

    /// 中身が背景の端に付いて動く画面か。アイランドとノッチでは、背景が切り欠きから左右へ広がる。
    private var tracksEdges: Bool {
        if case .none = cutout { return false }
        return true
    }

    /// 背景の左端から左の中身までの余白と、右の中身から背景の右端までの余白。
    /// アイランドの機種では、チューニングの値を使う。左は先頭の記号が端の半円と同心に見える値、右は行末のぼかしを端の半円の中に入れる値を初めの値にする。
    private var edgePaddings: (leading: CGFloat, trailing: CGFloat) {
        switch cutout {
        case .island:
            let tuning = AppDependencies.tuning
            return (tuning.value(of: TuningCatalog.statusBarTickerLeadingPadding), tuning.value(of: TuningCatalog.statusBarTickerTrailingPadding))
        case .notch: return (14, 14)
        case .none: return (0, 0)
        }
    }

    /// 背景が`visible`の枠（このビューの座標）にあるときの、背景の端から余白だけ内側の中身の枠。座標はカプセルの中。
    /// 広げ終わった位置より外へは出さない。画面の外まで広げる形でも、端が画面の外へ抜けたところで中身は止まる。
    private func edgeFrames(_ content: ContentViews, visible: CGRect) -> (left: CGRect, right: CGRect) {
        let frame = expandedFrame
        let rects = contentRects(content, in: frame)
        var left = rects.left.offsetBy(dx: frame.minX, dy: frame.minY)
        var right = rects.right.offsetBy(dx: frame.minX, dy: frame.minY)
        let paddings = edgePaddings
        left.origin.x = max(visible.minX + paddings.leading, left.minX)
        right.origin.x = min(visible.maxX - paddings.trailing, right.maxX) - right.width
        return (left.offsetBy(dx: -visible.minX, dy: -visible.minY), right.offsetBy(dx: -visible.minX, dy: -visible.minY))
    }


    /// 左右の中身を置く。座標はカプセルの中。
    private func layoutContent(_ content: ContentViews, in frame: CGRect) {
        let rects = contentRects(content, in: frame)
        content.left.frame = rects.left
        content.right.frame = rects.right
    }

    /// 背景が`frame`にあるときの左右の中身の枠。座標はカプセルの中。
    private func contentRects(_ content: ContentViews, in frame: CGRect) -> (left: CGRect, right: CGRect) {
        let gap: CGFloat = 8
        let left: CGRect
        let right: CGRect
        switch cutout {
        case .island(let rect):
            // 文字はアイランドと同じ高さの行に、カプセルの端から余白だけ内側に置く。
            let paddings = edgePaddings
            let leading = Self.islandSideMargin + paddings.leading
            let trailing = Self.islandSideMargin + paddings.trailing
            let y = rect.minY - frame.minY
            left = CGRect(x: leading - frame.minX, y: y, width: rect.minX - gap - leading, height: rect.height)
            right = CGRect(x: rect.maxX + gap - frame.minX, y: y, width: bounds.width - trailing - rect.maxX - gap, height: rect.height)
        case .notch(let rect):
            // ノッチの機種は、上の端では画面の角の丸みに文字がかかるため、少し多めに空ける。
            let inset: CGFloat = 14
            left = CGRect(x: inset, y: 0, width: rect.minX - frame.minX - gap - inset, height: frame.height)
            right = CGRect(x: rect.maxX - frame.minX + gap, y: 0, width: frame.maxX - rect.maxX - gap - inset, height: frame.height)
        case .none:
            // 切り欠きで分かれないので、誰が何をしたかのすぐ後ろに文頭を続ける。名前が長くても、文頭の場所を半分は残す。
            let inset: CGFloat = 16
            let available = frame.width - inset * 2 - gap
            let leftWidth = min(content.naturalLeftWidth, available / 2)
            left = CGRect(x: inset, y: 0, width: leftWidth, height: frame.height)
            right = CGRect(x: inset + leftWidth + gap, y: 0, width: available - leftWidth, height: frame.height)
        }
        return (left, right)
    }

    /// 1件の通知の中身。入れ替えるときに、古い中身を残したまま新しい中身を重ねて動かすため、まとめて持つ。
    @MainActor
    private final class ContentViews {
        let left = UIStackView()
        let right = UIStackView()
        let accessibilityLabel: String
        private let item: StatusBarTickerItem
        private let metrics: Metrics
        /// 入りきらない名前と文頭は、「…」で切らず、投稿の名前と同じく行末をぼかす。
        private let nameLabel = FadingLabel()
        private let subjectLabel = FadingLabel()

        init(item: StatusBarTickerItem, metrics: Metrics) {
            self.item = item
            self.metrics = metrics
            let appearance = NotificationAppearance(item.kind)
            let name = item.account.displayNameOrUsername
            let action = appearance.phrase.includesName ? "\(appearance.phrase.before)\(name)\(appearance.phrase.after)" : appearance.phrase.before
            accessibilityLabel = switch item.subject {
            case .text(let text): "\(action)。\(text.plainText)"
            case .media: "\(action)。画像だけの投稿"
            case .handle(let handle): "\(action)。\(handle)"
            case .none: action
            }

            for stack in [left, right] {
                stack.axis = .horizontal
                stack.alignment = .center
                stack.spacing = 5
                stack.isUserInteractionEnabled = false
            }

            let symbol = UIImageView(image: UIImage(
                systemName: appearance.symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: metrics.badgesSymbol ? metrics.avatarSide * 0.36 : metrics.fontSize, weight: .semibold)
            ))
            symbol.tintColor = appearance.color
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            symbol.setContentCompressionResistancePriority(.required, for: .horizontal)

            let avatar = AvatarView(store: AppDependencies.avatarImages)
            avatar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                avatar.widthAnchor.constraint(equalToConstant: metrics.avatarSide),
                avatar.heightAnchor.constraint(equalToConstant: metrics.avatarSide),
            ])
            avatar.apply(AvatarView.Content(url: item.account.avatarStatic, shape: AppDependencies.settings.avatarShape, animates: false))
            if metrics.badgesSymbol {
                left.addArrangedSubview(Self.badged(avatar, with: symbol, side: metrics.avatarSide))
                // 右下にはみ出す記号の分を空ける。
                left.setCustomSpacing(7, after: left.arrangedSubviews[left.arrangedSubviews.count - 1])
            } else {
                left.addArrangedSubview(symbol)
                left.addArrangedSubview(avatar)
            }

            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            left.addArrangedSubview(nameLabel)

            if case .media(let attachment, let isSensitive) = item.subject {
                right.addArrangedSubview(Self.thumbnail(of: attachment, isSensitive: isSensitive, side: metrics.thumbnailSide))
                // サムネイルを左に寄せるため、残りを空白で埋める。
                let spacer = UIView()
                spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
                right.addArrangedSubview(spacer)
            } else {
                subjectLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
                subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                right.addArrangedSubview(subjectLabel)
            }
            render()
        }

        /// 名前と文頭を描く。カスタム絵文字が届いたら、描き直す。
        func render() {
            let settings = AppDependencies.settings
            let fadeWidth = AppDependencies.tuning.value(of: TuningCatalog.statusBarTickerFadeWidth)
            nameLabel.fadeWidth = fadeWidth
            subjectLabel.fadeWidth = fadeWidth
            let font = UIFont.systemFont(ofSize: metrics.fontSize, weight: .semibold)
            let nameRenderer = RichTextRenderer(font: font, textColor: .label, emojiImages: AppDependencies.emojiImages, language: settings.glyphLanguageIdentifier())
            nameLabel.attributedText = nameRenderer.render(.plain(item.account.displayNameOrUsername, emojis: item.account.emojis))
            let subjectColor = UIColor.secondaryLabel
            var renderer = RichTextRenderer(
                font: .systemFont(ofSize: metrics.fontSize),
                textColor: subjectColor,
                emojiImages: AppDependencies.emojiImages,
                language: settings.glyphLanguageIdentifier()
            )
            renderer.linkColor = subjectColor
            renderer.secondaryColor = subjectColor
            switch item.subject {
            case .text(let text):
                subjectLabel.attributedText = renderer.render(text)
            case .handle(let handle):
                subjectLabel.attributedText = renderer.render(.plain(handle, emojis: []))
            case .media, .none:
                subjectLabel.attributedText = nil
            }
        }

        /// 左の中身を省かずに並べたときの幅。
        var naturalLeftWidth: CGFloat {
            let views = left.arrangedSubviews
            let widths = views.map { view in
                view is UILabel ? view.intrinsicContentSize.width : view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            }
            let spacings = views.dropLast().map { left.customSpacing(after: $0) == UIStackView.spacingUseDefault ? left.spacing : left.customSpacing(after: $0) }
            return ceil(widths.reduce(0, +) + spacings.reduce(0, +))
        }

        func offset(by dy: CGFloat) {
            left.center.y += dy
            right.center.y += dy
        }

        func setAlpha(_ alpha: CGFloat) {
            left.alpha = alpha
            right.alpha = alpha
        }

        func removeFromSuperview() {
            left.removeFromSuperview()
            right.removeFromSuperview()
        }

        /// アイコンの右下に、黒い丸に載せた記号を重ねる。
        private static func badged(_ avatar: UIView, with symbol: UIImageView, side: CGFloat) -> UIView {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            let badge = UIView()
            let badgeSide = side * 0.62
            badge.backgroundColor = .systemBackground
            badge.layer.cornerRadius = badgeSide / 2
            badge.translatesAutoresizingMaskIntoConstraints = false
            symbol.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(avatar)
            container.addSubview(badge)
            badge.addSubview(symbol)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: side),
                container.heightAnchor.constraint(equalToConstant: side),
                avatar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                avatar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: badgeSide),
                badge.heightAnchor.constraint(equalToConstant: badgeSide),
                badge.centerXAnchor.constraint(equalTo: container.trailingAnchor, constant: -1),
                badge.centerYAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
                symbol.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                symbol.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            ])
            return container
        }

        private static func thumbnail(of attachment: MediaAttachment, isSensitive: Bool, side: CGFloat) -> UIView {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = side * 0.22
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = .secondarySystemFill
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: side),
                imageView.heightAnchor.constraint(equalToConstant: side),
            ])
            let store = AppDependencies.mediaImages
            if isSensitive {
                // 閲覧注意の画像は、一覧と同じく中身を見せず、ぼかしの下地に目の印を重ねる。
                imageView.image = attachment.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: 1) }
                let eye = UIImageView(image: UIImage(systemName: "eye.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.4, weight: .semibold)))
                eye.tintColor = .white
                eye.translatesAutoresizingMaskIntoConstraints = false
                imageView.addSubview(eye)
                NSLayoutConstraint.activate([
                    eye.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                    eye.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                ])
                return imageView
            }
            guard let url = attachment.previewUrl else { return imageView }
            let request = MediaThumbnailRequest(url: url, maxPixelSize: Int((side * 3).rounded(.up)))
            if let cached = store.cachedThumbnail(for: request) {
                imageView.image = cached
                return imageView
            }
            Task { [weak imageView] in
                guard let image = try? await store.thumbnail(for: request) else { return }
                imageView?.image = image
            }
            return imageView
        }
    }
}

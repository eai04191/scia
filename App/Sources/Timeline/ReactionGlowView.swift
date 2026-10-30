import SciaCore
import UIKit

/// お気に入りとブーストをしたことを、行の下の端から照らす光で示す。両方なら左半分がブースト、右半分がお気に入りで、
/// 片方だけのときは、その色で全幅を光らせるか、その半分だけを光らせるかを選べる。色だけでは何を示すか分かりにくいため、アイコンを添えられる。
struct ReactionGlow: Equatable {
    /// 光らせる投稿。同じ投稿のまま状態が変わったときだけ、点けたり消したりを動かす。
    var statusID: Status.ID?
    var isReblogged: Bool
    var isFavourited: Bool
    var style: Style

    struct Style: Equatable {
        var height: CGFloat
        /// ライトモードでSDRで描くときの光の高さ。
        var lightSDRHeight: CGFloat
        var darkOpacity: CGFloat
        var lightOpacity: CGFloat
        /// にじみを、SDRの白の何倍の明るさで描くか。1ならSDRのまま描く。HDRで描ける画面でだけ、白より明るく光る。
        var hdrExposure: CGFloat
        /// 使う人がHDRで光らせることを選んでいるか。オフなら、HDRで描ける画面でもSDRで描く。
        var allowsHDR: Bool
        /// ライトモードでHDRで描くときの、照らされた側を重ねる濃さ。SDRで描くときは`lightOpacity`を使う。
        var lightHDROpacity: CGFloat
        /// ライトモードでHDRで描くときの、にじみの強さ。照らす光の強さの何倍にするか。
        var lightBloomIntensityRatio: Double
        /// ダークモードで、照らされた側をSDRの白の何倍の明るさで描くか。1ならSDRのまま描く。
        var darkGlowHDRExposure: CGFloat
        /// ライトモードのお気に入りの色を、黄色にする。オフなら橙。
        var lightFavouriteIsYellow: Bool
        /// ライトモードでHDRで描くときの、照らす光の強さ。白い背景にこの強さで光を足し、白より明るくする。
        var lightIntensity: Double
        var fillsWidthWhenAlone: Bool
        var iconStyle: IconStyle
        var iconSize: CGFloat
        var iconOpacity: Double
        /// 散らしたアイコンを、光源から遠いほど遅れて点け、早く消す強さ。0なら全部が一緒に点く。
        var iconRiseDelay: Double
        var blendWidth: CGFloat
        /// 真ん中で2色を混ぜる空間。
        var mixSpace: ColorMixSpace
        var duration: TimeInterval
    }

    enum IconStyle: Equatable {
        case none
        /// 下の端に、ブーストとお気に入りのアイコンを1つずつ置く。
        case atBottom
        /// 下の端に、小さなアイコンを大きさと濃さを変えて散らす。本文と重ならないよう、下の余白の高さに収める。
        case scattered

        init(_ icons: ReactionGlowIcons) {
            self = switch icons {
            case .none: .none
            case .atBottom: .atBottom
            case .scattered: .scattered
            }
        }
    }

    /// お気に入りかブーストのどちらかをしていて、光っている。光っている行には、一覧の区切り線を引かない。
    var isLit: Bool { isReblogged || isFavourited }

    /// 読み上げで、名前や本文に続けて読む状態。
    var accessibilityText: String? {
        let parts = [isReblogged ? "ブースト済み" : nil, isFavourited ? "お気に入り済み" : nil].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }
}

extension ReactionGlow.Style {
    /// ライトでHDRを使わずに描くときの、光の高さと濃さの、HDRで描くときに対する割合。
    /// 白い背景に光の色を薄く重ねるだけなので、高く濃くすると汚れのように見える。設定ではHDRのときの値だけを選ばせ、これを掛ける。
    /// 割合は、設定に移す前にチューニングで決めていた値（高さは64ptに対して38pt、濃さは0.95に対して0.3）から求めた。
    static let lightSDRHeightRatio: CGFloat = 38.0 / 64.0
    static let lightSDROpacityRatio: CGFloat = 0.3 / 0.95

    @MainActor
    init(tuning: TuningStore, settings: AppSettings) {
        typealias C = AppearanceCatalog
        let height = settings.value(of: C.reactionGlowHeight)
        let lightOpacity = settings.value(of: C.reactionGlowLightOpacity)
        self.init(
            height: height,
            lightSDRHeight: height * Self.lightSDRHeightRatio,
            darkOpacity: settings.value(of: C.reactionGlowDarkOpacity),
            lightOpacity: lightOpacity * Self.lightSDROpacityRatio,
            hdrExposure: tuning.value(of: TuningCatalog.reactionGlowHDRExposure),
            allowsHDR: settings.drawsReactionGlowInHDR,
            lightHDROpacity: lightOpacity,
            lightBloomIntensityRatio: tuning.value(of: TuningCatalog.reactionGlowLightBloomIntensityRatio),
            darkGlowHDRExposure: tuning.value(of: TuningCatalog.reactionGlowDarkGlowHDRExposure),
            lightFavouriteIsYellow: settings.reactionGlowLightFavouriteColor == .yellow,
            lightIntensity: tuning.value(of: TuningCatalog.reactionGlowLightIntensity),
            fillsWidthWhenAlone: settings.reactionGlowFillsWidthWhenAlone,
            iconStyle: ReactionGlow.IconStyle(settings.reactionGlowIcons),
            iconSize: settings.value(of: C.reactionGlowIconSize),
            iconOpacity: settings.value(of: C.reactionGlowIconOpacity),
            iconRiseDelay: tuning.value(of: TuningCatalog.reactionGlowIconRiseDelay),
            blendWidth: settings.value(of: C.reactionGlowBlendWidth),
            mixSpace: tuning.value(of: TuningCatalog.reactionGlowMixesInOKLab) ? .oklab : .linear,
            duration: tuning.value(of: TuningCatalog.reactionGlowDuration)
        )
    }
}

/// 行の中身の後ろに敷いて、下の端に置く。行の大きさには関わらない。
///
/// 左から右への色と濃さは、1本のグラデーション（`ReactionGlowGradient`）で描く。縦に上へ薄くなる形は、それにマスクで付ける。
final class ReactionGlowView: UIView {

    private let glow = CAGradientLayer()
    /// 下の端から離れるほど早く暗くなるよう、なめらかに落とす。直線で落とすと、上の端に境目が見える。
    private let falloff = CAGradientLayer()
    /// 下の端のすぐ上に重ねる、いちばん明るいにじみ。上へすぐに消える。
    private let bloom = CAGradientLayer()
    private let bloomFalloff = CAGradientLayer()
    private var icons: [IconView] = []
    private var current: ReactionGlow?
    /// 下の端から、本文や添付ファイルが始まるまでの高さ。アイコンは本文と重ならないよう、この中に収める。
    private var iconAreaHeight: CGFloat = 0
    /// ブーストとお気に入りの、いま描いている明るさ。点けたり消したりする途中は、0と1のあいだ。
    private var levels = Levels(boost: 0, favourite: 0)
    private var fade: Fade?
    private lazy var ticker = FrameTicker(source: DisplayLinkFrameSource.shared) { [weak self] elapsed in
        self?.step(elapsed) ?? false
    }

    private struct Levels: Equatable {
        var boost: Double
        var favourite: Double
    }

    private struct Fade {
        var from: Levels
        var to: Levels
        var duration: TimeInterval
        var elapsed: TimeInterval = 0
        /// 動きの進み具合（なめらかにした後）。0で`from`、1で`to`。
        var progress: Double = 0
        /// 散らしたアイコンを、どの状態からどの状態へ入れ替えるか。ふつうは`from`と`to`と同じ。
        var iconFrom: Levels
        var iconTo: Levels
        /// 置き場所ごとの、入れ替えの進み具合の始まり。光源からの遠さで決まる遅れ（`delay`）ごとに変わるので、関数で持つ。
        /// 新しく始めた動きでは0。途中で逆向きに戻されたときは、前の動きでその置き場所が進んでいた分を引き継ぐ。
        var iconStart: (Double) -> Double = { _ in 0 }

        init(from: Levels, to: Levels, duration: TimeInterval) {
            self.from = from
            self.to = to
            self.duration = duration
            iconFrom = from
            iconTo = to
        }

        /// 置き場所ごとの入れ替えの進み具合。遠い置き場所ほど遅れて進む。
        func iconProgress(delay: Double) -> Double {
            let start = iconStart(delay)
            return start + (1 - start) * pow(progress, delay)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // 入れ替わるアイコンを、下の端（光源）の向こうへ沈めて見えなくするため、外を切り取る。
        clipsToBounds = true
        isAccessibilityElement = false
        for gradient in [glow, bloom] {
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            layer.addSublayer(gradient)
        }
        falloff.startPoint = CGPoint(x: 0.5, y: 0)
        falloff.endPoint = CGPoint(x: 0.5, y: 1)
        falloff.locations = [0, 0.35, 0.65, 0.85, 1]
        falloff.colors = [0, 0.08, 0.3, 0.65, 1].map { UIColor(white: 0, alpha: $0).cgColor }
        glow.mask = falloff
        bloomFalloff.startPoint = CGPoint(x: 0.5, y: 0)
        bloomFalloff.endPoint = CGPoint(x: 0.5, y: 1)
        // 下の端を濃くし、上へすばやく薄くする。
        bloomFalloff.locations = [0, 0.35, 0.7, 1]
        bloomFalloff.colors = [0, 0.3, 0.8, 1].map { UIColor(white: 0, alpha: $0).cgColor }
        bloom.mask = bloomFalloff
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            // ライトとダークで光の高さが変わるため、行の中身に並べ直してもらう。
            self.superview?.setNeedsLayout()
            self.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 行の中身の一番後ろに置く。行の高さを測るときに加わらないよう、制約は付けず、`layout(in:)`で枠を決める。
    func install(in container: UIView) {
        container.insertSubview(self, at: 0)
    }

    /// 行の中身を並べ終えたあとに呼び、下の端に置く。行より高い光は、行の上の端で切る。
    /// - Parameter bottomMargin: 行の下の余白。中身は少なくともこれだけ下の端から離れている。
    func layout(in bounds: CGRect, bottomMargin: CGFloat) {
        let height = min(glowHeight, bounds.height)
        frame = CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
        if iconAreaHeight != bottomMargin {
            iconAreaHeight = bottomMargin
            render()
        }
    }

    func apply(_ glow: ReactionGlow?) {
        let previous = current
        current = glow
        // 高さが変わったときは、行の中身を並べ直す中で枠を決め直す。
        superview?.setNeedsLayout()
        setNeedsLayout()
        let target = Levels(boost: glow?.isReblogged == true ? 1 : 0, favourite: glow?.isFavourited == true ? 1 : 0)
        // 別の投稿に使い回されたときは、前の投稿の光から動かさず、すぐに切り替える。
        let duration = previous != nil && previous?.statusID == glow?.statusID ? glow?.style.duration ?? 0 : 0
        if duration == 0 {
            fade = nil
            ticker.stop()
            levels = target
        } else if (fade?.to ?? levels) != target {
            // 点けている途中に取り消されても、今の明るさから戻す。押したときの強調などで同じ状態がもう一度適用されたときは、進んでいる動きを残す。
            let distance = max(abs(target.boost - levels.boost), abs(target.favourite - levels.favourite))
            var next = Fade(from: levels, to: target, duration: duration * distance)
            // 散らしたアイコンが入れ替わる途中で、元の状態へ戻されたときは、今見えている位置と濃さから逆向きにたどる。
            // 新しく始めると、沈みかけた記号が元の位置と濃さへぱっと戻るため。
            if let previous = fade, target == previous.iconFrom {
                next.iconFrom = previous.iconTo
                next.iconTo = previous.iconFrom
                next.iconStart = { delay in 1 - previous.iconProgress(delay: delay) }
            }
            fade = next
            if !ticker.isRunning { ticker.start() }
        }
        render()
    }

    /// 「投稿の見た目」のプレビューで場所を示すための、光の全体（片方だけをした投稿なら、その別にも）、真ん中で2色を混ぜる幅、出ているアイコンの枠。`space`の座標で返す。光っていなければ空。
    func previewFrames(in space: UIView) -> AppearancePreviewFrames {
        // 高さを0にしたときも、光があった下の端を示せるよう、高さのない枠を返す。
        guard !glow.isHidden, let style = current?.style else { return [:] }
        let blendWidth = min(style.blendWidth, bounds.width)
        var frames: AppearancePreviewFrames = [
            .reactionGlow: [convert(bounds, to: space)],
            .reactionGlowBlend: [convert(CGRect(x: bounds.midX - blendWidth / 2, y: 0, width: blendWidth, height: bounds.height), to: space)],
        ]
        if current?.isReblogged != current?.isFavourited {
            frames[.reactionGlowAlone] = frames[.reactionGlow]
        }
        let shownIcons = icons.filter { $0.alpha > 0 }.map { $0.convert($0.bounds, to: space) }
        if !shownIcons.isEmpty {
            frames[.reactionGlowIcons] = shownIcons
        }
        return frames
    }

    private func step(_ elapsed: CFTimeInterval) -> Bool {
        guard var fade else { return false }
        fade.elapsed += elapsed
        let t = fade.duration > 0 ? min(fade.elapsed / fade.duration, 1) : 1
        let eased = 1 - pow(1 - t, 3)
        fade.progress = eased
        levels = Levels(
            boost: fade.from.boost + (fade.to.boost - fade.from.boost) * eased,
            favourite: fade.from.favourite + (fade.to.favourite - fade.from.favourite) * eased
        )
        self.fade = t < 1 ? fade : nil
        render()
        return t < 1
    }

    /// いまの明るさと見た目の設定から、グラデーションの色とアイコンを決め直す。
    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let isLit = levels.boost > 0 || levels.favourite > 0
        for layer in [glow, bloom] {
            layer.isHidden = !isLit
        }
        guard isLit, let style = current?.style else {
            for icon in icons { icon.alpha = 0 }
            return
        }
        let isDark = traitCollection.userInterfaceStyle == .dark
        let boostColor = Self.srgb(.systemGreen, traits: traitCollection)
        // 白い背景では黄色が見えにくいため、ライトモードでは既定で橙に寄せる。設定で黄色にもできる。
        let favouriteColor = Self.srgb(isDark || style.lightFavouriteIsYellow ? .systemYellow : .systemOrange, traits: traitCollection)
        func makeGradient(_ levels: Levels) -> ReactionGlowGradient {
            ReactionGlowGradient(
                boost: boostColor,
                favourite: favouriteColor,
                boostLevel: levels.boost,
                favouriteLevel: levels.favourite,
                blendFraction: bounds.width > 0 ? style.blendWidth / bounds.width : 0,
                space: style.mixSpace,
                fillsWidthWhenAlone: style.fillsWidthWhenAlone
            )
        }
        let gradient = makeGradient(levels)
        let stops = gradient.stops()
        let locations = stops.map { NSNumber(value: $0.location) }
        // にじみを、白より明るいHDRの色で描く。ライトでは照らされた側もHDRの色にし、白い背景の上に白より明るい光を足す。
        // ダークでは照らされた側はSDRのまま。黒い背景の上ではSDRの色でも十分に明るく見えるため。
        // HDRで描けない画面（白より明るくできる余地が1倍）では、SDRで描く。白より明るい色は白に丸められ、ライトでは光が白い背景に溶けて見えなくなるため。
        let exposure = canDrawHDR && style.allowsHDR ? style.hdrExposure : 1
        // ライトでHDRを使うときは、照らされた面を「背景の白＋光」の色で描く。光の色を明るくして白に重ねるだけでは、
        // 光の色にない成分（橙なら青）が白より暗くなり、面が明るくならずに色が付いて見えるだけになるため。
        let addsLight = !isDark && exposure > 1
        let white = SRGBColor(red: 1, green: 1, blue: 1)
        let colors = stops.map { stop in
            addsLight
                ? Self.cgColor(white.lightAdded(stop.color, intensity: style.lightIntensity), alpha: stop.alpha)
                : Self.cgColor(stop.color, alpha: stop.alpha, exposure: isDark && canDrawHDR && style.allowsHDR ? style.darkGlowHDRExposure : 1)
        }
        let bloomColors = stops.map { stop in
            addsLight
                ? Self.cgColor(white.lightAdded(stop.color, intensity: style.lightIntensity * style.lightBloomIntensityRatio), alpha: stop.alpha)
                : Self.cgColor(stop.color, alpha: stop.alpha, exposure: exposure)
        }
        for (layer, layerColors) in [(glow, colors), (bloom, bloomColors)] {
            layer.colors = layerColors
            layer.locations = locations
        }
        // 白より明るい色は、レイヤーがHDRで描くと決めたときだけ、白で頭打ちにならずに描かれる。
        let usesHDR = exposure > 1 || (isDark && canDrawHDR && style.allowsHDR && style.darkGlowHDRExposure > 1)
        let dynamicRange: CALayer.DynamicRange = usesHDR ? .high : .standard
        for layer in [glow, bloom] {
            layer.preferredDynamicRange = dynamicRange
        }
        // 光を足すときは、濃さは縦の形（falloff）と区切りの濃さだけで決める。重ねる濃さを下げると、足した光がそのぶん弱まるため。
        glow.opacity = Float(isDark ? style.darkOpacity : addsLight ? style.lightHDROpacity : style.lightOpacity)
        bloom.opacity = Self.bloomOpacity
        let bloomHeight = min(Self.bloomHeight, bounds.height)
        bloom.frame = CGRect(x: 0, y: bounds.height - bloomHeight, width: bounds.width, height: bloomHeight)
        bloomFalloff.frame = bloom.bounds
        glow.frame = bounds
        falloff.frame = glow.bounds
        // アイコンは光の色のまま薄く出す。光より目立たせないため。
        renderIcons(style: style, gradient: gradient, makeGradient: makeGradient, boost: boostColor, favourite: favouriteColor)
    }

    private func renderIcons(style: ReactionGlow.Style, gradient: ReactionGlowGradient, makeGradient: (Levels) -> ReactionGlowGradient, boost: SRGBColor, favourite: SRGBColor) {
        let placements: [IconPlacement] = switch style.iconStyle {
        case .none: []
        case .atBottom: bottomPlacements(style: style, boost: boost, favourite: favourite)
        case .scattered: scatteredPlacements(style: style, gradient: gradient, makeGradient: makeGradient)
        }
        while icons.count < placements.count {
            let icon = IconView()
            addSubview(icon)
            icons.append(icon)
        }
        for (index, icon) in icons.enumerated() {
            guard placements.indices.contains(index) else {
                icon.alpha = 0
                continue
            }
            icon.apply(placements[index])
        }
    }

    /// 両方なら、それぞれの半分の真ん中に置く。全幅に広げるときは、片方だけなら真ん中に置き、もう片方が点くのに合わせて半分の真ん中へ寄せる。
    /// 視差効果を減らす設定では、アイコンを動かさずに行き先へ置き、濃さだけを変える。
    private func bottomPlacements(style: ReactionGlow.Style, boost: SRGBColor, favourite: SRGBColor) -> [IconPlacement] {
        let positionLevels = UIAccessibility.isReduceMotionEnabled ? fade?.to ?? levels : levels
        let boostX = style.fillsWidthWhenAlone ? 0.5 - 0.25 * positionLevels.favourite : 0.25
        let favouriteX = style.fillsWidthWhenAlone ? 0.5 + 0.25 * positionLevels.boost : 0.75
        let lift = Self.iconBottomGap
        let maxHeight = iconAreaHeight - lift - Self.iconTextGap
        return [
            IconPlacement(kind: .boost, x: bounds.width * boostX, bottom: bounds.height - lift, size: style.iconSize, maxHeight: maxHeight, color: boost, alpha: levels.boost * style.iconOpacity),
            IconPlacement(kind: .favourite, x: bounds.width * favouriteX, bottom: bounds.height - lift, size: style.iconSize, maxHeight: maxHeight, color: favourite, alpha: levels.favourite * style.iconOpacity),
        ]
    }

    /// 決まった並びで散らす。行ごとに並びを変えると、流れる一覧の中でちらついて見えるため。
    /// 置き場所ごとに、その位置で多くを占める色でどちらのアイコンかを決める。止まっているときは一方だけを出す。
    /// 点けたり消したりして入れ替わる置き場所は、動く前のアイコンから動いたあとのアイコンへ、動きの進み具合に合わせてクロスフェードする。
    /// 今の明るさで決めると、置き場所ごとに別々の瞬間に絵がぱっと入れ替わってちらつき、割合で濃さを分け合うと、2色が混ざる真ん中で止まったあとも2つが重なって見えるため。
    ///
    /// アイコンも光源に照らされているものとして描く。光源（下の端）に近いほど濃く、遠いほど薄くし、色はその位置を照らす光の色にする。
    /// 点けたり消したりする途中は、光源から遠いアイコンほど、明るさを遅れて立ち上げ、早く落とす。下から上へ光が広がり、消えるときは光源のそばが最後まで残る。
    private func scatteredPlacements(
        style: ReactionGlow.Style,
        gradient: ReactionGlowGradient,
        makeGradient: (Levels) -> ReactionGlowGradient
    ) -> [IconPlacement] {
        let count = max(Int(bounds.width / 22), 1)
        let base = Self.iconBottomGap
        let highestLift = base + max(iconAreaHeight - base, 0) / 2
        let target = fade?.iconTo ?? levels
        let source = fade?.iconFrom ?? levels
        let targetGradient = makeGradient(target)
        let sourceGradient = makeGradient(source)
        /// 消えている状態では、どちらのアイコンかは決まらない。
        func isFavourite(at x: Double, in gradient: ReactionGlowGradient, levels: Levels) -> Bool? {
            levels.boost > 0 || levels.favourite > 0 ? gradient.sample(at: x).favouriteShare > 0.5 : nil
        }
        return (0..<count).flatMap { index -> [IconPlacement] in
            let i = Double(index)
            let x = (i + 0.5 + (Self.fraction(i * 0.618) - 0.5) * 0.7) / Double(count)
            let size = style.iconSize * (0.6 + Self.fraction(i * 0.754 + 0.3) * 0.5)
            // 余白の下半分の中で高さをずらし、大きさは余白の残りに収める。
            let lift = base + Self.fraction(i * 0.382 + 0.1) * max(iconAreaHeight - base, 0) / 2
            let maxHeight = iconAreaHeight - lift - Self.iconTextGap
            // 照らす明るさと沈む深さは、余白に収めて縮めたあとの大きさで測る。縮める前の大きさで測ると、大きなアイコンの中ほどが光の外に出て、すべて消えるため。
            let drawnSize = min(size, max(maxHeight, 0))
            // 光源からの遠さ。並びの中でいちばん低いアイコンが0、いちばん高いアイコンが1。
            let distance = highestLift > base ? (lift - base) / (highestLift - base) : 0
            let delay = 1 + style.iconRiseDelay * distance
            let sample = gradient.sample(at: x)
            // 照らされた側と同じ減り方で、アイコンの中ほどの高さの明るさを決める。
            let illumination = Self.falloff(at: bounds.height > 0 ? (lift + drawnSize / 2) / bounds.height : 0)
            let alpha = pow(sample.alpha, delay) * illumination * style.iconOpacity
            let slotProgress = fade?.iconProgress(delay: delay) ?? 1
            let toFavourite = isFavourite(at: x, in: targetGradient, levels: target) ?? isFavourite(at: x, in: sourceGradient, levels: source) ?? false
            let fromFavourite = isFavourite(at: x, in: sourceGradient, levels: source) ?? toFavourite
            // 入れ替わる置き場所は、前半で古い記号を光源へ沈めながら消し、後半で新しい記号を光源から昇らせながら出す。
            // 2つの形を同時に見せないため。沈む深さは、記号が下の端の向こうへ隠れきるところまで。視差効果を減らす設定では動かさない。
            let changes = fromFavourite != toFavourite
            let sinkDepth = UIAccessibility.isReduceMotionEnabled ? 0 : lift + drawnSize
            let leaving = changes ? min(slotProgress * 2, 1) : 0
            let arriving = changes ? max(slotProgress * 2 - 1, 0) : 1
            let oldShare = changes ? 1 - leaving : 0
            let newShare = changes ? arriving : 1
            // 沈むときは光源へ向けて速め、昇るときは光源を出てから緩める。
            let oldOffset = sinkDepth * leaving * leaving
            let newOffset = sinkDepth * pow(1 - arriving, 2)
            let favourite = (share: toFavourite ? newShare : oldShare, offset: toFavourite ? newOffset : oldOffset)
            let boost = (share: toFavourite ? oldShare : newShare, offset: toFavourite ? oldOffset : newOffset)
            // 並びの中の位置で、どちらのアイコンのビューかを決めておく。ビューが絵を描き直さずに済み、濃さだけが変わる。
            return [(IconPlacement.Kind.boost, boost), (.favourite, favourite)].map { kind, state in
                IconPlacement(
                    kind: kind,
                    x: bounds.width * x,
                    bottom: bounds.height - lift + state.offset,
                    size: size,
                    maxHeight: maxHeight,
                    color: sample.color,
                    alpha: alpha * state.share
                )
            }
        }
    }

    /// 照らされた側の縦の形（`falloff`）と同じ減り方。`height`は下の端から測った、光の高さに対する割合で、0が光源。
    private static func falloff(at height: Double) -> Double {
        let points: [(height: Double, alpha: Double)] = [(0, 1), (0.15, 0.65), (0.35, 0.3), (0.65, 0.08), (1, 0)]
        let h = min(max(height, 0), 1)
        for (lower, upper) in zip(points, points.dropFirst()) where h <= upper.height {
            let t = (h - lower.height) / (upper.height - lower.height)
            return lower.alpha + (upper.alpha - lower.alpha) * t
        }
        return 0
    }

    private static func fraction(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    /// 下の端のすぐ上に重ねる、いちばん明るいにじみの高さと濃さ。実機で見比べて決めた。
    private static let bloomHeight: CGFloat = 1
    private static let bloomOpacity: Float = 1

    /// アイコンと、その上の本文とのすき間。
    private static let iconTextGap: CGFloat = 1
    /// アイコンと、行の下の端とのすき間。
    private static let iconBottomGap: CGFloat = 1

    /// - Parameter exposure: SDRの白の何倍の明るさにするか。1を超えると、明るさの余地（headroom）を使うHDRの色になる。
    ///   HDRの色の成分は0...1で渡す決まりなので、広い色域で外に出た成分は丸める。
    private static func cgColor(_ color: ExposedColor, alpha: Double) -> CGColor {
        cgColor(color.color, alpha: alpha, exposure: color.exposure)
    }

    private static func cgColor(_ color: SRGBColor, alpha: Double, exposure: CGFloat = 1) -> CGColor {
        guard exposure > 1 else {
            return UIColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha).cgColor
        }
        func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
        return UIColor(red: clamped(color.red), green: clamped(color.green), blue: clamped(color.blue), alpha: alpha, linearExposure: exposure).cgColor
    }

    /// `UIColor`の成分は、広い色域でも0...1の外に出る形のsRGBで取れる。
    private static func srgb(_ color: UIColor, traits: UITraitCollection) -> SRGBColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SRGBColor(red: red, green: green, blue: blue)
    }

    /// ライトでSDRで描くときだけ、専用の高さを使う。
    private var glowHeight: CGFloat {
        guard let style = current?.style else { return 0 }
        let isDark = traitCollection.userInterfaceStyle == .dark
        let drawsLightInHDR = canDrawHDR && style.allowsHDR && style.hdrExposure > 1
        return !isDark && !drawsLightInHDR ? style.lightSDRHeight : style.height
    }

    /// 置かれた画面が、SDRの白より明るく描けるか。画面に置かれる前は分からないので、描けないものとして扱い、置かれたら描き直す。
    private var canDrawHDR: Bool {
        (window?.windowScene?.screen.potentialEDRHeadroom ?? 1) > 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // HDRで描けるかが分かると、ライトの光の高さが変わることがあるため、行の中身に並べ直してもらう。
        superview?.setNeedsLayout()
        render()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 枠と、混ぜる幅（幅に対する割合で渡す）が変わるため、描き直す。
        render()
    }
}

private struct IconPlacement {
    enum Kind {
        case boost
        case favourite

        var symbolName: String {
            switch self {
            case .boost: "arrow.2.squarepath"
            case .favourite: "star.fill"
            }
        }
    }

    var kind: Kind
    var x: CGFloat
    /// アイコンの下の端の位置。
    var bottom: CGFloat
    /// 記号の文字の大きさ。描いた画像は、これより少し高くなる。
    var size: CGFloat
    /// 描いた画像の高さの上限。超えるときは縮める。
    var maxHeight: CGFloat
    var color: SRGBColor
    var alpha: Double
}

/// 光に添えるアイコン。読み上げでは、行のラベルの「ブースト済み」「お気に入り済み」で伝えるため、読まない。
private final class IconView: UIImageView {
    private var shown: (kind: IconPlacement.Kind, size: CGFloat)?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = false
        contentMode = .scaleAspectFit
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ placement: IconPlacement) {
        if shown?.kind != placement.kind || shown?.size != placement.size {
            image = UIImage(systemName: placement.kind.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: placement.size, weight: .bold))
            shown = (placement.kind, placement.size)
        }
        sizeToFit()
        guard placement.maxHeight > 0, bounds.height > 0 else {
            alpha = 0
            return
        }
        let scale = min(1, placement.maxHeight / bounds.height)
        bounds.size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        center = CGPoint(x: placement.x, y: placement.bottom - bounds.height / 2)
        tintColor = UIColor(red: placement.color.red, green: placement.color.green, blue: placement.color.blue, alpha: 1)
        alpha = placement.alpha
    }
}

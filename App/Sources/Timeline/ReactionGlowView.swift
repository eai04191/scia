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
        var darkOpacity: CGFloat
        var lightOpacity: CGFloat
        /// 下の端のすぐ上に重ねる、いちばん明るいにじみの高さと濃さ。
        var bloomHeight: CGFloat
        var bloomOpacity: CGFloat
        /// にじみを、SDRの白の何倍の明るさで描くか。1ならSDRのまま描く。HDRで描ける画面でだけ、白より明るく光る。
        var hdrExposure: CGFloat
        /// 使う人がHDRで光らせることを選んでいるか。オフなら、HDRで描ける画面でもSDRで描く。
        var allowsHDR: Bool
        /// ライトモードでHDRで描くときの、照らす光の強さ。白い背景にこの強さで光を足し、白より明るくする。
        var lightIntensity: Double
        var fillsWidthWhenAlone: Bool
        var iconStyle: IconStyle
        var iconSize: CGFloat
        var iconOpacity: Double
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

        /// チューニングの数値（0: なし、1: 下の端、2: 散らす）から選ぶ。
        init(_ value: Double) {
            self = switch value {
            case 1: .atBottom
            case 2: .scattered
            default: .none
            }
        }
    }

    /// 読み上げで、名前や本文に続けて読む状態。
    var accessibilityText: String? {
        let parts = [isReblogged ? "ブースト済み" : nil, isFavourited ? "お気に入り済み" : nil].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }
}

extension ReactionGlow.Style {
    @MainActor
    init(tuning: TuningStore, settings: AppSettings) {
        self.init(
            height: tuning.value(of: TuningCatalog.reactionGlowHeight),
            darkOpacity: tuning.value(of: TuningCatalog.reactionGlowDarkOpacity),
            lightOpacity: tuning.value(of: TuningCatalog.reactionGlowLightOpacity),
            bloomHeight: tuning.value(of: TuningCatalog.reactionGlowBloomHeight),
            bloomOpacity: tuning.value(of: TuningCatalog.reactionGlowBloomOpacity),
            hdrExposure: tuning.value(of: TuningCatalog.reactionGlowHDRExposure),
            allowsHDR: settings.drawsReactionGlowInHDR,
            lightIntensity: tuning.value(of: TuningCatalog.reactionGlowLightIntensity),
            fillsWidthWhenAlone: tuning.value(of: TuningCatalog.reactionGlowFillsWidthWhenAlone),
            iconStyle: ReactionGlow.IconStyle(tuning.value(of: TuningCatalog.reactionGlowIconStyle)),
            iconSize: tuning.value(of: TuningCatalog.reactionGlowIconSize),
            iconOpacity: tuning.value(of: TuningCatalog.reactionGlowIconOpacity),
            blendWidth: tuning.value(of: TuningCatalog.reactionGlowBlendWidth),
            mixSpace: tuning.value(of: TuningCatalog.reactionGlowMixesInOKLab) ? .oklab : .linear,
            duration: tuning.value(of: TuningCatalog.reactionGlowDuration)
        )
    }
}

/// 行の中身の後ろに敷いて、下の端に置く。行の大きさには関わらない。
///
/// 左から右への色と濃さは、1本のグラデーション（`ReactionGlowGradient`）で描く。縦に上へ薄くなる形は、それにマスクで付ける。
final class ReactionGlowView: UIView {
    /// 白い背景では黄色が見えにくいため、ライトモードでは橙に寄せる。
    private static let favouriteColor = UIColor { $0.userInterfaceStyle == .dark ? .systemYellow : .systemOrange }

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
    private lazy var ticker = FrameTicker { [weak self] elapsed in
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
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
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
        let height = min(current?.style.height ?? 0, bounds.height)
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
            fade = Fade(from: levels, to: target, duration: duration * distance)
            if !ticker.isRunning { ticker.start() }
        }
        render()
    }

    private func step(_ elapsed: CFTimeInterval) -> Bool {
        guard var fade else { return false }
        fade.elapsed += elapsed
        let t = fade.duration > 0 ? min(fade.elapsed / fade.duration, 1) : 1
        let eased = 1 - pow(1 - t, 3)
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
        let favouriteColor = Self.srgb(Self.favouriteColor, traits: traitCollection)
        let gradient = ReactionGlowGradient(
            boost: boostColor,
            favourite: favouriteColor,
            boostLevel: levels.boost,
            favouriteLevel: levels.favourite,
            blendFraction: bounds.width > 0 ? style.blendWidth / bounds.width : 0,
            space: style.mixSpace,
            fillsWidthWhenAlone: style.fillsWidthWhenAlone
        )
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
                : Self.cgColor(stop.color, alpha: stop.alpha)
        }
        let bloomColors = stops.map { stop in
            addsLight
                ? Self.cgColor(white.lightAdded(stop.color, intensity: style.lightIntensity * 2), alpha: stop.alpha)
                : Self.cgColor(stop.color, alpha: stop.alpha, exposure: exposure)
        }
        for (layer, layerColors) in [(glow, colors), (bloom, bloomColors)] {
            layer.colors = layerColors
            layer.locations = locations
        }
        // 白より明るい色は、レイヤーがHDRで描くと決めたときだけ、白で頭打ちにならずに描かれる。
        let dynamicRange: CALayer.DynamicRange = exposure > 1 ? .high : .standard
        for layer in [glow, bloom] {
            layer.preferredDynamicRange = dynamicRange
        }
        // 光を足すときは、濃さは縦の形（falloff）と区切りの濃さだけで決める。重ねる濃さを下げると、足した光がそのぶん弱まるため。
        glow.opacity = Float(isDark ? style.darkOpacity : addsLight ? 1 : style.lightOpacity)
        bloom.opacity = Float(style.bloomOpacity)
        let bloomHeight = min(max(style.bloomHeight, 0), bounds.height)
        bloom.frame = CGRect(x: 0, y: bounds.height - bloomHeight, width: bounds.width, height: bloomHeight)
        bloomFalloff.frame = bloom.bounds
        glow.frame = bounds
        falloff.frame = glow.bounds
        // アイコンは光の色のまま薄く出す。光より目立たせないため。
        renderIcons(style: style, gradient: gradient, boost: boostColor, favourite: favouriteColor)
    }

    private func renderIcons(style: ReactionGlow.Style, gradient: ReactionGlowGradient, boost: SRGBColor, favourite: SRGBColor) {
        let placements: [IconPlacement] = switch style.iconStyle {
        case .none: []
        case .atBottom: bottomPlacements(style: style, boost: boost, favourite: favourite)
        case .scattered: scatteredPlacements(style: style, gradient: gradient)
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
    /// どちらのアイコンにするかは、その位置で多くを占める色で決める。
    private func scatteredPlacements(style: ReactionGlow.Style, gradient: ReactionGlowGradient) -> [IconPlacement] {
        let count = max(Int(bounds.width / 22), 1)
        return (0..<count).map { index in
            let i = Double(index)
            let x = (i + 0.5 + (Self.fraction(i * 0.618) - 0.5) * 0.7) / Double(count)
            let size = style.iconSize * (0.6 + Self.fraction(i * 0.754 + 0.3) * 0.5)
            // 余白の下半分の中で高さをずらし、大きさは余白の残りに収める。
            let base = Self.iconBottomGap
            let lift = base + Self.fraction(i * 0.382 + 0.1) * max(iconAreaHeight - base, 0) / 2
            let sample = gradient.sample(at: x)
            return IconPlacement(
                kind: sample.favouriteShare > 0.5 ? .favourite : .boost,
                x: bounds.width * x,
                bottom: bounds.height - lift,
                size: size,
                maxHeight: iconAreaHeight - lift - Self.iconTextGap,
                color: sample.color,
                alpha: sample.alpha * style.iconOpacity * (0.4 + Self.fraction(i * 0.29 + 0.6) * 0.6)
            )
        }
    }

    private static func fraction(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    /// アイコンと、その上の本文とのすき間。
    private static let iconTextGap: CGFloat = 1
    /// アイコンと、行の下の端とのすき間。
    private static let iconBottomGap: CGFloat = 1

    /// - Parameter exposure: SDRの白の何倍の明るさにするか。1を超えると、明るさの余地（headroom）の印が付いたHDRの色になる。
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

    /// 置かれた画面が、SDRの白より明るく描けるか。画面に置かれる前は分からないので、描けないものとして扱い、置かれたら描き直す。
    private var canDrawHDR: Bool {
        (window?.windowScene?.screen.potentialEDRHeadroom ?? 1) > 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
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

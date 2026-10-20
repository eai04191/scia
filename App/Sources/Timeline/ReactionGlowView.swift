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
        var lineWidth: CGFloat
        var lineOpacity: CGFloat
        /// 線の芯を白に寄せる割合。
        var darkLineCoreWhiteness: Double
        var lightLineCoreWhiteness: Double
        var lineBloomHeight: CGFloat
        /// ライトモードで、行の下の端の近くに敷く陰の濃さ。
        var lightShadeOpacity: Double
        /// ライトモードで、芯を行の下の端から持ち上げる高さ。芯の下にも陰が入り、芯が上下とも背景より明るく見える。
        var lightCoreLift: CGFloat
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
        /// 光の下の線の上に、ブーストとお気に入りのアイコンを1つずつ載せる。光源そのものをアイコンにする。
        case onLine
        /// 下の端に、小さなアイコンを大きさと濃さを変えて散らす。本文と重ならないよう、下の余白の高さに収める。
        case scattered

        /// チューニングの数値（0: なし、1: 線の上、2: 散らす）から選ぶ。
        init(_ value: Double) {
            self = switch value {
            case 1: .onLine
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
    init(tuning: TuningStore) {
        self.init(
            height: tuning.value(of: TuningCatalog.reactionGlowHeight),
            darkOpacity: tuning.value(of: TuningCatalog.reactionGlowDarkOpacity),
            lightOpacity: tuning.value(of: TuningCatalog.reactionGlowLightOpacity),
            lineWidth: tuning.value(of: TuningCatalog.reactionGlowLineWidth),
            lineOpacity: tuning.value(of: TuningCatalog.reactionGlowLineOpacity),
            darkLineCoreWhiteness: tuning.value(of: TuningCatalog.reactionGlowDarkLineCoreWhiteness),
            lightLineCoreWhiteness: tuning.value(of: TuningCatalog.reactionGlowLightLineCoreWhiteness),
            lineBloomHeight: tuning.value(of: TuningCatalog.reactionGlowLineBloomHeight),
            lightShadeOpacity: tuning.value(of: TuningCatalog.reactionGlowLightShadeOpacity),
            lightCoreLift: tuning.value(of: TuningCatalog.reactionGlowLightCoreLift),
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
    /// 光の縦の形。ダークとライトで形を変える（`render()`）。
    private let falloff = CAGradientLayer()
    private let line = CAGradientLayer()
    /// ライトモードで、行の下の端の近くにだけ敷く、ごく薄い陰。光が届かなくなるあたりと、上へ向けた照明の下に置く。
    /// 白い背景より明るいものは描けないため、光源から離れたところを少し暗くして、光源がいちばん明るく見えるようにする。
    private let shade = CAGradientLayer()
    /// 線のまわりの色のにじみ。下の端から上へすぐに消える。
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
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(shade)
        for gradient in [glow, bloom, line] {
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
        // 芯のすぐ上を濃くし、上へすばやく薄くする。芯のまわりに色が集まっていると、芯が光って見える。
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
        for layer in [shade, glow, bloom, line] {
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
        let whiteness = isDark ? style.darkLineCoreWhiteness : style.lightLineCoreWhiteness
        let locations = stops.map { NSNumber(value: $0.location) }
        let colors = stops.map { Self.cgColor($0.color, alpha: $0.alpha) }
        let coreColors = stops.map { Self.cgColor(Self.core($0.color, whiteness: whiteness), alpha: $0.alpha) }
        for (layer, layerColors) in [(glow, colors), (line, coreColors)] {
            layer.colors = layerColors
            layer.locations = locations
        }
        // にじみは、ダークでは光の色で芯を包む。ライトでは芯と同じ白に近い色にし、芯のすぐ上をいちばん明るくする。
        // ライトで光の色のにじみを芯に当てると、芯のすぐ上が芯より暗くなり、光源のまわりが明るく見えないため。
        bloom.colors = isDark ? colors : coreColors
        bloom.locations = locations
        glow.opacity = Float(isDark ? style.darkOpacity : style.lightOpacity)
        line.opacity = Float(style.lineOpacity)
        bloom.opacity = Float(style.lineOpacity) * (isDark ? 0.6 : 1)
        // 光源から上へ、明るさがどう落ちていくか。ダークでは光源のそばほど光の色が濃い。
        // ライトでは光源のそばは白に近く、離れるにつれて光の色が出て、その先で薄い陰になり、投稿の白に戻る。
        falloff.locations = isDark ? [0, 0.35, 0.65, 0.85, 1] : [0, 0.3, 0.7, 1]
        falloff.colors = (isDark ? [0, 0.08, 0.3, 0.65, 1] : [0, 1, 0.7, 0.25]).map { UIColor(white: 0, alpha: $0).cgColor }
        // ライトでは、照明を行の下の端から持ち上げ、その下を照明の陰にする。光は上にしか向かないため。
        let coreLift = isDark ? 0 : min(max(style.lightCoreLift, 0), bounds.height)
        let litBottom = bounds.height - coreLift
        line.frame = CGRect(x: 0, y: max(litBottom - style.lineWidth, 0), width: bounds.width, height: min(style.lineWidth, litBottom))
        let bloomHeight = min(style.lineBloomHeight + style.lineWidth, litBottom)
        bloom.frame = CGRect(x: 0, y: litBottom - bloomHeight, width: bounds.width, height: bloomHeight)
        bloomFalloff.frame = bloom.bounds
        glow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: litBottom)
        falloff.frame = glow.bounds
        renderShade(style: style, isDark: isDark, litBottom: litBottom, bloomHeight: bloomHeight)
        // アイコンは芯の白に寄せず、光の色のまま薄く出す。白に寄せると、ライトでは背景に溶け、ダークでは光より目立つため。
        renderIcons(style: style, gradient: gradient, boost: boostColor, favourite: favouriteColor)
    }

    /// 陰は黒の濃さで描き、光が点いたり消えたりするのに合わせて濃さを変える。ダークの背景では見えず、光を濁らせるだけなので出さない。
    private func renderShade(style: ReactionGlow.Style, isDark: Bool, litBottom: CGFloat, bloomHeight: CGFloat) {
        let opacity = style.lightShadeOpacity * (1 - (1 - levels.boost) * (1 - levels.favourite))
        shade.isHidden = isDark || opacity == 0 || bounds.height == 0
        guard !shade.isHidden else { return }
        shade.frame = bounds
        let height = bounds.height
        // 上から順に、投稿の白、光が届かなくなるあたりの陰、光源のそばの明るいところ（陰なし）、照明の下の陰。
        let fadeIn = 0.3 * litBottom / height
        let bright = max((litBottom - bloomHeight) / height, fadeIn)
        let core = litBottom / height
        shade.locations = [0, fadeIn, bright, core, core, 1].map { NSNumber(value: Double($0)) }
        shade.colors = [0, 1, 0, 0, 1, 1].map { UIColor(white: 0, alpha: opacity * $0).cgColor }
    }

    private func renderIcons(style: ReactionGlow.Style, gradient: ReactionGlowGradient, boost: SRGBColor, favourite: SRGBColor) {
        let placements: [IconPlacement] = switch style.iconStyle {
        case .none: []
        case .onLine: onLinePlacements(style: style, boost: boost, favourite: favourite)
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
    private func onLinePlacements(style: ReactionGlow.Style, boost: SRGBColor, favourite: SRGBColor) -> [IconPlacement] {
        let positionLevels = UIAccessibility.isReduceMotionEnabled ? fade?.to ?? levels : levels
        let boostX = style.fillsWidthWhenAlone ? 0.5 - 0.25 * positionLevels.favourite : 0.25
        let favouriteX = style.fillsWidthWhenAlone ? 0.5 + 0.25 * positionLevels.boost : 0.75
        let lift = style.lineWidth + coreLift + 1
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
            let base = style.lineWidth + coreLift + 1
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

    /// ライトモードで芯を持ち上げる高さ。アイコンも、その分だけ上に置く。
    private var coreLift: CGFloat {
        traitCollection.userInterfaceStyle == .dark ? 0 : current?.style.lightCoreLift ?? 0
    }

    private static func fraction(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    /// アイコンと、その上の本文とのすき間。
    private static let iconTextGap: CGFloat = 1

    /// 光源の芯の色。光源は中心が白く飛んで見えるため、光の強さで白に寄せる。
    private static func core(_ color: SRGBColor, whiteness: Double) -> SRGBColor {
        whiteness > 0 ? color.mixed(with: SRGBColor(red: 1, green: 1, blue: 1), fraction: whiteness, in: .linear) : color
    }

    private static func cgColor(_ color: SRGBColor, alpha: Double) -> CGColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha).cgColor
    }

    /// `UIColor`の成分は、広い色域でも0...1の外に出る形のsRGBで取れる。
    private static func srgb(_ color: UIColor, traits: UITraitCollection) -> SRGBColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SRGBColor(red: red, green: green, blue: blue)
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

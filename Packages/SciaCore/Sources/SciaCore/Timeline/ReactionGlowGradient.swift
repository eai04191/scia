import Foundation

/// sRGBの値で表した色。各成分は、ガンマで符号化された0...1の値。広い色域の色は、0...1の外に出ることがある。
public struct SRGBColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// 2つの色を混ぜる空間。sRGBの値のまま混ぜると、途中の色が暗くくすむため、どちらかに直してから混ぜる。
public enum ColorMixSpace: Sendable {
    /// 光の強さに比例する値（ガンマを外した値）で混ぜる。光を重ねたときの色になる。
    case linear
    /// 見た目の明るさと色みが均等に変わるOKLabで混ぜる。
    case oklab
}

extension SRGBColor {
    /// `fraction`が0なら自分、1なら`other`。
    public func mixed(with other: SRGBColor, fraction: Double, in space: ColorMixSpace) -> SRGBColor {
        switch space {
        case .linear:
            let a = linear, b = other.linear
            return SRGBColor(linear: Self.lerp(a, b, fraction))
        case .oklab:
            let a = oklab, b = other.oklab
            return SRGBColor(oklab: Self.lerp(a, b, fraction))
        }
    }

    private static func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }

    /// ガンマを外した値。広い色域の負の値も、符号を保って変換する。
    var linear: SIMD3<Double> {
        SIMD3(Self.decode(red), Self.decode(green), Self.decode(blue))
    }

    init(linear: SIMD3<Double>) {
        self.init(red: Self.encode(linear.x), green: Self.encode(linear.y), blue: Self.encode(linear.z))
    }

    /// 変換の係数は、OKLabの定義（https://bottosson.github.io/posts/oklab/ ）による。
    var oklab: SIMD3<Double> {
        let rgb = linear
        let l = 0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z
        let m = 0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z
        let s = 0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z
        let l3 = cbrt(l), m3 = cbrt(m), s3 = cbrt(s)
        return SIMD3(
            0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3,
            1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3,
            0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3
        )
    }

    init(oklab lab: SIMD3<Double>) {
        let l3 = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m3 = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s3 = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l3 * l3 * l3, m = m3 * m3 * m3, s = s3 * s3 * s3
        self.init(linear: SIMD3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        ))
    }

    private static func decode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let decoded = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return value < 0 ? -decoded : decoded
    }

    private static func encode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let encoded = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return value < 0 ? -encoded : encoded
    }
}

/// お気に入りとブーストの光の、左から右への色と濃さ。両方光っていれば、左半分がブースト、右半分がお気に入りで、真ん中の混ぜる幅の中で入れ替わる。
///
/// 2色を別々に薄くして重ねると、真ん中で覆う割合が足りずに暗くなり、上に重ねた色が勝つ。
/// 1本のグラデーションで、位置ごとに2色の重みから濃さと色を決める。重みの和は1を超えず、両方光っていれば真ん中も同じ濃さになる。
public struct ReactionGlowGradient: Equatable, Sendable {
    public struct Stop: Equatable, Sendable {
        /// 左の端が0、右の端が1。
        public var location: Double
        public var color: SRGBColor
        /// 0...1。
        public var alpha: Double
        /// 色のうち、お気に入りの色が占める割合。0ならブーストの色だけ。
        public var favouriteShare: Double
    }

    public var boost: SRGBColor
    public var favourite: SRGBColor
    public var boostLevel: Double
    public var favouriteLevel: Double
    public var blendFraction: Double
    public var space: ColorMixSpace
    public var fillsWidthWhenAlone: Bool

    /// - Parameters:
    ///   - boostLevel: ブーストの光の明るさ。点けたり消したりする途中は、0と1のあいだ。
    ///   - favouriteLevel: お気に入りの光の明るさ。
    ///   - blendFraction: 真ん中で混ぜる幅の、全体の幅に対する割合。0でくっきり分ける。
    ///   - fillsWidthWhenAlone: 片方だけのときは、その色で全幅を光らせる。オフなら、片方だけでもその半分だけを光らせる。
    ///     半分だけ光った帯は、半分まで進んだ進み具合のバーのように見え、足りない印象になるため。
    public init(
        boost: SRGBColor,
        favourite: SRGBColor,
        boostLevel: Double,
        favouriteLevel: Double,
        blendFraction: Double,
        space: ColorMixSpace,
        fillsWidthWhenAlone: Bool = false
    ) {
        self.boost = boost
        self.favourite = favourite
        self.boostLevel = boostLevel
        self.favouriteLevel = favouriteLevel
        self.blendFraction = min(max(blendFraction, 0), 1)
        self.space = space
        self.fillsWidthWhenAlone = fillsWidthWhenAlone
    }

    /// `location`（左の端が0、右の端が1）での色と濃さ。
    public func sample(at location: Double) -> Stop {
        let start = 0.5 - blendFraction / 2
        let t: Double = if blendFraction > 0 {
            min(max((location - start) / blendFraction, 0), 1)
        } else {
            location < 0.5 ? 0 : 1
        }
        return sample(at: location, progress: t)
    }

    /// - Parameter t: 混ぜる幅の中の進み具合。左の端の側が0。
    private func sample(at location: Double, progress t: Double) -> Stop {
        // 入れ替わりの両端で傾きが急に変わると、そこに筋が見えるため、なめらかに入れ替える。
        let share = t * t * (3 - 2 * t)
        // 全幅に広げるときは、もう片方が光っている分だけ、自分の側でない半分を譲る。もう片方が消えていれば全幅を受け持つ。
        let boostWeight = fillsWidthWhenAlone ? boostLevel * (1 - share * favouriteLevel) : boostLevel * (1 - share)
        let favouriteWeight = fillsWidthWhenAlone ? favouriteLevel * (1 - (1 - share) * boostLevel) : favouriteLevel * share
        let alpha = boostWeight + favouriteWeight
        // 消えている側の色は描かれないが、隣の区切りとのあいだで混ざらないよう、光っている側の色にしておく。
        let fraction = alpha > 0 ? favouriteWeight / alpha : (favouriteLevel > boostLevel ? 1 : 0)
        return Stop(location: location, color: boost.mixed(with: favourite, fraction: fraction, in: space), alpha: alpha, favouriteShare: fraction)
    }

    /// 描く側に渡す区切り。描く側は区切りのあいだをsRGBの値のまま直線でつなぐため、混ぜる幅を`steps`に細かく区切って、混ぜる空間の色に寄せる。
    public func stops(steps: Int = 16) -> [Stop] {
        let start = 0.5 - blendFraction / 2
        let count = max(steps, 1)
        return [sample(at: 0, progress: 0)]
            + (0...count).map { index in
                let t = Double(index) / Double(count)
                return sample(at: start + blendFraction * t, progress: t)
            }
            + [sample(at: 1, progress: 1)]
    }
}

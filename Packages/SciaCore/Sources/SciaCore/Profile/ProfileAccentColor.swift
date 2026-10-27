public import CoreGraphics
import Foundation

/// プロフィールのアイコンやヘッダー画像から作る、カードの色。画像を代表する色を、見た目の印象を変えない範囲で少し鮮やかにする。
/// 平均色は、色の違う部分が打ち消し合ってくすむため、色相ごとに数えて一番強い色相を選び、その色相の画素だけを混ぜる。
/// 混ぜた色の明るさは残す。明るさを色相ごとの一番鮮やかに出せる明るさへ寄せると、淡い桃色が赤に、茶色がオレンジになるため。
/// 色がほとんどない画像（白黒の絵や灰色の写真）では、画像の平均の明るさの灰色にする。白黒も、その人の色として見せるため。
/// 色はOKLCHで扱い、Display P3に収まるまで鮮やかさを落とす。
public struct ProfileAccentColor: Equatable, Sendable {
    /// OKLCHの明るさ（0〜1）。
    public let lightness: Double
    /// OKLCHの鮮やかさ。
    public let chroma: Double
    /// OKLCHの色相（ラジアン）。
    public let hue: Double

    public init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    /// 選び方の値。
    public struct Options: Equatable, Sendable {
        /// 混ぜた色の明るさを収める範囲。黒に近い色と白に近い色は、カードの地にすると色に見えないため。
        public var lightness: ClosedRange<Double> = 0.3 ... 0.88
        /// 画像の色の鮮やかさに掛ける倍率。混ぜると、少しずつ違う色相が打ち消し合って淡くなる分を戻す。
        public var chromaBoost: Double = 1.5
        /// 灰色にするときの明るさを収める範囲。白や黒に近すぎると、カードが画面の地に溶けるため。
        public var neutralLightness: ClosedRange<Double> = 0.2 ... 0.86
        /// 色の付いた画素の割合の下限。これより少なく、はっきり鮮やかな画素も`minimumStrongShare`より少なければ、灰色に寄せる。どちらも下限の半分に届かなければ、灰色にする。
        /// ほぼ灰色の絵で、わずかに残った色かぶりや肌の色を、画像の色として出さないため。
        public var minimumColorfulShare: Double = 0.15
        /// はっきり鮮やかな画素の割合の下限。白や黒の地に小さく鮮やかなロゴを置いたアイコンは、色の付いた画素が少なくても色を作る。
        public var minimumStrongShare: Double = 0.03
        /// はっきり鮮やかとみなす、OKLCHの鮮やかさ。
        public var strongChroma: Double = 0.08

        public init() {}
    }

    /// 画像を縮めて色を選ぶ。透明な画像ならnil。
    public init?(image: CGImage, side: Int = 48, options: Options = Options()) {
        guard side > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: side * side * 4), count: side * side * 4)
        self.init(premultipliedRGBA: Array(pixels), options: options)
    }

    /// sRGBの、透明度を掛けたRGBAの画素の並びから色を選ぶ。
    public init?(premultipliedRGBA pixels: [UInt8], options: Options = Options()) {
        let binCount = 36
        var weights = [Double](repeating: 0, count: binCount)
        var sums = [(l: Double, a: Double, b: Double)](repeating: (0, 0, 0), count: binCount)
        var opaqueCount = 0
        var colorfulCount = 0
        var strongCount = 0
        var lightnessSum = 0.0
        for offset in stride(from: 0, to: pixels.count - 3, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha >= 0.5 else { continue }
            opaqueCount += 1
            let lab = OKLab(
                srgbRed: Double(pixels[offset]) / 255 / alpha,
                green: Double(pixels[offset + 1]) / 255 / alpha,
                blue: Double(pixels[offset + 2]) / 255 / alpha
            )
            let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            lightnessSum += lab.l
            // 暗すぎる画素と白に近い画素は、色相が定まらないので数えない。
            guard chroma > 0.04, lab.l > 0.25, lab.l < 0.97 else { continue }
            colorfulCount += 1
            if chroma > options.strongChroma { strongCount += 1 }
            var hue = atan2(lab.b, lab.a)
            if hue < 0 { hue += 2 * .pi }
            let bin = min(Int(hue / (2 * .pi) * Double(binCount)), binCount - 1)
            // 鮮やかな画素ほど少し強く数える。2乗で数えると、小さく鮮やかな部分が、画像の大半を占める色に勝ってしまう。
            let weight = chroma
            weights[bin] += weight
            sums[bin].l += lab.l * weight
            sums[bin].a += lab.a * weight
            sums[bin].b += lab.b * weight
        }
        guard opaqueCount > 0 else { return nil }
        let neutral = ProfileAccentColor(
            lightness: min(max(lightnessSum / Double(opaqueCount), options.neutralLightness.lowerBound), options.neutralLightness.upperBound),
            chroma: 0,
            hue: 0
        )
        // 色の多さを、下限を1とした割合で測る。下限の半分から下限までは、灰色から色へ少しずつ移す。
        // 下限で急に切り替えると、色の量が少し違うだけの似たアイコンで、灰色と色付きに分かれるため。
        let share = max(
            Double(colorfulCount) / Double(opaqueCount) / options.minimumColorfulShare,
            Double(strongCount) / Double(opaqueCount) / options.minimumStrongShare
        )
        let progress = min(max((share - 0.5) / 0.5, 0), 1)
        guard progress > 0 else {
            self = neutral
            return
        }
        let blend = progress * progress * (3 - 2 * progress)
        // 隣の色相も半分の重みで数え、境目で割れた色が負けないようにする。
        func neighbors(_ bin: Int) -> [Int] { [(bin + binCount - 1) % binCount, bin, (bin + 1) % binCount] }
        let scores = (0 ..< binCount).map { bin in weights[bin] + 0.5 * (weights[(bin + binCount - 1) % binCount] + weights[(bin + 1) % binCount]) }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else {
            self = neutral
            return
        }
        let total = neighbors(best).reduce(0) { $0 + weights[$1] }
        guard total > 0 else {
            self = neutral
            return
        }
        let l = neighbors(best).reduce(0) { $0 + sums[$1].l } / total
        let a = neighbors(best).reduce(0) { $0 + sums[$1].a } / total
        let b = neighbors(best).reduce(0) { $0 + sums[$1].b } / total
        let hue = atan2(b, a)
        let lightness = min(max(l, options.lightness.lowerBound), options.lightness.upperBound)
        let chroma = (a * a + b * b).squareRoot() * options.chromaBoost
        self = Self.fitted(lightness: neutral.lightness + (lightness - neutral.lightness) * blend, chroma: chroma * blend, hue: hue)
    }

    /// 明るさと色相を保ったまま、Display P3に収まるまで鮮やかさを落とす。
    public static func fitted(lightness: Double, chroma: Double, hue: Double) -> ProfileAccentColor {
        var low = 0.0
        var high = chroma
        if OKLab(lightness: lightness, chroma: high, hue: hue).displayP3.isInGamut {
            return ProfileAccentColor(lightness: lightness, chroma: high, hue: hue)
        }
        for _ in 0 ..< 20 {
            let middle = (low + high) / 2
            if OKLab(lightness: lightness, chroma: middle, hue: hue).displayP3.isInGamut { low = middle } else { high = middle }
        }
        return ProfileAccentColor(lightness: lightness, chroma: low, hue: hue)
    }

    /// 色の付いていない灰色。
    public var isNeutral: Bool { chroma == 0 }

    /// 同じ色相で、明るさと鮮やかさを変えた色。Display P3に収まるまで鮮やかさを落とす。
    public func with(lightness: Double, chroma: Double) -> ProfileAccentColor {
        Self.fitted(lightness: lightness, chroma: chroma, hue: hue)
    }

    /// Display P3の、ガンマを掛けた成分（0〜1）。
    public var displayP3: (red: Double, green: Double, blue: Double) {
        let rgb = OKLab(lightness: lightness, chroma: chroma, hue: hue).displayP3
        return (SRGBColor.encode(rgb.red), SRGBColor.encode(rgb.green), SRGBColor.encode(rgb.blue))
    }

    /// sRGBの、ガンマを掛けた成分。sRGBの外の色は0〜1の外に出る。
    public var srgb: (red: Double, green: Double, blue: Double) {
        let rgb = OKLab(lightness: lightness, chroma: chroma, hue: hue).linearSRGB
        return (SRGBColor.encode(rgb.red), SRGBColor.encode(rgb.green), SRGBColor.encode(rgb.blue))
    }
}

/// OKLabの色。線形のsRGBとの変換は、`SRGBColor`の変換を使う。
struct OKLab {
    let l: Double
    let a: Double
    let b: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        l = lightness
        a = chroma * cos(hue)
        b = chroma * sin(hue)
    }

    init(srgbRed red: Double, green: Double, blue: Double) {
        let lab = SRGBColor.oklab(linear: SIMD3(
            SRGBColor.decode(min(max(red, 0), 1)),
            SRGBColor.decode(min(max(green, 0), 1)),
            SRGBColor.decode(min(max(blue, 0), 1))
        ))
        l = lab.x
        a = lab.y
        b = lab.z
    }

    var linearSRGB: (red: Double, green: Double, blue: Double) {
        let rgb = SRGBColor.linear(oklab: SIMD3(l, a, b))
        return (rgb.x, rgb.y, rgb.z)
    }

    /// 線形のDisplay P3の成分。
    var displayP3: LinearRGB {
        let rgb = linearSRGB
        return LinearRGB(
            red: 0.8224621 * rgb.red + 0.1775380 * rgb.green,
            green: 0.0331941 * rgb.red + 0.9668058 * rgb.green,
            blue: 0.0170827 * rgb.red + 0.0723974 * rgb.green + 0.9105199 * rgb.blue
        )
    }
}

struct LinearRGB {
    let red: Double
    let green: Double
    let blue: Double

    var isInGamut: Bool {
        [red, green, blue].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
    }
}

/// Display P3の、ガンマを掛けた成分（0〜1）の色。文字と地のコントラストを測るのに使う。
public struct DisplayP3Color: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = DisplayP3Color(red: 1, green: 1, blue: 1)
    public static let black = DisplayP3Color(red: 0, green: 0, blue: 0)

    /// 相対輝度（0〜1）。Display P3の原色の輝度の係数で測る。
    public var relativeLuminance: Double {
        0.2289746 * SRGBColor.decode(red) + 0.6917385 * SRGBColor.decode(green) + 0.0792869 * SRGBColor.decode(blue)
    }

    /// WCAG 2.1のコントラスト比（1〜21）。
    public func contrast(with other: DisplayP3Color) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// `background`の上に、透明度`alpha`で重ねた色。UIKitと同じく、ガンマを掛けた成分のまま混ぜる。
    public func composited(over background: DisplayP3Color, alpha: Double) -> DisplayP3Color {
        DisplayP3Color(
            red: background.red + (red - background.red) * alpha,
            green: background.green + (green - background.green) * alpha,
            blue: background.blue + (blue - background.blue) * alpha
        )
    }

    /// APCA（0.0.98G-4g）の、`background`の上の文字としてのLc（およそ-108〜106）。地より暗い文字なら正、明るい文字なら負。
    /// WCAG 2.1の比と違い、文字と地のどちらが明るいかで値が変わり、明るい色の上の黒い文字を高く見積もりすぎない。
    /// 成分はAPCAのDisplay P3の係数と、2.4乗の簡単なガンマで輝度に直す。灰色では、sRGBで測った値と同じになる。
    public func apcaContrast(onBackground background: DisplayP3Color) -> Double {
        func luminance(_ color: DisplayP3Color) -> Double {
            let y = 0.2289829594805780 * pow(max(color.red, 0), 2.4)
                + 0.6917492625852380 * pow(max(color.green, 0), 2.4)
                + 0.0792677779341829 * pow(max(color.blue, 0), 2.4)
            // 黒に近い色の輝度を持ち上げる。
            return y < 0.022 ? y + pow(0.022 - y, 1.414) : y
        }
        let text = luminance(self)
        let back = luminance(background)
        guard abs(back - text) >= 0.0005 else { return 0 }
        if back > text {
            let contrast = (pow(back, 0.56) - pow(text, 0.57)) * 1.14
            return contrast < 0.1 ? 0 : (contrast - 0.027) * 100
        }
        let contrast = (pow(back, 0.65) - pow(text, 0.62)) * 1.14
        return contrast > -0.1 ? 0 : (contrast + 0.027) * 100
    }

    /// `background`の上の文字として、`target`に届くか。
    public func meets(_ target: ContrastTarget, onBackground background: DisplayP3Color) -> Bool {
        contrast(with: background) >= target.ratio && abs(apcaContrast(onBackground: background)) >= target.lc
    }

    /// `background`の上に重ねたときに、`target`に届く一番小さな透明度。1でも届かなければ1。
    /// 控えめな文字を、読める範囲でいちばん薄くするのに使う。
    public func minimumAlpha(over background: DisplayP3Color, target: ContrastTarget) -> Double {
        guard composited(over: background, alpha: 1).meets(target, onBackground: background) else { return 1 }
        var low = 0.0
        var high = 1.0
        for _ in 0 ..< 20 {
            let middle = (low + high) / 2
            if composited(over: background, alpha: middle).meets(target, onBackground: background) { high = middle } else { low = middle }
        }
        return high
    }
}

/// 文字と地に求めるコントラスト。WCAG 2.1の比とAPCAのLcの絶対値の、両方に届くことを求める。
/// APCAで見た目の読みやすさを、WCAG 2.1でアクセシビリティの基準（AppleのSufficient Contrastも同じ比で測る）を守る。
public struct ContrastTarget: Equatable, Sendable {
    /// WCAG 2.1のコントラスト比の下限。
    public var ratio: Double
    /// APCAのLcの絶対値の下限。
    public var lc: Double

    public init(ratio: Double, lc: Double) {
        self.ratio = ratio
        self.lc = lc
    }
}

/// 明るさを動かす色が、文字か地か。APCAは文字と地を入れ替えると値が変わるため、どちらとして測るかを決める。
public enum ContrastRole: Sendable {
    case text
    case background
}

extension ProfileAccentColor {
    public var displayP3Color: DisplayP3Color {
        let p3 = displayP3
        return DisplayP3Color(red: p3.red, green: p3.green, blue: p3.blue)
    }

    /// 色相を保ったまま明るさだけを動かして、`other`との間で`target`に届くようにする。`role`は、この色が文字か地か。
    /// `other`より明るい色なら明るく、暗い色なら暗くする。鮮やかさは、その明るさでDisplay P3に収まるところまで落とす。
    /// 端まで動かしても届かなければ、端の色にする。
    public func ensuringContrast(_ target: ContrastTarget, against other: DisplayP3Color, as role: ContrastRole) -> ProfileAccentColor {
        func meets(_ color: ProfileAccentColor) -> Bool {
            switch role {
            case .text: color.displayP3Color.meets(target, onBackground: other)
            case .background: other.meets(target, onBackground: color.displayP3Color)
            }
        }
        guard !meets(self) else { return self }
        let goesLighter = displayP3Color.relativeLuminance > other.relativeLuminance
        func candidate(_ lightness: Double) -> ProfileAccentColor {
            Self.fitted(lightness: lightness, chroma: chroma, hue: hue)
        }
        // 届く側の端と、届かない今の明るさの間で探す。
        var reaching = goesLighter ? 1.0 : 0.0
        var failing = lightness
        for _ in 0 ..< 24 {
            let middle = (reaching + failing) / 2
            if meets(candidate(middle)) { reaching = middle } else { failing = middle }
        }
        return candidate(reaching)
    }
}

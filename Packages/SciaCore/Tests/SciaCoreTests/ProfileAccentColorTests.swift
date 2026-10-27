import SciaCore
import Testing

struct ProfileAccentColorTests {
    /// `count`個の不透明な画素。
    private static func pixels(_ count: Int, red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        Array(repeating: [red, green, blue, 255], count: count).flatMap(\.self)
    }

    /// 色相を0〜2πにそろえる。色相は`atan2`で作るので、-π〜πで返る。
    private static func hue(_ color: ProfileAccentColor) -> Double {
        color.hue < 0 ? color.hue + 2 * .pi : color.hue
    }

    @Test("1色の画像では、その色相の色を作る")
    func solidColorKeepsHue() throws {
        let orange = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(100, red: 255, green: 140, blue: 0)))
        let blue = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(100, red: 0, green: 115, blue: 255)))
        #expect(!orange.isNeutral)
        #expect(!blue.isNeutral)
        // OKLCHの色相（ラジアン）。オレンジはおよそ0.9、青はおよそ4.5。
        #expect(abs(Self.hue(orange) - 0.9) < 0.3)
        #expect(abs(Self.hue(blue) - 4.5) < 0.3)
    }

    @Test("淡い色の画像では、明るさを残す")
    func paleColorKeepsLightness() throws {
        let pink = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(100, red: 255, green: 190, blue: 205)))
        #expect(pink.lightness > 0.8)
    }

    @Test("色の付いた画素の多い色相を選ぶ")
    func picksDominantHue() throws {
        let image = Self.pixels(70, red: 0, green: 115, blue: 255) + Self.pixels(30, red: 255, green: 140, blue: 0)
        let color = try #require(ProfileAccentColor(premultipliedRGBA: image))
        #expect(abs(Self.hue(color) - 4.5) < 0.3)
    }

    @Test("灰色の画像では、平均の明るさの灰色にする")
    func grayImageIsNeutral() throws {
        let image = Self.pixels(50, red: 255, green: 255, blue: 255) + Self.pixels(50, red: 0, green: 0, blue: 0)
        let color = try #require(ProfileAccentColor(premultipliedRGBA: image))
        #expect(color.isNeutral)
        #expect(abs(color.lightness - 0.5) < 0.01)
    }

    @Test("灰色の明るさは、白や黒にしない")
    func neutralLightnessIsClamped() throws {
        let white = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(100, red: 255, green: 255, blue: 255)))
        let black = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(100, red: 0, green: 0, blue: 0)))
        let options = ProfileAccentColor.Options()
        #expect(white.lightness == options.neutralLightness.upperBound)
        #expect(black.lightness == options.neutralLightness.lowerBound)
    }

    @Test("小さく鮮やかなロゴは、色の付いた画素が少なくても色にする")
    func smallVividLogoIsColored() throws {
        // はっきり鮮やかな画素が5%。色の付いた画素の下限（15%）には届かないが、はっきり鮮やかな画素の下限（3%）を超える。
        let image = Self.pixels(95, red: 255, green: 255, blue: 255) + Self.pixels(5, red: 220, green: 20, blue: 40)
        let color = try #require(ProfileAccentColor(premultipliedRGBA: image))
        #expect(!color.isNeutral)
    }

    @Test("色の量が下限の半分から下限までなら、灰色と色の間の淡い色にする")
    func borderlineIsBlended() throws {
        // 色の付いた画素が10%で、はっきり鮮やかではない。下限（15%）の2/3。
        let muted = Self.pixels(10, red: 170, green: 140, blue: 120)
        let full = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(90, red: 128, green: 128, blue: 128) + muted + muted))
        let borderline = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(90, red: 128, green: 128, blue: 128) + muted))
        let tooFew = try #require(ProfileAccentColor(premultipliedRGBA: Self.pixels(95, red: 128, green: 128, blue: 128) + Self.pixels(5, red: 170, green: 140, blue: 120)))
        #expect(!borderline.isNeutral)
        #expect(borderline.chroma < full.chroma)
        #expect(tooFew.isNeutral)
    }

    @Test("透明な画像からは色を作らない")
    func transparentImageHasNoColor() {
        #expect(ProfileAccentColor(premultipliedRGBA: Array(repeating: 0, count: 400)) == nil)
    }
}

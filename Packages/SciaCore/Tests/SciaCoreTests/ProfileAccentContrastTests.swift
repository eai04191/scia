import SciaCore
import Testing

struct ProfileAccentContrastTests {
    private static func gray(_ hex: Int) -> DisplayP3Color {
        let value = Double(hex) / 255
        return DisplayP3Color(red: value, green: value, blue: value)
    }

    @Test("APCAのLcは、参照実装の灰色の値と同じになる", arguments: [
        (0x88, 0xFF, 63.056469930209424),
        (0xFF, 0x88, -68.54146436644962),
        (0x00, 0xAA, 58.146262578561334),
        (0xAA, 0x00, -56.24113336839742),
    ])
    func apcaMatchesReference(text: Int, background: Int, expected: Double) {
        let lc = Self.gray(text).apcaContrast(onBackground: Self.gray(background))
        #expect(abs(lc - expected) < 0.01)
    }

    @Test("文字と地の明るさがほぼ同じなら、APCAのLcは0になる")
    func apcaIsZeroForSameColors() {
        #expect(Self.gray(0x80).apcaContrast(onBackground: Self.gray(0x80)) == 0)
    }

    @Test("地として明るさを動かすと、WCAGの比とAPCAのLcの両方に届く")
    func ensuringContrastAsBackgroundMeetsBoth() {
        let target = ContrastTarget(ratio: 4.5, lc: 75)
        // 白い文字に対して、WCAGでは4.3:1、APCAでは74ほどの青。
        let blue = ProfileAccentColor(lightness: 0.6, chroma: 0.2, hue: 4.5)
        let adjusted = blue.ensuringContrast(target, against: .white, as: .background)
        #expect(DisplayP3Color.white.meets(target, onBackground: adjusted.displayP3Color))
        #expect(adjusted.lightness < blue.lightness)
    }

    @Test("届いている色は動かさない")
    func ensuringContrastKeepsMetColor() {
        let target = ContrastTarget(ratio: 4.5, lc: 75)
        let dark = ProfileAccentColor(lightness: 0.3, chroma: 0.1, hue: 1)
        #expect(dark.ensuringContrast(target, against: .white, as: .background) == dark)
    }

    @Test("文字として明るさを動かすと、地の上で両方に届く")
    func ensuringContrastAsTextMeetsBoth() {
        let target = ContrastTarget(ratio: 4.5, lc: 60)
        let orange = ProfileAccentColor(lightness: 0.75, chroma: 0.17, hue: 1)
        let adjusted = orange.ensuringContrast(target, against: .white, as: .text)
        #expect(adjusted.displayP3Color.meets(target, onBackground: .white))
    }

    @Test("控えめな文字の透明度は、両方に届く一番薄いところになる")
    func minimumAlphaMeetsBoth() {
        let target = ContrastTarget(ratio: 3, lc: 60)
        let background = Self.gray(0x30)
        let alpha = DisplayP3Color.white.minimumAlpha(over: background, target: target)
        #expect(DisplayP3Color.white.composited(over: background, alpha: alpha).meets(target, onBackground: background))
        #expect(!DisplayP3Color.white.composited(over: background, alpha: alpha - 0.02).meets(target, onBackground: background))
    }
}

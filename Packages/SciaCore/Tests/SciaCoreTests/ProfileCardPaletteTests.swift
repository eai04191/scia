import SciaCore
import Testing

struct ProfileCardPaletteTests {
    private static let orange = ProfileAccentColor.fitted(lightness: 0.75, chroma: 0.18, hue: 0.9)
    private static let blue = ProfileAccentColor.fitted(lightness: 0.58, chroma: 0.2, hue: 4.5)
    private static let yellow = ProfileAccentColor.fitted(lightness: 0.88, chroma: 0.17, hue: 1.7)
    private static let navy = ProfileAccentColor.fitted(lightness: 0.3, chroma: 0.12, hue: 4.6)
    private static let gray = ProfileAccentColor(lightness: 0.6, chroma: 0, hue: 0)
    private static let colors = [orange, blue, yellow, navy, gray]

    private static func text(_ palette: ProfileCardPalette) -> DisplayP3Color {
        palette.usesLightText ? .white : .black
    }

    /// 届いたかを確かめる目標。地の明るさを目標ちょうどまで動かすと、成分を丸めた分だけ目標をわずかに下回るため、その分だけ緩める。
    private static func loosened(_ target: ContrastTarget) -> ContrastTarget {
        ContrastTarget(ratio: target.ratio - 0.001, lc: target.lc - 0.1)
    }

    @Test("白と黒のうち、APCAで読みやすいほうを文字にする")
    func choosesTextByAPCA() {
        // 青の地は、WCAG 2.1の比では黒のほうが高いが、APCAでは白のほうが読みやすい。
        #expect(ProfileCardPalette(color: Self.blue, isDark: false).usesLightText)
        #expect(!ProfileCardPalette(color: Self.orange, isDark: false).usesLightText)
        #expect(!ProfileCardPalette(color: Self.yellow, isDark: false).usesLightText)
        #expect(ProfileCardPalette(color: Self.navy, isDark: false).usesLightText)
    }

    @Test("本文と地は、WCAGの比とAPCAのLcの両方に届く", arguments: [false, true])
    func bodyMeetsTarget(isDark: Bool) {
        let options = ProfileCardPalette.Options()
        for color in Self.colors {
            let palette = ProfileCardPalette(color: color, isDark: isDark)
            #expect(Self.text(palette).meets(Self.loosened(options.body), onBackground: palette.background.displayP3Color))
        }
    }

    @Test("控えめな文字は、地と同じ色相の色でも、本文の色を薄めた色でも、目標に届く", arguments: [true, false])
    func secondaryMeetsTarget(tints: Bool) {
        var options = ProfileCardPalette.Options()
        options.tintsSecondaryText = tints
        for color in Self.colors {
            let palette = ProfileCardPalette(color: color, options: options, isDark: false)
            let background = palette.background.displayP3Color
            let secondary = switch palette.secondaryText {
            case .toned(let toned): toned.displayP3Color
            case .translucent(let alpha): Self.text(palette).composited(over: background, alpha: alpha)
            }
            #expect(secondary.meets(Self.loosened(options.secondary), onBackground: background))
        }
    }

    @Test("区切り線はLc 15に届く一番薄い色にする")
    func separatorMeetsTarget() {
        let options = ProfileCardPalette.Options()
        for color in Self.colors {
            let palette = ProfileCardPalette(color: color, isDark: true)
            let background = palette.background.displayP3Color
            let line = Self.text(palette).composited(over: background, alpha: palette.separatorAlpha)
            #expect(line.meets(Self.loosened(options.separator), onBackground: background))
            #expect(!Self.text(palette).composited(over: background, alpha: palette.separatorAlpha - 0.03).meets(options.separator, onBackground: background))
        }
    }

    @Test("ティントカラーは、画面の地の上で本文の目標に届く", arguments: [false, true])
    func screenTintMeetsTarget(isDark: Bool) {
        let options = ProfileCardPalette.Options()
        let screen: DisplayP3Color = isDark ? .black : .white
        for color in [Self.orange, Self.blue, Self.yellow, Self.navy] {
            let palette = ProfileCardPalette(color: color, isDark: isDark)
            #expect(palette.screenTint.displayP3Color.meets(Self.loosened(options.body), onBackground: screen))
            #expect(!palette.underlinesScreenLinks)
        }
    }

    @Test("灰色のときは、ティントカラーを本文と同じ黒か白にし、カードの外のリンクに下線を引く", arguments: [false, true])
    func neutralUsesTextColorForTint(isDark: Bool) {
        let palette = ProfileCardPalette(color: Self.gray, isDark: isDark)
        #expect(palette.screenTint.lightness == (isDark ? 1 : 0))
        #expect(palette.underlinesScreenLinks)
    }

    @Test("ティントカラーを白い本文の近くまで動かしたときも、カードの外のリンクに下線を引く")
    func washedOutTintUnderlinesLinks() {
        let red = ProfileAccentColor.fitted(lightness: 0.55, chroma: 0.2, hue: 0.5)
        let normal = ProfileCardPalette(color: red, isDark: true)
        let raised = ProfileCardPalette(color: red, options: ProfileCardPalette.Options().raisingContrast(), isDark: true)
        #expect(!normal.underlinesScreenLinks)
        #expect(raised.underlinesScreenLinks)
        // 鮮やかな緑は、明るくしても色が残るので、下線を引かない。
        let green = ProfileAccentColor.fitted(lightness: 0.65, chroma: 0.2, hue: 2.5)
        #expect(!ProfileCardPalette(color: green, options: ProfileCardPalette.Options().raisingContrast(), isDark: true).underlinesScreenLinks)
    }

    @Test("ダークモードでは、灰色のカードを明るさの上限まで暗くする")
    func darkModeDimsNeutral() {
        let white = ProfileAccentColor(lightness: 0.86, chroma: 0, hue: 0)
        let palette = ProfileCardPalette(color: white, isDark: true)
        #expect(palette.background.lightness <= ProfileCardPalette.Options().darkNeutralMaxLightness)
        #expect(palette.usesLightText)
    }

    @Test("「コントラストを上げる」では、どのLcの目標もLc 15ずつ上げ、上げた目標に届く")
    func raisedContrastMeetsHigherTargets() {
        let raised = ProfileCardPalette.Options().raisingContrast()
        #expect(raised.body.lc == 90)
        #expect(raised.secondary.lc == 75)
        #expect(raised.separator.lc == 30)
        #expect(raised.body.ratio == 4.5)
        for color in Self.colors {
            let palette = ProfileCardPalette(color: color, options: raised, isDark: false)
            #expect(Self.text(palette).meets(Self.loosened(raised.body), onBackground: palette.background.displayP3Color))
        }
    }
}

import Testing
@testable import SciaCore

struct ReactionGlowGradientTests {
    /// ダークモードのsystemGreenとsystemYellow。
    private let green = SRGBColor(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    private let yellow = SRGBColor(red: 255 / 255, green: 214 / 255, blue: 10 / 255)

    private func isClose(_ a: SRGBColor, _ b: SRGBColor, tolerance: Double = 0.002) -> Bool {
        abs(a.red - b.red) < tolerance && abs(a.green - b.green) < tolerance && abs(a.blue - b.blue) < tolerance
    }

    /// 光の強さで半分ずつ混ぜると、sRGBの値のまま混ぜたときより明るい。
    @Test func linearMidpointIsBrighterThanEncodedMidpoint() {
        let mixed = green.mixed(with: yellow, fraction: 0.5, in: .linear)

        #expect(isClose(mixed, SRGBColor(red: 190 / 255, green: 212 / 255, blue: 63 / 255), tolerance: 0.004))
        #expect(mixed.red > (green.red + yellow.red) / 2)
    }

    @Test(arguments: [ColorMixSpace.linear, .oklab])
    func endpointsKeepTheOriginalColors(space: ColorMixSpace) {
        #expect(isClose(green.mixed(with: yellow, fraction: 0, in: space), green))
        #expect(isClose(green.mixed(with: yellow, fraction: 1, in: space), yellow))
    }

    /// OKLabへの変換と戻しで、色が変わらない。広い色域の負の成分も保つ。
    /// 係数は10桁で丸めてあるため、暗い成分ではガンマの符号化で1e-6ほどずれる。1段階（1/255）より十分小さい。
    @Test func oklabRoundTripKeepsTheColor() {
        for color in [green, yellow, SRGBColor(red: -0.05, green: 0.8, blue: 1.02)] {
            #expect(isClose(SRGBColor(oklab: color.oklab), color, tolerance: 1e-5))
        }
    }

    /// 両方光っていれば、真ん中でも濃さが落ちない。
    @Test(arguments: [ColorMixSpace.linear, .oklab])
    func bothLitKeepsFullAlphaAcrossTheBlend(space: ColorMixSpace) {
        let gradient = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 1, favouriteLevel: 1, blendFraction: 0.2, space: space).stops()

        #expect(gradient.allSatisfy { abs($0.alpha - 1) < 1e-9 })
        #expect(isClose(gradient[0].color, green))
        #expect(isClose(gradient[gradient.count - 1].color, yellow))
    }

    /// 片方だけなら、その半分だけを同じ色で光らせ、混ぜる幅の中で消す。
    @Test func onlyBoostFadesOutTowardTheRight() {
        let gradient = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 1, favouriteLevel: 0, blendFraction: 0.2, space: .linear).stops()

        #expect(gradient.allSatisfy { isClose($0.color, green) })
        #expect(gradient[0].alpha == 1)
        #expect(gradient[gradient.count - 1].alpha == 0)
        let alphas = gradient.map(\.alpha)
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 >= $1 })
    }

    /// 混ぜる幅は真ん中に置き、その外は左右の端まで同じ状態にする。
    @Test func blendIsCenteredInTheMiddle() {
        let gradient = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 1, favouriteLevel: 1, blendFraction: 0.2, space: .linear).stops(steps: 4)

        let locations = gradient.map(\.location)
        let expected = [0, 0.4, 0.45, 0.5, 0.55, 0.6, 1]
        #expect(locations.count == expected.count)
        #expect(zip(locations, expected).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func zeroBlendSwitchesAtTheMiddle() {
        let gradient = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 1, favouriteLevel: 1, blendFraction: 0, space: .oklab).stops(steps: 4)

        #expect(gradient.dropFirst().dropLast().allSatisfy { $0.location == 0.5 })
    }

    /// 全幅に広げるときは、片方だけでも全幅をその色で、同じ濃さで光らせる。
    @Test func aloneFillsTheWholeWidth() {
        let gradient = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 0, favouriteLevel: 1, blendFraction: 0.2, space: .linear, fillsWidthWhenAlone: true)

        for location in stride(from: 0.0, through: 1, by: 0.05) {
            let sample = gradient.sample(at: location)
            #expect(abs(sample.alpha - 1) < 1e-9)
            #expect(isClose(sample.color, yellow))
        }
    }

    /// 全幅に広げていても、両方光っていれば左半分と右半分に分ける。
    @Test func fillingWidthStillSplitsWhenBothAreLit() {
        let filling = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 1, favouriteLevel: 1, blendFraction: 0.2, space: .linear, fillsWidthWhenAlone: true)
        let halves = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 1, favouriteLevel: 1, blendFraction: 0.2, space: .linear)

        #expect(filling.stops() == halves.stops())
    }

    /// 片方を点けていく途中も、濃さは1を超えず、両方の明るさから決まる。
    @Test func partialLevelsNeverExceedFullAlpha() {
        let gradient = ReactionGlowGradient(boost: green, favourite: yellow, boostLevel: 1, favouriteLevel: 0.4, blendFraction: 0.2, space: .oklab, fillsWidthWhenAlone: true)

        for location in stride(from: 0.0, through: 1, by: 0.05) {
            #expect(abs(gradient.sample(at: location).alpha - 1) < 1e-9)
        }
        #expect(gradient.sample(at: 0).favouriteShare < 1e-9)
        #expect(abs(gradient.sample(at: 1).favouriteShare - 0.4) < 1e-9)
    }

    private let white = SRGBColor(red: 1, green: 1, blue: 1)

    /// 光を足さなければ、もとの色のまま、倍率は1。
    @Test func noLightKeepsTheBase() {
        let lit = white.lightAdded(yellow, intensity: 0)

        #expect(isClose(lit.color, white))
        #expect(lit.exposure == 1)
    }

    /// 白い面を白い光で照らすと、白のまま2倍の明るさになる。
    @Test func whiteLightDoublesWhite() {
        let lit = white.lightAdded(white, intensity: 1)

        #expect(isClose(lit.color, white))
        #expect(abs(lit.exposure - 2) < 1e-9)
    }

    /// 白い面を色の光で照らすと、どの成分も白より暗くならず、光の色に寄る。倍率を掛け戻すと、面に光を足した値になる。
    @Test func coloredLightBrightensWhiteTowardItsColor() {
        let lit = white.lightAdded(yellow, intensity: 0.5)
        let restored = lit.color.linear * lit.exposure

        #expect(lit.exposure > 1)
        #expect(restored.min() >= 1 - 1e-9)
        #expect(restored.x > restored.z)
        let expected = white.linear + yellow.linear * 0.5
        #expect(abs(restored.x - expected.x) < 1e-6 && abs(restored.y - expected.y) < 1e-6 && abs(restored.z - expected.z) < 1e-6)
    }
}

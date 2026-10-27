import Foundation

/// プロフィールの補足情報のカードと固定された投稿のカードに敷く色と、その上の文字、画面のティントカラー。
/// アイコンから作った色（`ProfileAccentColor`）を地に敷き、白か黒の文字を載せる。App Storeのカードに近い組み方。
/// 文字と地のコントラストは、WCAG 2.1の比とAPCAのLcの両方の目標に届くまで、地の明るさを動かして保つ。
public struct ProfileCardPalette: Equatable, Sendable {
    /// 確保するコントラストと、ダークモードでの暗くし方。
    public struct Options: Equatable, Sendable {
        /// 本文とリンクに確保するコントラスト。補足情報の値（15pt、太さ400）は、APCAの目安では本文でない15px/400の文字で、Lc 75が最低限。
        public var body = ContrastTarget(ratio: 4.5, lc: 75)
        /// 控えめな文字に確保するコントラスト。
        /// 補足情報の名前や日付（13pt、太さ400）は、APCAの目安ではLc 90が、WCAG 2.1のAAでは4.5:1が要る大きさだが、承知のうえでLc 60と3:1にしている。
        /// 目安どおりにすると本文（Lc 75と4.5:1）と同じかそれより強くなり、名前や日付のような添える情報を薄くして強弱を付けられなくなるため。
        /// 4.5:1では、白い文字で4.5:1ちょうどまでしか暗くしない青緑や緑のカードで、控えめな文字が本文と同じ白になった。
        public var secondary = ContrastTarget(ratio: 3, lc: 60)
        /// 区切り線に確保するコントラスト。APCAの、文字でない見分けられるべきものの最低限（Lc 15）。
        /// 目安は一番細いところが5px以上のものの値で、1ピクセルの線はそれより細いが、線を太くはしない。
        public var separator = ContrastTarget(ratio: 1, lc: 15)
        /// 控えめな文字を、地と同じ色相の色にする。falseなら、本文と同じ白か黒を薄めた色にする。
        public var tintsSecondaryText = true
        /// ダークモードで、地に敷く色の明るさに掛ける倍率。
        public var darkLightness = 0.85
        /// ダークモードで、灰色の明るさの上限。灰色は、明るさの順を保ったまま0.25からこの値までに縮める。
        public var darkNeutralMaxLightness = 0.45

        public init() {}

        /// 端末の「コントラストを上げる」がオンのときの値。APCAの目安に倣い、どのLcの目標もLc 15ずつ上げる。
        public func raisingContrast() -> Options {
            var options = self
            for keyPath in [\Options.body, \.secondary, \.separator] {
                options[keyPath: keyPath].lc += 15
            }
            return options
        }
    }

    /// 控えめな文字の色。
    public enum SecondaryText: Equatable, Sendable {
        /// 地と同じ色相の色。
        case toned(ProfileAccentColor)
        /// 本文と同じ白か黒を、この透明度で地に重ねた色。
        case translucent(alpha: Double)
    }

    /// カードの地の色。塗りつぶしたボタンも、この色で塗って画面の中で色を揃える。
    public let background: ProfileAccentColor
    /// 白い文字で描く。falseなら黒い文字で描く。本文、リンク、確認済みのチェックマーク、塗りつぶしたボタンの文字もこの色にする。
    public let usesLightText: Bool
    public let secondaryText: SecondaryText
    /// 区切り線の、本文と同じ白か黒の透明度。システムの区切り線の色は半透明の灰色で、色の地に重ねても地が少し暗くなるだけで、暗い地ではほとんど見えないため。
    public let separatorAlpha: Double
    /// 画面のティントカラー。カードの外のリンクや「さらに表示」に使う。
    public let screenTint: ProfileAccentColor
    /// カードの外のリンクと「さらに表示」に下線を引く。灰色のときは、ティントカラーが本文と同じ黒か白で、色では見分けられないため。
    /// 色があっても、画面の地の上で目標に届かせるために本文の色の近くまで動かしたときも引く。
    /// 「コントラストを上げる」のダークモードで、赤や青が明るさ0.92ほどの淡い色になり、白い本文と見分けにくくなるときなど。
    public let underlinesScreenLinks: Bool

    /// ティントカラーを本文と色で見分けられるとみなす、OKLabでの本文の色との差。
    /// 赤や青は、ふつうは0.18ほど、「コントラストを上げる」のダークモードでは0.09ほどの差になり、後者は白い本文と見分けにくかった。
    static let distinguishableDifference = 0.15

    public init(color: ProfileAccentColor, options: Options = Options(), isDark: Bool) {
        let screen: DisplayP3Color = isDark ? .black : .white
        // カードの地とティントカラーで同じ色を元にし、揃えて見せる。
        let base = isDark ? Self.darkened(color, options: options) : color
        // 灰色のときは、ティントカラーを画面の文字と同じ黒（ダークモードでは白）にする。灰色のリンクは、本文と見分けにくく、色にも見えないため。
        screenTint = color.isNeutral
            ? ProfileAccentColor(lightness: isDark ? 1 : 0, chroma: 0, hue: 0)
            : base.ensuringContrast(options.body, against: screen, as: .text)
        // 本文の色は、明るさが1か0の白か黒。OKLabでは、明るさの差と鮮やかさから差が出る。
        let textLightness: Double = isDark ? 1 : 0
        underlinesScreenLinks = hypot(screenTint.lightness - textLightness, screenTint.chroma) < Self.distinguishableDifference
        let lightText = Self.prefersLightText(on: base.displayP3Color)
        let text: DisplayP3Color = lightText ? .white : .black
        background = base.ensuringContrast(options.body, against: text, as: .background)
        usesLightText = lightText
        let backgroundP3 = background.displayP3Color
        separatorAlpha = text.minimumAlpha(over: backgroundP3, target: options.separator)
        if options.tintsSecondaryText {
            // 同じ色相の、文字の側に寄せた色にする。App Storeのカードの、オレンジの地の黄色い文字のように。
            let toned = background.with(lightness: lightText ? 0.92 : 0.3, chroma: min(background.chroma, 0.11))
            secondaryText = .toned(toned.ensuringContrast(options.secondary, against: backgroundP3, as: .text))
        } else {
            secondaryText = .translucent(alpha: text.minimumAlpha(over: backgroundP3, target: options.secondary))
        }
    }

    /// ダークモードで地に敷く色。色の面がまぶしくならないよう、明るさに倍率を掛ける。黒い画面に溶けないよう、0.25より暗くはしない。
    /// 灰色は倍率では足りない。白い地のアイコンの人のカードが、黒い画面の中で明るい面として浮くため、上限まで縮める。
    /// 色と灰色の間の淡い色は、鮮やかさに応じて両方の明るさを混ぜ、灰色に寄せたアイコンとの間で明るさが飛ばないようにする。
    static func darkened(_ color: ProfileAccentColor, options: Options) -> ProfileAccentColor {
        let floor = 0.25
        let colored = max(color.lightness * options.darkLightness, min(color.lightness, floor))
        let neutral = floor + (max(options.darkNeutralMaxLightness, floor) - floor) * color.lightness
        let weight = min(color.chroma / 0.05, 1)
        return color.with(lightness: neutral + (colored - neutral) * weight, chroma: color.chroma)
    }

    /// `background`の上の文字に、白のほうが黒より読みやすいか。APCAのLcの絶対値で比べる。
    /// WCAG 2.1の比で選ぶと、青や青緑、中くらいの灰色のように、白い文字のほうが読みやすい地でも黒を選ぶため。
    static func prefersLightText(on background: DisplayP3Color) -> Bool {
        abs(DisplayP3Color.white.apcaContrast(onBackground: background)) >= abs(DisplayP3Color.black.apcaContrast(onBackground: background))
    }
}

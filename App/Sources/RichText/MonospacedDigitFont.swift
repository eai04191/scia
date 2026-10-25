import UIKit

extension UIFont {
    /// `style`の書式の文字で、数字の幅を揃えたもの。残りの文字数のように、数えながら変わる数字に使う。
    /// 書式の文字に数字の幅の指定を足すだけなので、大きさは書式と同じで、`adjustsFontForContentSizeCategory`を付けたラベルなら、表示中に文字の大きさを変えても追従する。
    /// `preferredFont(forTextStyle:).pointSize`で`monospacedDigitSystemFont`を作ると、作った時点の大きさで止まり、追従しないため、これで作る。
    /// - Parameter traits: この文字の大きさで作る。nilなら今の端末の文字の大きさで作る。
    static func monospacedDigitFont(forTextStyle style: UIFont.TextStyle, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

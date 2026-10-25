import UIKit

extension UIColor {
    /// 画像や黒い背景の上に置く、本文の白より控えめな白い文字の色。プレースホルダーや補足に使う。
    /// 白を透かして控えめにすると、明るい画像の上で読みにくくなるため、コントラストを上げる設定では、透ける分を半分にして濃くする。
    /// 半透明の白い文字は、`withAlphaComponent`で直接作らず、これで作る。
    static func dimmedWhiteText(alpha: CGFloat) -> UIColor {
        UIColor { traits in
            let resolved = traits.accessibilityContrast == .high ? 1 - (1 - alpha) / 2 : alpha
            return UIColor.white.withAlphaComponent(resolved)
        }
    }
}

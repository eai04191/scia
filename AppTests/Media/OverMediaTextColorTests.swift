import Testing
import UIKit
@testable import Scia

@MainActor
struct OverMediaTextColorTests {
    private func alpha(of color: UIColor, contrast: UIAccessibilityContrast) -> CGFloat {
        var alpha: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(accessibilityContrast: contrast)).getWhite(nil, alpha: &alpha)
        return alpha
    }

    /// 画像の上の控えめな白い文字は、コントラストを上げる設定では、透ける分を半分にして濃くする。
    @Test func dimmedWhiteTextGetsDarkerWithIncreasedContrast() {
        let color = UIColor.dimmedWhiteText(alpha: 0.6)

        #expect(abs(alpha(of: color, contrast: .normal) - 0.6) < 0.001)
        #expect(abs(alpha(of: color, contrast: .high) - 0.8) < 0.001)
    }
}

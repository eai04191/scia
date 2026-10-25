import Testing
import UIKit
@testable import Scia

@MainActor
struct MonospacedDigitFontTests {
    /// 数字の幅を揃えた文字も、端末の文字の大きさに合わせて、同じ書式の文字と同じ大きさになる。
    @Test(arguments: [UIContentSizeCategory.small, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge])
    func followsTheContentSizeLikeTheTextStyle(category: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: category)

        let font = UIFont.monospacedDigitFont(forTextStyle: .footnote, compatibleWith: traits)

        #expect(abs(font.pointSize - UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).pointSize) < 0.5)
    }

    /// 表示中に文字の大きさが変わっても、ラベルが文字を作り直して追従する。
    @Test func labelFollowsAContentSizeChange() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // 端末がいちばん大きい文字になっていても大きくなることを確かめられるよう、ふつうの大きさから始める。
        window.traitOverrides.preferredContentSizeCategory = .large
        let label = UILabel()
        label.font = .monospacedDigitFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        window.addSubview(label)
        window.isHidden = false
        window.layoutIfNeeded()
        let before = label.font.pointSize

        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.layoutIfNeeded()

        #expect(label.font.pointSize > before)
        window.isHidden = true
    }
}

extension MonospacedDigitFontTests {
    /// 数字の幅が揃い、「1」と「8」が同じ幅になる。
    @Test func digitsHaveTheSameWidth() {
        let font = UIFont.monospacedDigitFont(forTextStyle: .footnote)
        let one = ("1" as NSString).size(withAttributes: [.font: font]).width
        let eight = ("8" as NSString).size(withAttributes: [.font: font]).width

        #expect(abs(one - eight) < 0.01)
    }
}

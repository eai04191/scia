import Testing
import UIKit
@testable import Scia

/// ティントカラーの地と、その上に載せる中身の色。決まりはAGENTS.mdの設計原則にある。
@MainActor
@Suite(.failureState)
struct TintFillTests {
    /// `style`と`contrast`の外観のウインドウに載せたビューで決めた色と、その外観。外観の上書きは、ウインドウに載せたビューにだけ効く。
    private func colors(tint: UIColor, style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast, on surface: TintFill.Surface) throws -> (fill: UIColor, foreground: UIColor, traits: UITraitCollection) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.traitOverrides.userInterfaceStyle = style
        window.traitOverrides.accessibilityContrast = contrast
        let view = UIView()
        view.tintColor = tint
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        let traits = view.traitCollection
        #expect(traits.userInterfaceStyle == style)
        #expect(traits.accessibilityContrast == contrast)
        let colors = TintFill.colors(for: view, on: surface)
        return (colors.fill.resolvedColor(with: traits), colors.foreground.resolvedColor(with: traits), traits)
    }

    /// モノトーンでは、ライトでもダークでも、「コントラストを上げる」でも、地と中身が同じ色にならない。
    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func monochromeForegroundDiffersFromFill(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) throws {
        let glass = try colors(tint: .label, style: style, contrast: contrast, on: .glass)
        #expect(glass.fill != glass.foreground)

        // ふつうの画面の上では、本文の色の地に、背景の色の中身を載せる。
        let plain = try colors(tint: .label, style: style, contrast: contrast, on: .plain)
        #expect(plain.fill == UIColor.label.resolvedColor(with: plain.traits))
        #expect(plain.foreground == UIColor.systemBackground.resolvedColor(with: plain.traits))
        #expect(plain.fill != plain.foreground)
    }

    /// 色のあるティントカラーでは、地に白い中身を載せる。
    @Test(arguments: [TintFill.Surface.plain, .glass])
    func coloredTintUsesWhiteForeground(surface: TintFill.Surface) throws {
        let colors = try colors(tint: .systemBlue, style: .dark, contrast: .normal, on: surface)

        #expect(colors.foreground == UIColor.white.resolvedColor(with: UITraitCollection()))
        #expect(colors.fill != colors.foreground)
    }
}

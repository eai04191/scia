import UIKit

/// ティントカラーで塗った地と、その上に載せる中身（文字や記号）の色。ティントカラーの地に中身を載せるものは、色を自分で決めずにここから取る。
/// 中身を白に決め打ちすると、モノトーンのダークで白い地に白い中身になり、地を`.tintColor`のまま置くと、ガラスの中でほかのボタンより明るく描かれるため。
/// 地に`.tintColor`を直接指定する書き方は、`make lint`の`raw_tint_background`で止める。
@MainActor
enum TintFill {
    /// 地を置く場所。
    enum Surface {
        /// ふつうの画面の上。ティントカラーで塗りつぶしたボタンと同じ決まり（`UIColor.filledForeground(on:traits:)`）で、モノトーンでは本文の色の地に背景の色を載せる。
        case plain
        /// ガラスの中（投稿欄など）。ガラスの中の塗りつぶしのボタンと同じ決まり（`TintFollowingButton.appliesGlassAccent(monochromeFill:)`）で、モノトーンでは淡い地に本文の色を載せる。
        case glass
    }

    /// `view`のティントカラーと見た目の設定から決めた色。ティントカラーや外観が変わったら取り直す。
    static func colors(for view: UIView, on surface: Surface) -> (fill: UIColor, foreground: UIColor) {
        let tint: UIColor = view.tintColor
        let monochrome = UIColor.isMonochromeTint(tint, traits: view.traitCollection)
        switch surface {
        case .plain:
            return (.whiteForegroundFill(tint), .filledForeground(on: tint, traits: view.traitCollection))
        case .glass:
            return (monochrome ? .tertiarySystemFill : .whiteForegroundFill(tint), monochrome ? .label : .white)
        }
    }
}

/// ティントカラーの地に文字を載せたバッジ。投稿欄で、既定と違う言語のコードを出す。
final class TintBadgeLabel: UILabel {
    private let surface: TintFill.Surface

    init(surface: TintFill.Surface) {
        self.surface = surface
        super.init(frame: .zero)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (label: TintBadgeLabel, _) in label.applyColors() }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    private func applyColors() {
        let colors = TintFill.colors(for: self, on: surface)
        backgroundColor = colors.fill
        textColor = colors.foreground
    }
}

/// ティントカラーの丸い地に記号を載せたバッジ。投稿欄で、既定と違う引用できる人を選んでいることを示す。
final class TintSymbolBadge: UIView {
    static let side: CGFloat = 16
    private let imageView: UIImageView
    private let surface: TintFill.Surface

    init(symbolName: String, surface: TintFill.Surface) {
        self.surface = surface
        imageView = UIImageView(image: UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)))
        super.init(frame: .zero)
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        layer.cornerRadius = Self.side / 2
        clipsToBounds = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (badge: TintSymbolBadge, _) in badge.applyColors() }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    private func applyColors() {
        let colors = TintFill.colors(for: self, on: surface)
        backgroundColor = colors.fill
        // 記号の色は、記号のビューにだけ付ける。バッジのティントカラーを変えると、地の色まで変わるため。
        imageView.tintColor = colors.foreground
    }
}

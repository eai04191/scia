import SciaCore
import SwiftUI
import UIKit

extension AccentColorChoice {
    var uiColor: UIColor {
        switch self {
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .brown: .systemBrown
        case .gray: .systemGray
        case .monochrome: .label
        }
    }

    /// タブのアイコンを、アクセントカラーではなく本文の色の濃淡で描くか。タブバーは選んでいないタブを本文の色で描くので、
    /// モノトーンでは選んでいるタブと同じ色に、グレーでは選んでいるタブより濃くなる。そこでこの2つは、選んでいるタブを本文の色、選んでいないタブを一段薄い色で描く。
    var drawsTabsInTextColors: Bool {
        self == .gray || self == .monochrome
    }

    /// ティントカラーが本文の色と同じで、色だけではオンとオフを見分けられないか。
    var tintMatchesTextColor: Bool {
        self == .monochrome
    }

    /// 選んでいるタブが、ほかのタブと見分けにくくなるか。選んでいるときの画像を渡せるのはiOS 26.1からなので、
    /// 26.0では`drawsTabsInTextColors`の色で、選んでいるタブがほかのタブと同じ色かより薄い色になる。
    var obscuresSelectedTab: Bool {
        if #available(iOS 26.1, *) { return false }
        return drawsTabsInTextColors
    }

    var title: String {
        switch self {
        case .blue: "ブルー"
        case .indigo: "インディゴ"
        case .purple: "パープル"
        case .pink: "ピンク"
        case .red: "レッド"
        case .orange: "オレンジ"
        case .yellow: "イエロー"
        case .green: "グリーン"
        case .mint: "ミント"
        case .teal: "ティール"
        case .cyan: "シアン"
        case .brown: "ブラウン"
        case .gray: "グレー"
        case .monochrome: "モノトーン"
        }
    }
}

extension UIColor {
    /// モノトーンのティントカラー（本文の文字の色）か。ウィンドウの設定ではなく、ボタンに付いているティントカラーで決める。プロフィール画面は、ティントカラーをその人の色で上書きするため。
    static func isMonochromeTint(_ tint: UIColor, traits: UITraitCollection) -> Bool {
        tint.resolvedColor(with: traits) == UIColor.label.resolvedColor(with: traits)
    }

    /// ティントカラーで塗りつぶしたボタン（`filled`）の文字の色。ふだんは白。モノトーンでは地が本文の文字の色になり、ダークでは白い地に白い文字になるので、地の反対の`systemBackground`にする。
    static func filledForeground(on tint: UIColor, traits: UITraitCollection) -> UIColor {
        isMonochromeTint(tint, traits: traits) ? .systemBackground : .white
    }

    /// 白い文字を載せる地に塗るティントカラー。「コントラストを上げる」では、設定アプリのアイコンの四角と同じく地を濃くして、白い文字との差を広げる。ダークモードの高コントラスト版のシステムカラーは暗い背景との差を広げるために明るくなり、白い文字が見えにくくなるので、ライトモードの高コントラスト版の濃い色を使う。
    static func whiteForegroundFill(_ tint: UIColor) -> UIColor {
        UIColor { traits in
            guard traits.accessibilityContrast == .high else { return tint.resolvedColor(with: traits) }
            return tint.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceStyle = .light })
        }
    }
}

/// ティントカラーが変わったら、設定（`configurationUpdateHandler`）を決め直すボタン。UIButtonはティントカラーが変わっても決め直さないので、
/// ティントカラーから色を決めるボタンは、ウィンドウに載る前の既定のティントカラーや、プロフィール画面がその人の色に替える前のティントカラーで決めた色が残る。
class TintFollowingButton: UIButton {
    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsUpdateConfiguration()
    }

    /// ティントカラーで塗りつぶすボタンの文字の色を、ティントカラーに合わせて決め直し続ける。`filledForeground(on:traits:)`の決まりで塗る。
    func followsFilledForeground() {
        configurationUpdateHandler = { button in
            let monochrome = UIColor.isMonochromeTint(button.tintColor, traits: button.traitCollection)
            button.configuration?.baseBackgroundColor = monochrome ? nil : .whiteForegroundFill(button.tintColor)
            button.configuration?.baseForegroundColor = .filledForeground(on: button.tintColor, traits: button.traitCollection)
        }
    }

    /// ティントカラーのガラスのボタン（`prominentGlass`）と、ガラスの中に置いた塗りつぶしのボタンを、モノトーンのときは`monochromeFill`の地と本文の色の文字にする。
    /// ガラスの上やガラスの中の文字は、文字の色を黒にしても明るく描かれ、ダークの白い地の上で読めないため。ライトとダークで形を揃えるよう、ライトでも同じにする。
    /// - Parameter monochromeFill: `prominentGlass`なら`.clear`で色を付けないガラスに、塗りつぶしなら淡い地にする。
    func appliesGlassAccent(monochromeFill: UIColor = .clear) {
        let monochrome = UIColor.isMonochromeTint(tintColor, traits: traitCollection)
        configuration?.baseBackgroundColor = monochrome ? monochromeFill : .whiteForegroundFill(tintColor)
        configuration?.baseForegroundColor = monochrome ? .label : .white
    }

    /// `appliesGlassAccent(monochromeFill:)`を、ティントカラーに合わせて当て直し続ける。
    func followsGlassAccent(monochromeFill: UIColor = .clear) {
        configurationUpdateHandler = { button in
            (button as? TintFollowingButton)?.appliesGlassAccent(monochromeFill: monochromeFill)
        }
    }
}

@MainActor
enum AccentColorTint {
    /// 選んだアクセントカラーを`window`のティントカラーにする。選び直すと塗り直すので、開いている画面にもすぐ効く。
    /// `window`は弱く持ち、なくなったら塗り直すのをやめる。
    static func follow(_ window: UIWindow, settings: AppSettings) {
        withObservationTracking {
            window.tintColor = settings.accentColor.uiColor
        } onChange: { [weak window] in
            Task(.withoutRequests) { @MainActor in
                guard let window else { return }
                follow(window, settings: settings)
            }
        }
    }
}

/// 表示の分類から入る、アクセントカラーを選ぶ行。
struct AccentColorPicker: View {
    @Binding var selection: AccentColorChoice

    var body: some View {
        Picker("アクセントカラー", selection: $selection) {
            ForEach(AccentColorChoice.allCases, id: \.self) { choice in
                Label {
                    Text(choice.title)
                } icon: {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Color(uiColor: choice.uiColor))
                }
                .tag(choice)
            }
        }
        .pickerStyle(.navigationLink)
    }
}

extension View {
    /// SwiftUIの`glassProminent`のボタンに、`TintFollowingButton.followsGlassAccent(monochromeFill:)`と同じ決まりを当てる。モノトーンでは色を付けないガラスにする。
    @ViewBuilder
    func accentProminentGlassButtonStyle(_ accent: AccentColorChoice) -> some View {
        if accent == .monochrome {
            buttonStyle(.glass)
        } else {
            buttonStyle(.glassProminent)
        }
    }
}

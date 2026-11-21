import SciaCore
import UIKit

/// アプリ内のSafariのバーの上に重ねる、シートを引ける範囲の決まり。
struct InAppBrowserBarGrab {
    /// Safariのバーの上端から下へ伸ばす高さ。0なら重ねない。
    var height: CGFloat
    /// 左右の空き。Safariの×とメニューのボタンを押せるように空ける。
    var inset: CGFloat
    /// 範囲がどこにあるかを確かめるために、見える色で塗る。
    var isVisible: Bool
    /// シートの上端の、引く帯の高さ。
    var handleHeight: CGFloat
    /// シートの上端からSafariのバーの上端までの空き。
    var safariTopInset: CGFloat

    var isEnabled: Bool { height > 0 }

    /// Safariのバーの上端が`safariTop`にあり、シートの幅が`width`のときの範囲（同じ座標）。
    /// シートの上端（Safariのバーの上端から`safariTopInset`だけ上）から、Safariのバーの上端から上の帯の高さと`height`を足した分だけ下まで。
    func frame(width: CGFloat, safariTop: CGFloat) -> CGRect {
        CGRect(x: inset, y: safariTop - safariTopInset, width: max(0, width - inset * 2), height: safariTopInset + handleHeight + height)
    }
}

/// アプリ内のSafariのバーの上に重ねる、シートを引ける範囲のビュー。シートのSafari（`InAppBrowserSheet`）と、重ねたウインドウのSafari（`InAppBrowserOverlayWindow`。伏せている間と全画面の間）で、同じ見た目と範囲にする。
/// Safariの上で触れたことは、アプリの`hitTest`を通らずにSafariのプロセスへ行く。上に自分のビューを重ねると、そこで触れたことはアプリに届く。
/// 色のない（完全に透明な）ビューでは、触れたことが重ねたビューを通り抜けてSafariへ行く（シミュレーターで確かめた）。そのため、見た目にはわからない濃さの色を付ける。
/// Safariのバーとページは別のプロセスが描いていて、アプリからはどちらの上かを触れた場所で選び分けられないので、範囲の高さと左右の空きはチューニングで決める。
final class InAppBrowserBarGrabView: UIView {
    let barGrab: InAppBrowserBarGrab
    /// VoiceOverで、シートのグラバーと同じ名前のボタンとして読み、操作したときに呼ぶ。nilなら読まない（シートでは、グラバーが受け持つ）。
    var onAccessibilityActivate: (() -> Void)? {
        didSet { isAccessibilityElement = onAccessibilityActivate != nil }
    }
    /// VoiceOverで読む、シートを折りたたんでいるか。
    var readsAsCollapsed = false

    init(barGrab: InAppBrowserBarGrab) {
        self.barGrab = barGrab
        super.init(frame: .zero)
        backgroundColor = barGrab.isVisible ? UIColor.systemRed.withAlphaComponent(0.4) : UIColor.black.withAlphaComponent(0.01)
        accessibilityLabel = InAppBrowserSheetTexts.grabber
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var accessibilityValue: String? {
        get { InAppBrowserSheetTexts.grabberValue(isCollapsed: readsAsCollapsed) }
        set { _ = newValue }
    }

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate?()
        return onAccessibilityActivate != nil
    }
}

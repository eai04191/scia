import SwiftUI
import UIKit

/// Macでは、ウィンドウがアクティブな間、UIKitがナビゲーションバーの下のぼかし（スクロールの上端の効果）を消し、
/// 一覧の文字がタイトルやボタンと重なって読めなくなる。ポインタをバーに乗せたときと、アクティブでないウィンドウでは消えない。下端の効果も消えない。
/// 消しているのはUIKitの中（`UIScrollView`の上端の効果の更新）で、効果のスタイルを変えても戻らないため、
/// Macでは、内容がバーの下に入っている間、ナビゲーションバーにぼかしの背景を付けて代わりにし、上端の効果は止める。
/// 止めないと、ポインタを乗せたときやアクティブでないときに、背景と上端の効果が重なって二重に見える。
/// 上端の効果を止めるのは、`hidesTopEdgeEffectOnMac()`と`topEdgeEffectHiddenOnMac()`を呼んだスクロールビューだけ。
/// 呼んでいない画面では、Macで背景と上端の効果が重なる。
@MainActor
enum MacNavigationBarBackground {
    static var isNeeded: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

    /// アプリのナビゲーションバーに背景を付ける。一覧の一番上にいるときは、iPhoneと同じく背景を付けない（`scrollEdgeAppearance`を指定しない）。
    static func install() {
        guard isNeeded else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        // iOS 26の標準の背景は何も描かず、上端の効果に任せるため、ぼかしを明示する
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

extension UIScrollView {
    /// ナビゲーションバーの下に置くスクロールビューで、Macでは上端の効果を止め、バーの背景だけにする。
    func hidesTopEdgeEffectOnMac() {
        guard MacNavigationBarBackground.isNeeded else { return }
        topEdgeEffect.isHidden = true
    }
}

extension View {
    /// ナビゲーションバーの下に置くスクロールで、Macでは上端の効果を止め、バーの背景だけにする。
    func topEdgeEffectHiddenOnMac() -> some View {
        scrollEdgeEffectHidden(MacNavigationBarBackground.isNeeded, for: .top)
    }
}

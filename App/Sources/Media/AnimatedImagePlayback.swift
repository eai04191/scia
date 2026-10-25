import Accessibility
import UIKit

/// 動く画像（アイコン、カスタム絵文字）を動かしてよいかの、端末の設定の側の決まり。アプリの設定で動かすことにしていても、ここが許さなければ静止画で描く。
/// 動く画像を描く場所は、端末の設定をそれぞれで見ず、ここを見る。設定が変わったら`changeNotifications`で描き直す。
@MainActor
enum AnimatedImagePlayback {
    /// 「視差効果を減らす」がオフで、「アニメーション画像を自動再生」がオンのときだけ動かす。
    static var isAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled && AccessibilitySettings.animatedImagesEnabled
    }

    /// `isAllowed`が変わりうるときの通知。
    static let changeNotifications: [Notification.Name] = [
        UIAccessibility.reduceMotionStatusDidChangeNotification,
        AccessibilitySettings.animatedImagesEnabledDidChangeNotification,
    ]
}

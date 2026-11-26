import Accessibility
import SciaCore
import UIKit

/// 動く画像（アイコン、カスタム絵文字）を動かしてよいかの、端末の設定の側の決まり。アプリの設定で動かすことにしていても、ここが許さなければ静止画で描く。
/// 動く画像を描く場所は、端末の設定をそれぞれで見ず、ここを見る。設定が変わったら`changeNotifications`で再描画する。
@MainActor
enum AnimatedImagePlayback {
    /// 「視差効果を減らす」がオフで、「アニメーション画像を自動再生」がオンのときだけ動かす。
    static var isAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled && AccessibilitySettings.animatedImagesEnabled
    }

    /// 描くときに組み立て直すもの（文字列、メニュー）が、カスタム絵文字を動かすか。アプリの設定と端末の設定の両方が許すときだけ動かす。
    /// 動かす場所は元の画像を読み、動かさない場所は動かない版を読むので、どちらを読むかもこれで決める（`EmojiImageStore.choice(animates:)`）。
    /// `EmojiImageView`に描く場所は、端末の設定が変わったときに組み立て直さないので、アプリの設定だけで決め、端末の設定は`EmojiImageView`が見る。
    static func animatesCustomEmojis(_ settings: AppSettings) -> Bool {
        settings.animatesCustomEmojis && isAllowed
    }

    /// `isAllowed`が変わりうるときの通知。
    static let changeNotifications: [Notification.Name] = [
        UIAccessibility.reduceMotionStatusDidChangeNotification,
        AccessibilitySettings.animatedImagesEnabledDidChangeNotification,
    ]
}

import UIKit

/// 待ってから画面をプッシュする操作で、選択したときに見えていた画面。待つ間にタブを移ったり、戻ったり、別の画面を開いたりモーダルビューを出したりしたら、届いてもプッシュしない。
/// 見ていないタブに覚えのない画面がプッシュされたり、開く先をこちらで移して操作の途中で画面が飛んだりしないようにする。
@MainActor
struct PushAnchor {
    private weak var navigation: UINavigationController?
    private weak var top: UIViewController?

    init(_ source: UIViewController) {
        navigation = source.navigationController
        top = navigation?.topViewController
    }

    /// 選択したときと同じ画面が、いちばん上に見えたままか。ほかのタブを選ぶと、そのタブのナビゲーションはウィンドウから外れる。
    /// 添付ファイルのビューアのように元の画面をウィンドウに残したまま重ねる画面は、`presentedViewController`で見る。祖先が出しているものも返る。
    /// 下げたアプリ内のSafariのシートも`presentedViewController`に返るが、後ろの画面を触れるので、モーダルビューに数えない。
    /// 閉じている途中の画面も数えない。閉じるのと同時に、その下にプッシュするため。下へスワイプして閉じている途中は、取り消せるので数える。
    var isStillShowing: Bool {
        guard let navigation, let top else { return false }
        guard navigation.topViewController === top, navigation.viewIfLoaded?.window != nil else { return false }
        guard let presented = navigation.presentedViewController else { return true }
        if presented.isBeingDismissed, presented.transitionCoordinator?.initiallyInteractive != true { return true }
        return (presented as? InAppBrowserSheet)?.leavesScreenBehindUsable == true
    }
}

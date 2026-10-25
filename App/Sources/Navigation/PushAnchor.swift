import UIKit

/// 待ってから画面を積む操作で、押したときに見えていた画面。待つ間にタブを移ったり、戻ったり、別の画面を開いたり上に重ねたりしたら、届いても積まない。
/// 見ていないタブに覚えのない画面が積まれたり、開く先をこちらで移して操作の途中で画面が飛んだりしないようにする。
@MainActor
struct PushAnchor {
    private weak var navigation: UINavigationController?
    private weak var top: UIViewController?

    init(_ source: UIViewController) {
        navigation = source.navigationController
        top = navigation?.topViewController
    }

    /// 押したときと同じ画面が、いちばん上に見えたままか。ほかのタブを選ぶと、そのタブのナビゲーションはウィンドウから外れる。
    /// 添付ファイルのビューアのように元の画面をウィンドウに残したまま重ねる画面は、`presentedViewController`で見る。祖先が出しているものも返る。
    var isStillShowing: Bool {
        guard let navigation, let top else { return false }
        return navigation.topViewController === top && navigation.viewIfLoaded?.window != nil && navigation.presentedViewController == nil
    }
}

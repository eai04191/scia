import UIKit

extension UIView {
    /// ステータスバーを押したときに、UIKitが最上部へ動かす対象にするスクロールビュー。`scrollsToTop`が入っていて、画面に見えていて、最上部にいないもの。
    func scrollViewsScrollingToTop() -> [UIScrollView] {
        guard !isHidden, alpha > 0 else { return [] }
        var found: [UIScrollView] = []
        if let scrollView = self as? UIScrollView, scrollView.scrollsToTop,
           scrollView.contentOffset.y > -scrollView.adjustedContentInset.top {
            found.append(scrollView)
        }
        for subview in subviews {
            found += subview.scrollViewsScrollingToTop()
        }
        return found
    }
}

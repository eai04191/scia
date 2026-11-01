import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄のカプセルなどが覆う下端を、一覧以外の積んだ画面でも空ける。
@MainActor
@Suite(.scratch, .serialized)
struct CoveredBottomTests {
    /// 一覧以外の画面を積んでも、末尾までスクロールした最後の行が、覆われた下端より上に出る。
    @Test func pushedScrollViewEndsAboveCoveredBottom() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let pushed = UIViewController()
        let scrollView = UIScrollView(frame: pushed.view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let content = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 3000))
        scrollView.addSubview(content)
        scrollView.contentSize = content.frame.size
        pushed.view.addSubview(scrollView)
        harness.navigation.pushViewController(pushed, animated: false)
        harness.window.layoutIfNeeded()

        harness.coverBottom(400)
        let inset = scrollView.adjustedContentInset
        scrollView.contentOffset.y = scrollView.contentSize.height + inset.bottom - scrollView.bounds.height

        let contentBottom = content.convert(content.bounds, to: harness.window).maxY
        #expect(contentBottom <= harness.window.bounds.maxY - 400 + 0.5, "最後の行が、覆われた下端の裏に\(contentBottom - (harness.window.bounds.maxY - 400))pt隠れています")
    }

    /// 覆うものがなくなったら、足した分を戻す。
    @Test func uncoveringRestoresSafeArea() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let view: UIView = harness.viewController.view
        let before = view.safeAreaInsets.bottom

        harness.coverBottom(400)
        let covered = view.safeAreaInsets.bottom
        harness.coverBottom(0)

        #expect(covered == 400)
        #expect(view.safeAreaInsets.bottom == before)
    }
}

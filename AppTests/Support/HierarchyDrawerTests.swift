import Testing
import UIKit

@MainActor
@Suite(.failureState)
struct HierarchyDrawerTests {
    /// 上限の回数までは通し、それを超えて描いたら落とす。
    @Test func failsWhenDrawingMoreThanLimit() {
        let drawer = HierarchyDrawer()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        for _ in 0 ..< HierarchyDrawer.limit {
            _ = drawer.image(of: view, scale: 1)
        }
        withKnownIssue {
            _ = drawer.image(of: view, scale: 1)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("drawHierarchyを\(HierarchyDrawer.limit)回より多く") }
        }
    }
}

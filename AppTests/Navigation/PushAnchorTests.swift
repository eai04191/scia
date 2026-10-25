import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct PushAnchorTests {
    @MainActor
    private struct Harness {
        let arrangement: TabArrangement
        let navigations: [TabItem: UINavigationController]
        let window: UIWindow

        init() throws {
            var navigations: [TabItem: UINavigationController] = [:]
            for item in [TabItem.home, .local, .federated, .notifications] {
                navigations[item] = UINavigationController(rootViewController: UIViewController())
            }
            self.navigations = navigations
            let layout = MenuLayout<TabItem>(elements: [.item(.home, isVisible: true), .item(.notifications, isVisible: true), .more, .item(.local, isVisible: true), .item(.federated, isVisible: true)])
            arrangement = TabArrangement(navigation: { navigations[$0] }, placement: TabPlacement(layout: layout), restoring: .home)
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "テストのホストアプリにウィンドウシーンがありません"
            )
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = arrangement.tabBarController
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func source(_ item: TabItem) throws -> UIViewController {
            try #require(navigations[item]?.topViewController)
        }
    }

    @Test func showingWhileNothingChanged() throws {
        let harness = try Harness()
        let anchor = PushAnchor(try harness.source(.home))

        #expect(anchor.isStillShowing)
    }

    /// 待つ間にほかのタブへ移ったら、見ていないタブに積まない。戻ってくれば、また積む。
    @Test func notShowingAfterMovingToAnotherTab() throws {
        let harness = try Harness()
        let anchor = PushAnchor(try harness.source(.home))

        harness.arrangement.show(.notifications)
        harness.window.layoutIfNeeded()
        #expect(!anchor.isStillShowing)

        harness.arrangement.show(.home)
        harness.window.layoutIfNeeded()
        #expect(anchor.isStillShowing)
    }

    /// 切り替えタブの中で別の項目に切り替えたときも、前の項目に積まない。
    @Test func notShowingAfterSwitchingWithinSwitchTab() throws {
        let harness = try Harness()
        harness.arrangement.show(.local)
        harness.window.layoutIfNeeded()
        let anchor = PushAnchor(try harness.source(.local))
        #expect(anchor.isStillShowing)

        harness.arrangement.show(.federated)
        harness.window.layoutIfNeeded()
        #expect(!anchor.isStillShowing)
    }

    @Test func notShowingAfterPushingAnotherScreen() throws {
        let harness = try Harness()
        let anchor = PushAnchor(try harness.source(.home))

        harness.navigations[.home]?.pushViewController(UIViewController(), animated: false)
        #expect(!anchor.isStillShowing)
    }

    /// 添付ファイルのビューアのように、元の画面をウィンドウに残したまま上に重ねたときも、その裏に積まない。閉じれば、また積む。
    @Test func notShowingWhileCoveredByPresentedScreen() async throws {
        let harness = try Harness()
        let anchor = PushAnchor(try harness.source(.home))
        let viewer = UIViewController()
        viewer.modalPresentationStyle = .overFullScreen

        try await harness.arrangement.tabBarController.presentForTesting(viewer)
        #expect(!anchor.isStillShowing)

        try await viewer.dismissForTesting()
        #expect(anchor.isStillShowing)
    }

    @Test func notShowingAfterGoingBack() throws {
        let harness = try Harness()
        let navigation = try #require(harness.navigations[.home])
        navigation.pushViewController(UIViewController(), animated: false)
        let anchor = PushAnchor(try harness.source(.home))

        navigation.popViewController(animated: false)
        #expect(!anchor.isStillShowing)
    }
}

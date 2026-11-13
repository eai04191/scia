import SciaTesting
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.failureState)
struct ContentNavigationPushTests {
    private func makeNavigation() throws -> (ContentNavigationController, UIWindow) {
        let navigation = ContentNavigationController(rootViewController: UIViewController())
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "テストのホストアプリにウィンドウシーンがありません"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (navigation, window)
    }

    /// 重ねた画面を閉じるのと同時に積む間は、アニメーション付きで頼まれても、その場で出す。
    @Test func pushesImmediatelyWhileAnimationIsOff() throws {
        let (navigation, window) = try makeNavigation()
        defer { window.isHidden = true }
        navigation.pushesWithoutAnimation = true

        navigation.pushViewController(UIViewController(), animated: true)

        #expect(navigation.transitionCoordinator == nil)
    }

    @Test func animatesPushOtherwise() throws {
        let (navigation, window) = try makeNavigation()
        defer { window.isHidden = true }

        navigation.pushViewController(UIViewController(), animated: true)

        #expect(navigation.transitionCoordinator?.isAnimated == true)
        navigation.setViewControllers([UIViewController()], animated: false)
    }
}

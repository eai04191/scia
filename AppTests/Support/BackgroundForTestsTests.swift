import SciaTesting
import SwiftUI
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.failureState)
struct BackgroundForTestsTests {
    /// 裏に回った状態を作ったテストのあとも、SwiftUIのスプリングで動かす動きが終わる。
    @Test func springAnimationsFinishAfterBackground() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        window.rootViewController?.view.addSubview(view)

        // 止まるのは、裏に回る前にスプリングの動きを一度でも走らせたプロセスだけなので、先に走らせる。
        var finishedBefore = false
        UIView.animateSmoothly(duration: 0.05) { view.frame.origin.y = 20 } completion: { finishedBefore = true }
        try await waitUntil { finishedBefore }

        whileInBackground {}

        var finished = false
        UIView.animateSmoothly(duration: 0.05) { view.frame.origin.y = 50 } completion: { finished = true }
        try await waitUntil { finished }
    }
}

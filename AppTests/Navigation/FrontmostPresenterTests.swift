import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 重ねた画面を閉じている途中に出そうとした画面を、閉じ終えてから、そのとき手前にある画面に出す。
/// 閉じる動きは、ウィンドウの層の時間を止めて手で進める。進めるまでは、閉じている途中のままになる。
@MainActor
@Suite(.serialized, .failureState)
struct FrontmostPresenterTests {
    private let window: UIWindow
    private let root = UIViewController()
    private let clock: LayerClock

    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        clock = LayerClock(freezing: window.layer)
    }

    private func makeAlert() -> UIAlertController {
        let alert = UIAlertController(title: "失敗しました", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        return alert
    }

    private func isShown(_ screen: UIViewController) -> Bool {
        screen.presentingViewController != nil && !screen.isBeingPresented
    }

    /// 重ねた画面を閉じ、ウィンドウを隠す。
    private func tearDown() async throws {
        clock.release()
        root.dismiss(animated: false)
        try await waitUntil { root.presentedViewController == nil }
        window.isHidden = true
    }

    /// シートを閉じている途中に出したアラートは、閉じ終えてから、下の画面に出る。
    @Test func presentsAfterSheetFinishesDismissing() async throws {
        let sheet = UIViewController()
        try await root.presentForTesting(sheet, advancing: clock)
        sheet.dismiss(animated: true)
        try #require(sheet.isBeingDismissed)

        let alert = makeAlert()
        root.presentOnFrontmost(alert)
        #expect(alert.presentingViewController == nil, "閉じている途中に出しました")

        try await clock.runUntilIdle()
        #expect(isShown(alert))
        #expect(root.presentedViewController === alert)
        try await tearDown()
    }

    /// 2枚重ねた手前だけを閉じている途中なら、閉じ終えてから、残った画面の上に出る。
    @Test func presentsOnRemainingScreenAfterTopFinishesDismissing() async throws {
        let lower = UIViewController()
        let upper = UIViewController()
        try await root.presentForTesting(lower, advancing: clock)
        try await lower.presentForTesting(upper, advancing: clock)
        upper.dismiss(animated: true)
        try #require(upper.isBeingDismissed)

        let alert = makeAlert()
        root.presentOnFrontmost(alert)

        try await clock.runUntilIdle()
        #expect(isShown(alert))
        #expect(root.presentedViewController === lower)
        #expect(lower.presentedViewController === alert)
        try await tearDown()
    }

    /// 閉じている途中に続けて出した2つは、どちらも失われず、頼んだ順に重なる。
    @Test func presentsEveryScreenRequestedWhileDismissing() async throws {
        let sheet = UIViewController()
        try await root.presentForTesting(sheet, advancing: clock)
        sheet.dismiss(animated: true)
        try #require(sheet.isBeingDismissed)

        let first = UIViewController()
        let second = makeAlert()
        root.presentOnFrontmost(first)
        root.presentOnFrontmost(second)

        try await clock.runUntilIdle()
        #expect(isShown(first))
        #expect(isShown(second))
        #expect(root.presentedViewController === first)
        #expect(first.presentedViewController === second)
        try await tearDown()
    }

    /// 閉じている途中の画面がなければ、待たずに、いちばん手前の画面に出す。
    @Test func presentsImmediatelyWhenNothingIsDismissing() async throws {
        let sheet = UIViewController()
        try await root.presentForTesting(sheet, advancing: clock)

        let alert = makeAlert()
        root.presentOnFrontmost(alert)
        #expect(alert.presentingViewController === sheet)

        try await clock.runUntilIdle()
        #expect(isShown(alert))
        try await tearDown()
    }

    /// 手前の画面を閉じている途中に、重ねた画面をすべて閉じても、下の画面が残らない。
    @Test func closesAllScreensAfterTopFinishesDismissing() async throws {
        let lower = UIViewController()
        let upper = UIViewController()
        try await root.presentForTesting(lower, advancing: clock)
        try await lower.presentForTesting(upper, advancing: clock)
        upper.dismiss(animated: true)
        try #require(upper.isBeingDismissed)

        var continued = false
        root.closeAllScreens { continued = true }

        try await clock.runUntilIdle()
        #expect(continued)
        #expect(root.presentedViewController == nil)
        try await tearDown()
    }
}

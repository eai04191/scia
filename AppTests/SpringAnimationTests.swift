import SciaTesting
import Testing
import UIKit
@testable import Scia

/// アプリの動き（`animateSpring`）の、始まりと止め方。
@MainActor
@Suite(.failureState)
struct SpringAnimationTests {
    private func makeWindow() throws -> (UIWindow, UIView, LayerClock) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let clock = LayerClock(freezing: window.layer)
        let view = UIView(frame: CGRect(x: 20, y: 100, width: 100, height: 40))
        window.addSubview(view)
        window.isHidden = false
        CATransaction.flush()
        return (window, view, clock)
    }

    /// 動きの外で不透明度を0にした直後に上げ始めると、まだ画面に出ていない0から上げる。
    /// 入れ替える文字（リンクカードの文字など）を、画面に残っている前の不透明度から始めると、薄くしている前の文字と重なって見えるため。
    /// 同じビューの位置を同時に動かしていても変わらない。
    @Test func fadeStartsFromValueSetJustBefore() async throws {
        let (window, view, clock) = try makeWindow()
        defer { window.isHidden = true }

        UIView.performWithoutAnimation { view.alpha = 0 }
        UIView.animateSpring(duration: 0.4, in: window) { view.frame.origin.x = 200 }
        UIView.animateSpring(duration: 0.4, delay: 0.1, in: view) { view.alpha = 1 }
        try await clock.advance(by: LayerClock.frame)

        let opacity = try #require(view.layer.presentation()).opacity
        #expect(opacity < 0.05, "不透明度が\(opacity)から始まりました")
    }

    /// 不透明度を上げている途中で`stopFading`すると、残りを足さずにその不透明度で止まる。
    @Test func stopFadingStopsImmediately() async throws {
        let (window, view, clock) = try makeWindow()
        defer { window.isHidden = true }
        UIView.performWithoutAnimation { view.alpha = 0 }
        CATransaction.flush()

        UIView.animateSpring(duration: 0.4, in: view) { view.alpha = 1 }
        try await clock.advance(by: LayerClock.frame * 5)
        view.stopFading(at: 0)
        CATransaction.flush()
        try await clock.advance(by: LayerClock.frame)

        #expect(try #require(view.layer.presentation()).opacity == 0)
        #expect(view.layer.animationKeys()?.isEmpty ?? true, "\(view.layer.animationKeys() ?? [])")
    }

    /// 動いている途中で位置と大きさの動きを外すと、入れた枠にすぐ置かれ、残りが足されて動き続けない。
    @Test func removeAnimationsPlacesAtNewFrame() async throws {
        let (window, view, clock) = try makeWindow()
        defer { window.isHidden = true }

        UIView.animateSpring(duration: 0.4, in: view) { view.frame = CGRect(x: 200, y: 300, width: 160, height: 60) }
        try await clock.advance(by: LayerClock.frame * 5)
        UIView.removeAnimations(of: ["bounds", "position"], in: view)
        UIView.performWithoutAnimation { view.frame = CGRect(x: 10, y: 10, width: 50, height: 50) }
        CATransaction.flush()
        try await clock.advance(by: LayerClock.frame)

        #expect(try #require(view.layer.presentation()).frame == CGRect(x: 10, y: 10, width: 50, height: 50))
    }
}

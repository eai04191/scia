import SciaTesting
import Testing
import UIKit

/// 層の時間を止めて手で進める時計の、動きの終わりを見て進める動き。
/// 動きの長さは、終わる時点がコマの境目に来ないようにする。境目ちょうどのコマは、Core Animationが終わったとみなすかどうかが揺れるため。
@MainActor
@Suite(.failureState)
struct LayerClockTests {
    /// 最後の終わりの1つ手前まで進めると、それより前に終わる動きの終わりの処理が始めた動きの終わりまで延ばし、すべて終わる前のコマで止まる。
    /// 延ばさずに止まると、まだ動いている途中のコマを、すべて終わる直前のコマとして見てしまう。
    @Test func advanceToFrameBeforeLastEndFollowsChainedAnimations() async throws {
        let (window, clock, layers) = try Self.makeWindow(layerCount: 3)
        defer { window.isHidden = true }
        try await clock.advance(by: LayerClock.frame)

        var finished = false
        Self.fade(layers[0], duration: 0.21) {
            Self.fade(layers[1], duration: 0.31) { finished = true }
        }
        Self.fade(layers[2], duration: 0.41) {}
        try await clock.advanceToFrameBeforeLastEnd()

        #expect(!finished, "すべての動きが終わってしまいました（\(clock.now)秒）")
        try await clock.advance(by: LayerClock.frame)
        #expect(finished, "1コマ進めても、すべての動きが終わりません（\(clock.now)秒）")
    }

    /// 時計を止めた時間0で始まった動きは、始まったあとも始まりの時間が0のままだが、始まっていない動きとみなさず、終わる前のコマで止まる。
    @Test func advanceToFrameBeforeLastEndStopsBeforeAnimationStartedAtZero() async throws {
        let (window, clock, layers) = try Self.makeWindow(layerCount: 1)
        defer { window.isHidden = true }

        var finished = false
        Self.fade(layers[0], duration: 0.21) { finished = true }
        try await clock.advanceToFrameBeforeLastEnd()

        #expect(!finished, "動きが終わってしまいました（\(clock.now)秒）")
        try await clock.advance(by: LayerClock.frame)
        #expect(finished, "1コマ進めても、動きが終わりません（\(clock.now)秒）")
    }

    /// 終わっても外さない動きがあっても、終わる前のコマで止まって戻る。
    @Test func advanceToFrameBeforeLastEndReturnsWithHeldAnimation() async throws {
        let (window, clock, layers) = try Self.makeWindow(layerCount: 1)
        defer { window.isHidden = true }

        Self.fade(layers[0], duration: 0.21, removedOnCompletion: false) {}
        try await clock.advanceToFrameBeforeLastEnd()

        #expect(clock.now < 0.21)
        #expect(clock.now > 0.21 - LayerClock.frame * 2)
    }

    private static func makeWindow(layerCount: Int) throws -> (UIWindow, LayerClock, [CALayer]) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let clock = LayerClock(freezing: window.layer)
        let views = (0..<layerCount).map { UIView(frame: CGRect(x: 0, y: CGFloat($0) * 20, width: 10, height: 10)) }
        views.forEach(window.addSubview)
        window.isHidden = false
        CATransaction.flush()
        return (window, clock, views.map(\.layer))
    }

    private static func fade(_ layer: CALayer, duration: TimeInterval, removedOnCompletion: Bool = true, completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.isRemovedOnCompletion = removedOnCompletion
        layer.add(animation, forKey: "fade")
        CATransaction.commit()
    }
}

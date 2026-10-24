public import QuartzCore
public import Testing
#if canImport(UIKit)
import UIKit
#endif

/// 層の中の動き（Core Animation）の時間を止め、テストが手で進める時計。
/// 動きの途中で状態を見たり次の操作を送ったりするテストで、実際の時間の代わりに使う。進めた分だけ動きが進み、終わった動きの終わりの処理もその時点で呼ばれる。
/// 止めるのは、動きがないとき（作った直後か`runUntilIdle()`のあと）にする。動いている途中に止めると、その動きの時間が飛ぶ。
@MainActor
public final class LayerClock {
    /// 1回に進める長さ。終わりの処理が次の動きを始めるとき、実際の動きと同じく、前の動きが終わったコマから始めさせる。
    public static let frame: TimeInterval = 1.0 / 60
    /// 終わった動きを知らせさせるときに、時間を流す速さ。
    private static let deliverySpeed: Float = 1e-6

    private let layer: CALayer

    /// `layer`とその中の動きの時間を止める。
    public init(freezing layer: CALayer) {
        self.layer = layer
        layer.speed = 0
        layer.timeOffset = 0
        layer.beginTime = 0
        CATransaction.flush()
    }

    /// 止めてから進めた長さ。
    public var now: TimeInterval { layer.timeOffset }

    /// `seconds`だけ、1コマずつ進める。コマごとに、そこまでに終わった動きの終わりの処理が呼ばれ終えるまで待つ。
    public func advance(by seconds: TimeInterval) async throws {
        var remaining = seconds
        repeat {
            let length = min(Self.frame, remaining)
            try await step(by: length)
            remaining -= length
        } while remaining > 1e-9
    }

    /// 終わりのある動きがなくなるまで進める。止まらない動き（カーソルの点滅など）は待たない。
    /// 終わりの処理がすぐ次の動きを始めることがあるので、そのあともう1コマ進めて、動きが始まらないことを確かめる。
    public func runUntilIdle(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let limit = now + 600
        var quietFrames = 0
        while quietFrames < 2 {
            guard now < limit else {
                Issue.record("動きが止まらないまま、固まったとみなす上限を過ぎました: \(Self.finiteAnimations(in: layer))", sourceLocation: sourceLocation)
                return
            }
            try await step(by: Self.frame)
            quietFrames = Self.finiteAnimations(in: layer).isEmpty ? quietFrames + 1 : 0
        }
    }

    /// `condition`を満たすまで、1コマずつ進める。画面を出し終える、閉じ終えるのように、動きの終わりで変わる状態を待つのに使う。
    public func advance(until condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let limit = now + 600
        while !condition() {
            guard now < limit else {
                Issue.record("条件を満たさないまま、固まったとみなす上限を過ぎました", sourceLocation: sourceLocation)
                return
            }
            try await step(by: Self.frame)
        }
    }

    /// 時間を戻す。止めている間に始めた動きは、戻したとたんに終わりまで進む。
    public func release() {
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
    }

    private func step(by seconds: TimeInterval) async throws {
        layer.timeOffset += seconds
        deliverEndedAnimations()
        // 終わりの処理と、メインスレッドに積まれた処理（キーボードの知らせ、レイアウトのあとの処理など）を流す。少なくとも1回はRunLoopを回す。
        var spun = false
        try await waitUntil {
            defer { spun = true }
            return spun && Self.endedAnimations(in: layer, at: now).isEmpty
        }
    }

    /// 止めたままでは、終わった動きの終わりの処理が呼ばれない。ごく遅く時間を流して、今の時点までに終わったものを知らせさせ、すぐ止め直す。
    /// 流す速さは実際の時間の100万分の1なので、流している間に負荷で止められても、まだ終わっていない動きはほとんど進まない（1秒止められて1マイクロ秒）。
    private func deliverEndedAnimations() {
        let target = layer.timeOffset
        layer.speed = Self.deliverySpeed
        layer.beginTime = layer.superlayer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        layer.timeOffset = target
        CATransaction.flush()
        layer.speed = 0
        layer.beginTime = 0
        layer.timeOffset = target
        CATransaction.flush()
    }

    /// 終わりのある動きの名前。入力欄のカーソルの点滅（`repeatCount`が`greatestFiniteMagnitude`）、Liquid Glassがほかの層に合わせ続ける動き（`duration`が無限）、
    /// 送信中のくるくる（`UIActivityIndicatorView`の中の絵の差し替え）は、待っても終わらないので含めない。
    public static func finiteAnimations(in layer: CALayer) -> [String] {
        #if canImport(UIKit)
        if layer.delegate is UIActivityIndicatorView { return [] }
        #endif
        let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
        let own = (layer.animationKeys() ?? []).filter { key in
            guard let animation = layer.animation(forKey: key) else { return false }
            return isFinite(animation)
        }
        return own.map { "\(owner).\($0)" } + (layer.sublayers ?? []).flatMap(finiteAnimations(in:))
    }

    /// `time`（止めた層の時間）までに終わったのに、まだ外れていない動き。終わりの処理が呼ばれると外れる。終わっても残す動き（`isRemovedOnCompletion`がfalse）は含めない。
    private static func endedAnimations(in layer: CALayer, at time: TimeInterval, root: CALayer? = nil) -> [String] {
        let root = root ?? layer
        let local = layer.convertTime(time, from: root)
        let own = (layer.animationKeys() ?? []).filter { key in
            guard let animation = layer.animation(forKey: key), animation.isRemovedOnCompletion, isFinite(animation) else { return false }
            return animation.beginTime + activeDuration(of: animation) <= local
        }
        return own + (layer.sublayers ?? []).flatMap { endedAnimations(in: $0, at: time, root: root) }
    }

    private static func isFinite(_ animation: CAAnimation) -> Bool {
        animation.duration.isFinite && animation.repeatCount < .greatestFiniteMagnitude && animation.repeatDuration.isFinite
    }

    private static func activeDuration(of animation: CAAnimation) -> TimeInterval {
        let once = animation.duration * (animation.autoreverses ? 2 : 1)
        if animation.repeatDuration > 0 { return animation.repeatDuration }
        return once * Double(max(animation.repeatCount, 1))
    }
}

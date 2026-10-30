public import CoreGraphics
import Foundation

/// スプリングの進み具合を、画面を描き換えるたびに渡す。複製の位置と、マスクのようにUIKitのアニメーションで動かせない見た目を、同じフレームでそろえるために使う。
@MainActor
public final class SpringDriver {
    private let spring: SpringCurve
    private let source: any FrameSource
    private let update: @MainActor (CGFloat) -> Void
    private let completion: @MainActor () -> Void
    private let longestElapsed: CFTimeInterval?
    /// 動き始めてからの時間。
    private var time: CFTimeInterval = 0
    private var ticker: FrameTicker?

    /// - Parameters:
    ///   - source: 経過時間を送る元。テストでは、実際の時間に頼らずに動きを進めるため、手で送る元を渡す。
    ///   - update: 進み具合を受け取る。0から始まり1に落ち着く。バウンスする場合は1を超えることがある。
    ///   - completion: 落ち着いたら呼ぶ。`stop`で止めたときは呼ばない。
    ///   - longestElapsed: 1フレームで進める時間の上限。nilなら、ひっかかりで間が空いても実際の時間で進め、決まった時間で落ち着かせる。
    ///     上限を付けると、間が空いたときに一度に大きく進まず、その分だけ落ち着くのが遅れる。
    public init(
        spring: SpringCurve,
        source: any FrameSource,
        longestElapsed: CFTimeInterval? = nil,
        update: @escaping @MainActor (CGFloat) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        self.spring = spring
        self.source = source
        self.update = update
        self.completion = completion
        self.longestElapsed = longestElapsed
    }

    /// 最初の進み具合をすぐに渡してから動かし始める。
    public func start() {
        ticker?.stop()
        time = 0
        // 上限を渡されなければ、スプリングは決まった時間で落ち着くため、ひっかかりで間が空いても経過時間を削らず、描かれる時刻とそろえる。
        // 持ち主が手放しても、落ち着くか止めるまで動かし続けるよう、動いている間は自分を強く持つ。止めると`ticker`を手放して解く。
        let ticker = FrameTicker(source: source, longestElapsed: longestElapsed) { elapsed in
            self.step(elapsed: elapsed)
        }
        self.ticker = ticker
        ticker.start()
        update(0)
    }

    /// 止めた時点の見た目のまま残す。
    public func stop() {
        ticker?.stop()
        ticker = nil
    }

    private func step(elapsed: CFTimeInterval) -> Bool {
        time += elapsed
        update(CGFloat(spring.value(at: time)))
        guard spring.isSettled(at: time) else { return true }
        stop()
        completion()
        return false
    }
}

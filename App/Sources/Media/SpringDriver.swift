import QuartzCore
import SciaCore

/// ばねの進み具合を、画面を描き換えるたびに渡す。写しの位置と、マスクのようにUIKitのアニメーションで動かせない見た目を、同じフレームでそろえるために使う。
@MainActor
final class SpringDriver: NSObject {
    private let spring: SpringCurve
    private let update: @MainActor (CGFloat) -> Void
    private let completion: @MainActor () -> Void
    private var startTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    /// - Parameters:
    ///   - update: 進み具合を受け取る。0から始まり1に落ち着く。弾む場合は1を超えることがある。
    ///   - completion: 落ち着いたら呼ぶ。`stop`で止めたときは呼ばない。
    init(spring: SpringCurve, update: @escaping @MainActor (CGFloat) -> Void, completion: @escaping @MainActor () -> Void) {
        self.spring = spring
        self.update = update
        self.completion = completion
    }

    /// 最初の進み具合をすぐに渡してから動かし始める。
    func start() {
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        update(0)
    }

    /// 止めた時点の見た目のまま残す。
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let time = link.targetTimestamp - startTime
        update(CGFloat(spring.value(at: time)))
        if spring.isSettled(at: time) {
            stop()
            completion()
        }
    }
}

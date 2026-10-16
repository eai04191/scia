import QuartzCore

/// 画面を描き換えるたびに、前のフレームからの経過時間を渡す。位置と速さを毎フレーム進める動きに使う。
///
/// 表示の時計（`CADisplayLink`）は受け取り手のこの部品を強く持つため、止めない限り動き続ける。
/// 持ち主が先に解放されると止める道筋がなくなるので、毎フレームの処理から続けるかを返させ、続けないなら自分で止める。
@MainActor
final class FrameTicker: NSObject {
    private let tick: @MainActor (CFTimeInterval) -> Bool
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// - Parameter tick: 経過時間を受け取り、次のフレームも続けるかを返す。持ち主がいなくなっていたらfalseを返す。
    init(tick: @escaping @MainActor (CFTimeInterval) -> Bool) {
        self.tick = tick
    }

    var isRunning: Bool {
        displayLink != nil
    }

    func start() {
        lastTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 次に画面に出る時刻までの時間を渡し、描かれる瞬間の位置を置く。
    ///
    /// 始めた直後に重い処理でメインスレッドが止まると、最初に届く時刻が始めた時刻より前になることがあるため、0未満にしない。
    /// ひっかかりで間が空いたときは、一度に大きく進めて飛んだように見えないよう、`longestElapsed`までにする。
    @objc private func step(_ link: CADisplayLink) {
        let elapsed = min(max(link.targetTimestamp - lastTimestamp, 0), Self.longestElapsed)
        lastTimestamp = max(lastTimestamp, link.targetTimestamp)
        if !tick(elapsed) {
            stop()
        }
    }

    /// 1回に渡す経過時間の上限。30fpsの1フレーム分。
    private static let longestElapsed: CFTimeInterval = 1.0 / 30
}

import QuartzCore

/// 画面を描き換えるたびに、前のフレームからの経過時間を渡す。位置と速さを毎フレーム進める動きに使う。
///
/// 表示の時計（`CADisplayLink`）は受け取り手を強く持つため、止めない限り動き続ける。
/// 持ち主が先に解放されると止める道筋がなくなるので、毎フレームの処理から続けるかを返させ、続けないなら自分で止める。
@MainActor
final class FrameTicker {
    private let tick: @MainActor (CFTimeInterval) -> Bool
    private let source: any FrameSource
    private(set) var isRunning = false

    /// - Parameters:
    ///   - source: 経過時間を送る元。テストでは、実際の時間に頼らずに動きを進めるため、手で送る元を渡す。
    ///   - tick: 経過時間を受け取り、次のフレームも続けるかを返す。持ち主がいなくなっていたらfalseを返す。
    init(source: any FrameSource = DisplayLinkFrameSource.shared, tick: @escaping @MainActor (CFTimeInterval) -> Bool) {
        self.source = source
        self.tick = tick
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        source.start(self)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stop(self)
    }

    /// 送る元から、前のフレームからの経過時間を受け取る。
    ///
    /// ひっかかりで間が空いたときは、一度に大きく進めて飛んだように見えないよう、`longestElapsed`までにする。
    func receive(elapsed: CFTimeInterval) {
        guard isRunning else { return }
        if !tick(min(max(elapsed, 0), Self.longestElapsed)) {
            stop()
        }
    }

    /// 1回に渡す経過時間の上限。30fpsの1フレーム分。
    private static let longestElapsed: CFTimeInterval = 1.0 / 30
}

/// `FrameTicker`に、毎フレームの経過時間を送る元。
@MainActor
protocol FrameSource: AnyObject {
    func start(_ ticker: FrameTicker)
    func stop(_ ticker: FrameTicker)
}

/// 画面の描き換え（`CADisplayLink`）に合わせて経過時間を送る。
@MainActor
final class DisplayLinkFrameSource: FrameSource {
    static let shared = DisplayLinkFrameSource()

    private var links: [ObjectIdentifier: DisplayLinkTarget] = [:]

    func start(_ ticker: FrameTicker) {
        let target = DisplayLinkTarget(ticker: ticker)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        target.link = link
        links[ObjectIdentifier(ticker)] = target
    }

    func stop(_ ticker: FrameTicker) {
        links.removeValue(forKey: ObjectIdentifier(ticker))?.link?.invalidate()
    }
}

/// 表示の時計の受け取り手。表示の時計がこれを、これが`FrameTicker`を強く持つ。
@MainActor
private final class DisplayLinkTarget: NSObject {
    let ticker: FrameTicker
    var link: CADisplayLink?
    private var lastTimestamp = AppDependencies.mediaTime()

    init(ticker: FrameTicker) {
        self.ticker = ticker
    }

    /// 次に画面に出る時刻までの時間を渡し、描かれる瞬間の位置を置く。
    /// 始めた直後に重い処理でメインスレッドが止まると、最初に届く時刻が始めた時刻より前になることがあるため、`FrameTicker`が0未満にしない。
    @objc func step(_ link: CADisplayLink) {
        let elapsed = link.targetTimestamp - lastTimestamp
        lastTimestamp = max(lastTimestamp, link.targetTimestamp)
        ticker.receive(elapsed: elapsed)
    }
}

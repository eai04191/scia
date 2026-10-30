import QuartzCore
import SciaCore

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

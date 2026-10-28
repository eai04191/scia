import QuartzCore
import SciaCore

/// スクロールしている間だけ画面の更新ごとに呼ばれ、落ちたフレームを数える。違和感レポートで、どのスクロールがカクついたかを見分けるために使う。
/// 常に動かすと、ProMotionの端末で画面を最高のリフレッシュレートに保ち続けて電池を使うため、スクロールの間に限る。
/// 動いている間は、`FrameWork.measure`で測った処理の時間も受け取り、落ちたフレームに使ったものを名前ごとに足し上げる。
@MainActor
final class ScrollHitchMonitor {
    private var link: CADisplayLink?
    private var ledger = FrameWorkLedger()

    func start() {
        link?.invalidate()
        ledger = FrameWorkLedger()
        let target = DisplayLinkTarget { [weak self] link in
            guard let self else {
                link.invalidate()
                return
            }
            ledger.frame(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        FrameWork.monitor = self
    }

    func stop() -> HitchCounter.Summary {
        finish().summary
    }

    /// 止めて、落ちたフレームの数と、落ちたフレームに使った処理の集計を返す。
    func finish() -> (summary: HitchCounter.Summary, work: FrameWorkTally) {
        link?.invalidate()
        link = nil
        if FrameWork.monitor === self {
            FrameWork.monitor = nil
        }
        return (ledger.summary, ledger.finish())
    }

    fileprivate func add(_ name: String, seconds: Double) {
        guard link != nil else { return }
        ledger.add(name, seconds: seconds)
    }
}

/// スクロールの間だけ、重くなりやすい処理の時間を測って`ScrollHitchMonitor`へ渡す。スクロールしていない間は、測らずにそのまま走らせる。
/// 入れ子になった処理（一覧の並べ直しの中の、行の大きさの計算など）は、内側の時間を外側から引いて渡し、同じ時間を二重に数えない。
@MainActor
enum FrameWork {
    /// 動いている計測。2つの一覧を同時にスクロールしたときは、あとから始めたほうだけが受け取る。
    /// 持ち主の画面がスクロールの途中で消えたら、計測も消えて画面の更新を止められるよう、弱く持つ。
    fileprivate static weak var monitor: ScrollHitchMonitor?
    /// 測っている途中の処理ごとの、内側の処理に使った時間。
    private static var nested: [Double] = []

    static func measure<T>(_ name: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        guard let monitor else { return try body() }
        let start = AppDependencies.mediaTime()
        nested.append(0)
        defer {
            let elapsed = AppDependencies.mediaTime() - start
            let inner = nested.removeLast()
            if !nested.isEmpty {
                nested[nested.count - 1] += elapsed
            }
            monitor.add(name(), seconds: max(elapsed - inner, 0))
        }
        return try body()
    }
}

/// `CADisplayLink`は対象を強く参照するため、計測する側を直接渡さずに挟む。
/// 直接渡すと、スクロールの途中で画面が閉じられた場合に、計測する側もリンクも残り続ける。挟んでおけば、計測する側が消えた次のフレームでリンクを止められる。
@MainActor
private final class DisplayLinkTarget: NSObject {
    private let onTick: @MainActor (CADisplayLink) -> Void

    init(onTick: @escaping @MainActor (CADisplayLink) -> Void) {
        self.onTick = onTick
    }

    @objc func tick(_ link: CADisplayLink) {
        onTick(link)
    }
}

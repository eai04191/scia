import QuartzCore
import SciaCore

/// スクロールしている間だけ画面の更新ごとに呼ばれ、落ちたフレームを数える。違和感レポートで、どのスクロールがカクついたかを見分けるために使う。
/// 常に動かすと、ProMotionの端末で画面を最高のリフレッシュレートに保ち続けて電池を使うため、スクロールの間に限る。
@MainActor
final class ScrollHitchMonitor {
    private var link: CADisplayLink?
    private var counter = HitchCounter()

    func start() {
        link?.invalidate()
        counter = HitchCounter()
        let target = DisplayLinkTarget { [weak self] link in
            guard let self else {
                link.invalidate()
                return
            }
            counter.record(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() -> HitchCounter.Summary {
        link?.invalidate()
        link = nil
        return counter.summary
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

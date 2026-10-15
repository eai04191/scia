import Foundation

/// 指で一覧を動かし始めてから止まるまでの1回のスクロール。違和感レポートで、どのスクロールのことかを見分けられるようにする。
public struct ScrollRecord: Sendable, Equatable {
    public enum Direction: String, Sendable {
        /// 下の内容へ進む向き。
        case down
        case up
    }

    public let screen: String
    public let direction: Direction
    /// 動いた量。表示領域の高さを1とする。
    public let pages: Double
    /// 指が触れてから止まるまでの秒数。
    public let duration: Double
    public let hitches: HitchCounter.Summary

    public init(screen: String, direction: Direction, pages: Double, duration: Double, hitches: HitchCounter.Summary) {
        self.screen = screen
        self.direction = direction
        self.pages = pages
        self.duration = duration
        self.hitches = hitches
    }

    /// 始まりと終わりの位置から組み立てる。`startOffset`と`endOffset`はスクロールの縦の位置で、大きいほど下の内容。
    public init(screen: String, startOffset: Double, endOffset: Double, viewportHeight: Double, duration: Double, hitches: HitchCounter.Summary) {
        self.init(
            screen: screen,
            direction: endOffset >= startOffset ? .down : .up,
            pages: viewportHeight > 0 ? abs(endOffset - startOffset) / viewportHeight : 0,
            duration: duration,
            hitches: hitches
        )
    }
}

/// 画面の更新の予定時刻と実際の時刻から、描画が間に合わずに落ちたフレームを数える。
/// `CADisplayLink`の`timestamp`と`targetTimestamp`を毎フレーム渡す。前のフレームで予定した時刻より実際の時刻が遅れた分を、落ちたフレームとみなす。
/// メインスレッドが詰まった落ちは捉えるが、描画サーバー側の落ちは見えないため、Instrumentsの値より少なく出ることがある。
public struct HitchCounter: Sendable, Equatable {
    public struct Summary: Sendable, Equatable {
        public let droppedFrames: Int
        /// 予定より遅れた時間の合計（秒）。
        public let hitchTime: Double

        public init(droppedFrames: Int, hitchTime: Double) {
            self.droppedFrames = droppedFrames
            self.hitchTime = hitchTime
        }
    }

    private var previousTarget: Double?
    public private(set) var summary = Summary(droppedFrames: 0, hitchTime: 0)

    public init() {}

    public mutating func record(timestamp: Double, targetTimestamp: Double) {
        defer { previousTarget = targetTimestamp }
        guard let previousTarget else { return }
        let frameDuration = targetTimestamp - timestamp
        let delay = timestamp - previousTarget
        // 時刻の揺れで遅れと数えないよう、半フレームより小さい差は無視する。
        guard frameDuration > 0, delay > frameDuration / 2 else { return }
        let dropped = max(Int((delay / frameDuration).rounded()), 1)
        summary = Summary(droppedFrames: summary.droppedFrames + dropped, hitchTime: summary.hitchTime + delay)
    }
}

public import Foundation

/// スクロール位置を、スプリングで目標へ寄せる。毎フレーム、今の位置と目標と経過時間を受け取り、次に置く位置を返す。
///
/// 位置と速さを持つスプリングとして進めるため、動いている途中に、上のセルが見積もりから実寸へ変わって位置が補正されたり、
/// 新着を足して目標までの距離が伸びたりしても、速さを持ち越したまま今の位置から目標へ向かう。
/// 進み具合を時間だけで決める動き（`SpringCurve`）で距離を縮め直すと、終わりぎわに距離が伸びたときに急に速くなり、
/// 動き直すと一度止まってしまう。
///
/// 時間とバウンスは`SpringCurve`と同じ定義で、止まった状態から動かせば`SpringCurve`と同じ道筋をたどる。
public struct SpringScroll: Sendable {
    /// 止まっているとみなす、目標からのずれ（pt）と速さ（pt/秒）。
    private static let settledDistance = 0.5
    private static let settledSpeed = 20.0
    /// 置いた位置と読み戻した位置の差がこれ以下なら、補正ではなく画素への丸めとみなす。
    /// 丸めた位置から進めると、1フレームの動きが画素より小さくなる終わりぎわに、動きが丸めで打ち消されて止まらなくなる。
    /// これより小さい補正は打ち消すため、中身がその分だけ動くが、1pt未満なので目立たない。
    private static let roundingTolerance = 1.0

    private let angularFrequency: Double
    private let dampingRatio: Double
    /// 今の速さ（pt/秒）。位置が増える向きを正にする。
    public private(set) var velocity: Double
    /// 前に返した、丸める前の位置。
    private var lastPosition: Double?

    /// - Parameters:
    ///   - duration: バウンスしない場合に、おおむね行き着くまでの時間。
    ///   - bounce: 0でバウンスせずに止まり、大きいほど行き過ぎてから戻る。
    ///   - velocity: 動き始めの速さ。
    public init(duration: TimeInterval, bounce: Double, velocity: Double = 0) {
        precondition(duration > 0, "スプリングの時間は正の値にします")
        precondition((0..<1).contains(bounce), "bounceは0以上1未満にします")
        angularFrequency = 2 * Double.pi / duration
        dampingRatio = 1 - bounce
        self.velocity = velocity
    }

    /// `current`から`time`秒進めた位置。速さも進める。
    /// - Parameter current: 今の位置。前に返した位置が画素に丸められていたり、補正で動いていたりする。
    public mutating func step(from current: Double, toward target: Double, by time: TimeInterval) -> Double {
        let start = lastPosition.flatMap { abs(current - $0) <= Self.roundingTolerance ? $0 : nil } ?? current
        let displacement = start - target
        let omega = angularFrequency
        let decay = exp(-dampingRatio * omega * time)
        let next: (displacement: Double, velocity: Double)
        if dampingRatio >= 1 {
            let slope = velocity + omega * displacement
            next = (
                decay * (displacement + slope * time),
                decay * (velocity - omega * slope * time)
            )
        } else {
            let dampedFrequency = omega * (1 - dampingRatio * dampingRatio).squareRoot()
            let cosine = cos(dampedFrequency * time)
            let sine = sin(dampedFrequency * time)
            next = (
                decay * (displacement * cosine + (velocity + dampingRatio * omega * displacement) / dampedFrequency * sine),
                decay * (velocity * cosine - (omega * omega * displacement + dampingRatio * omega * velocity) / dampedFrequency * sine)
            )
        }
        velocity = next.velocity
        lastPosition = target + next.displacement
        return target + next.displacement
    }

    /// 目標との差が見分けられないほど小さく、ほぼ止まっていて、動きを終えてよいか。
    public func isSettled(at position: Double, target: Double) -> Bool {
        abs(position - target) < Self.settledDistance && abs(velocity) < Self.settledSpeed
    }
}

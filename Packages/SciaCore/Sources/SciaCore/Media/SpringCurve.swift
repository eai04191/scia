public import Foundation

/// 0から1へ向かうスプリングの進み具合。UIKitの`UISpringTimingParameters(duration:bounce:initialVelocity:)`と同じ定義。
///
/// 動いている途中で行き先が変わる動き（閉じる途中に一覧をスクロールされ、戻り先のサムネイルが動くなど）は、
/// UIKitのアニメーションでは行き先を決め直せないため、毎フレームこの進み具合で始点と今の行き先のあいだを補う。
public struct SpringCurve: Sendable, Equatable {
    /// バウンスしない場合に、おおむね行き着くまでの時間。
    public let duration: TimeInterval
    /// 0でバウンスせずに止まり、大きいほど行き過ぎてから戻る。
    public let bounce: Double
    /// 動き始めの、進み具合の速さ（1秒あたり）。指でスワイプして離したときの速さを引き継ぐのに使う。
    public let initialVelocity: Double

    public init(duration: TimeInterval, bounce: Double, initialVelocity: Double = 0) {
        precondition(duration > 0, "スプリングの時間は正の値にします")
        precondition((0..<1).contains(bounce), "bounceは0以上1未満にします")
        self.duration = duration
        self.bounce = bounce
        self.initialVelocity = initialVelocity
    }

    /// 指でスワイプして離したときの速さ（pt/秒）を、`start`から`target`へ向かう進み具合の速さに直す。
    ///
    /// 行き先へ向かう向きの成分だけを使い、行き先から離れる向きにスワイプした分は捨てる。離れる向きの速さを引き継ぐと、
    /// 一度行き先と反対へ流れてから戻り、スワイプした向きと違う動きに見える。
    /// 速すぎるスワイプでは、バウンスしない設定でも行き先を越えてしまうため、バウンスしないスプリングが行き過ぎない速さ（角振動数）で抑える。
    public static func initialVelocity(
        releaseVelocity: (x: Double, y: Double),
        from start: (x: Double, y: Double),
        to target: (x: Double, y: Double),
        duration: TimeInterval
    ) -> Double {
        // ジェスチャーの速さは、NaNや無限大で届くことがある（指の最後の動きと離した時刻が同じなら、距離を0の時間で割る）。
        // NaNは下の範囲の制限をすり抜け、進み具合を動き始めからNaNにしてアプリを落とすため、引き継がない。
        guard releaseVelocity.x.isFinite, releaseVelocity.y.isFinite else { return 0 }
        let distance = (x: target.x - start.x, y: target.y - start.y)
        let squaredLength = distance.x * distance.x + distance.y * distance.y
        guard squaredLength > 1 else { return 0 }
        let toward = (releaseVelocity.x * distance.x + releaseVelocity.y * distance.y) / squaredLength
        return min(max(toward, 0), 2 * Double.pi / duration)
    }

    /// 経過時間`time`での進み具合。0から始まり、1に落ち着く。バウンスする場合は1を超えることがある。
    public func value(at time: TimeInterval) -> Double {
        guard time > 0 else { return 0 }
        let angularFrequency = 2 * Double.pi / duration
        let dampingRatio = 1 - bounce
        // 残りの割合（1から進み具合を引いたもの）を、1から始まり初速が`-initialVelocity`のスプリングとして解く。
        if dampingRatio >= 1 {
            return 1 - exp(-angularFrequency * time) * (1 + (angularFrequency - initialVelocity) * time)
        }
        let decay = dampingRatio * angularFrequency
        let dampedFrequency = angularFrequency * (1 - dampingRatio * dampingRatio).squareRoot()
        return 1 - exp(-decay * time) * (cos(dampedFrequency * time) + (decay - initialVelocity) / dampedFrequency * sin(dampedFrequency * time))
    }

    /// 見た目で区別できないほど1に近づき、動きを終えてよいか。
    public func isSettled(at time: TimeInterval) -> Bool {
        time >= duration && abs(1 - value(at: time)) < 0.001
            || time >= duration * 4
    }
}

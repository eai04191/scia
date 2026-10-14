public import Foundation

/// 0から1へ向かうばねの進み具合。UIKitの`UISpringTimingParameters(duration:bounce:)`と同じ定義で、初速は0。
///
/// 動いている途中で行き先が変わる動き（閉じる途中に一覧をスクロールされ、戻り先のサムネイルが動くなど）は、
/// UIKitのアニメーションでは行き先を決め直せないため、毎フレームこの進み具合で始点と今の行き先のあいだを補う。
public struct SpringCurve: Sendable, Equatable {
    /// 弾まない場合に、おおむね行き着くまでの時間。
    public let duration: TimeInterval
    /// 0で弾まずに止まり、大きいほど行き過ぎてから戻る。
    public let bounce: Double

    public init(duration: TimeInterval, bounce: Double) {
        precondition(duration > 0, "ばねの時間は正の値にします")
        precondition((0..<1).contains(bounce), "弾みは0以上1未満にします")
        self.duration = duration
        self.bounce = bounce
    }

    /// 経過時間`time`での進み具合。0から始まり、1に落ち着く。弾む場合は1を超えることがある。
    public func value(at time: TimeInterval) -> Double {
        guard time > 0 else { return 0 }
        let angularFrequency = 2 * Double.pi / duration
        let dampingRatio = 1 - bounce
        if dampingRatio >= 1 {
            return 1 - exp(-angularFrequency * time) * (1 + angularFrequency * time)
        }
        let decay = dampingRatio * angularFrequency
        let dampedFrequency = angularFrequency * (1 - dampingRatio * dampingRatio).squareRoot()
        return 1 - exp(-decay * time) * (cos(dampedFrequency * time) + decay / dampedFrequency * sin(dampedFrequency * time))
    }

    /// 見た目で区別できないほど1に近づき、動きを終えてよいか。
    public func isSettled(at time: TimeInterval) -> Bool {
        time >= duration && abs(1 - value(at: time)) < 0.001
            || time >= duration * 4
    }
}

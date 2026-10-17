/// ビューアの開閉で、画像の複製を一覧のバーの手前と奥のどちらに見せるか。
///
/// 複製は2枚ある。バーより手前に描く最前面の複製と、一覧の行の中に置いてバーの奥に描く一覧の中の複製。
/// サムネイルの位置ではバーの奥の見え方に、ビューアの画像の位置ではバーの手前の見え方にそろえるため、開閉の進み具合に合わせて2枚を入れ替える。
public struct MediaBarSwap: Sendable, Equatable {
    /// 一覧のバーに隠れない範囲での、最前面の複製から一覧の中の複製への受け渡しの度合い。0で最前面の複製だけ、1で一覧の中の複製だけを見せる。
    public var handoff: Double
    /// バーと重なる部分に、最前面の複製を見せる濃さ。0で一覧の中の複製だけ、1で最前面の複製だけを見せる。
    public var overlapOpacity: Double

    public init(handoff: Double, overlapOpacity: Double) {
        self.handoff = handoff
        self.overlapOpacity = overlapOpacity
    }

    /// 複製をすべてバーの手前に見せる。開ききったときや、指で動かしているとき。
    public static let front = MediaBarSwap(handoff: 0, overlapOpacity: 1)

    /// 閉じる動き。閉じ始めにバーと重なっていた部分を早めに奥へ入れ替え、着地の手前から一覧の中の複製へ受け渡す。
    /// - Parameters:
    ///   - progress: 閉じる動きの進み具合。0から1。
    ///   - handoffStart: 一覧の中の複製へ受け渡し始める進み具合。1なら着地の瞬間に切り替える。
    ///   - overlapFadeEnd: バーと重なっていた部分を奥へ入れ替え終える進み具合。
    ///   - startOverlapOpacity: 閉じ始めに、バーと重なっていた部分を手前に見せていた濃さ。開く途中から閉じたときは1未満になる。
    public static func closing(progress: Double, handoffStart: Double, overlapFadeEnd: Double, startOverlapOpacity: Double = 1) -> MediaBarSwap {
        let handoff = handoffStart < 1
            ? smoothstep((progress - handoffStart) / (1 - handoffStart))
            : (progress >= 1 ? 1 : 0)
        let fade = smoothstep(progress / max(overlapFadeEnd, 0.01))
        return MediaBarSwap(handoff: handoff, overlapOpacity: startOverlapOpacity * (1 - fade))
    }

    /// 開く動き。閉じる動きの逆で、サムネイルと同じバーの奥の見え方から始め、早めに最前面の複製へ受け渡し、
    /// ビューアの画像の位置に近づいてからバーと重なる部分を手前へ入れ替える。
    /// - Parameters:
    ///   - progress: 開く動きの進み具合。0から1。
    ///   - handoffEnd: 最前面の複製へ受け渡し終える進み具合。0なら開き始めから最前面の複製だけを見せる。
    ///   - overlapFadeStart: バーと重なる部分を手前へ入れ替え始める進み具合。
    public static func opening(progress: Double, handoffEnd: Double, overlapFadeStart: Double) -> MediaBarSwap {
        let handoff = handoffEnd > 0 ? 1 - smoothstep(progress / handoffEnd) : 0
        let overlapOpacity = overlapFadeStart < 1
            ? smoothstep((progress - overlapFadeStart) / (1 - overlapFadeStart))
            : (progress >= 1 ? 1 : 0)
        return MediaBarSwap(handoff: handoff, overlapOpacity: overlapOpacity)
    }

    /// `fraction`の割合だけ、すべてバーの手前に見せる状態へ近づける。開く途中でつかんだとき、指で動かす複製を手前へ寄せるために使う。
    public func converging(toFront fraction: Double) -> MediaBarSwap {
        let t = min(max(fraction, 0), 1)
        return MediaBarSwap(handoff: handoff * (1 - t), overlapOpacity: overlapOpacity + (1 - overlapOpacity) * t)
    }

    /// 0から1へなめらかに移る。範囲外は端の値にする。
    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

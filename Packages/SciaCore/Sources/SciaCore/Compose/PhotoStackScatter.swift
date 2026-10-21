/// 書いていない投稿欄のカプセルに重ねた写真1枚の置き方。1枚目の中心からのずらしと、回す角度。
public struct PhotoStackPlacement: Equatable, Sendable {
    /// 回す角度（度）。正の値で右回り。
    public var rotation: Double
    /// 1枚目の中心から横にずらす量（pt）。負の値で左。
    public var offsetX: Double
    /// 1枚目の中心から縦にずらす量（pt）。負の値で上。
    public var offsetY: Double

    public init(rotation: Double, offsetX: Double = 0, offsetY: Double = 0) {
        self.rotation = rotation
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

/// 投稿欄を勢いよく下げて閉じたときに、カプセルに重ねた写真を散らばらせる。
///
/// 整った置き方（正解）を基準に、閉じる速さに応じた幅の乱数を、角度とずらしに足す。閉じるたびに変わり、次に開くまでその形で残る。
/// ゆっくり閉じたときやタップで閉じたときは、正解の形のままにする。
/// 散らばったときは、必ず正解より広がって見えるようにする。向きを決めずに足すと、写真が中心へ寄ったり真っすぐに近づいたりして、正解より整って見えることがあるため。
/// - 角度は、どの写真も今傾いている向きへさらに傾ける
/// - 2枚目より下の写真のずらしは、下へと、1枚目から離れる横の向き（のぞいている側）へだけ足す。下げて閉じた勢いで滑ったように見せる
///
/// 散らばっても重ねが崩れないよう、次を保つ。
/// - 1枚目は動かさず、角度だけを変える
/// - 2枚目より下の写真は、正解でのぞいていた側（1枚目の左右）を変えず、1枚目の中心から少なくとも`minimumSideOffset`離す
/// - 2枚目より下の写真の、1枚目との角度の差は、正解での向きを変えず、少なくとも`minimumAngleGap`空ける。ほぼ同じ角度で並ぶと、縁がずれて見えるため
public enum PhotoStackScatter {
    /// 下の写真を1枚目の中心から離す最小の量（pt）。正解がこれより近ければ、正解の量にする。
    public static let minimumSideOffset = 1.5
    /// 下の写真と1枚目の角度の差の最小（度）。正解がこれより小さければ、正解の差にする。
    public static let minimumAngleGap = 3.0

    /// 閉じる速さ（pt/秒、下向きが正）を、散らばりの強さ（0から1）に変える。`minimumVelocity`以下なら0、`maximumVelocity`以上なら1。
    public static func intensity(velocity: Double, minimumVelocity: Double, maximumVelocity: Double) -> Double {
        guard maximumVelocity > minimumVelocity else { return velocity > minimumVelocity ? 1 : 0 }
        return min(max((velocity - minimumVelocity) / (maximumVelocity - minimumVelocity), 0), 1)
    }

    /// 正解の置き方`base`（先頭が1枚目）に、強さ`intensity`に応じた乱数を足す。
    /// - Parameters:
    ///   - maximumRotation: 強さ1のときに足す角度の最大（度）。
    ///   - maximumOffset: 強さ1のときに足すずらしの最大（pt）。
    public static func scatter(
        _ base: [PhotoStackPlacement],
        intensity: Double,
        maximumRotation: Double,
        maximumOffset: Double,
        using generator: inout some RandomNumberGenerator
    ) -> [PhotoStackPlacement] {
        guard intensity > 0, let front = base.first else { return base }
        let rotationRange = maximumRotation * intensity
        let offsetRange = maximumOffset * intensity
        var scattered = front
        scattered.rotation += outward(from: front.rotation, range: rotationRange, using: &generator)
        var result = [scattered]
        for placement in base.dropFirst() {
            var moved = placement
            moved.rotation = keepingGap(
                from: scattered.rotation,
                base: placement.rotation - front.rotation,
                proposed: placement.rotation + outward(from: placement.rotation, range: rotationRange, using: &generator) - scattered.rotation
            )
            moved.offsetX = keepingSide(base: placement.offsetX, proposed: placement.offsetX + outward(from: placement.offsetX, range: offsetRange, using: &generator))
            moved.offsetY = placement.offsetY + random(upTo: offsetRange, using: &generator)
            result.append(moved)
        }
        return result
    }

    /// 0から`range`までの乱数。
    private static func random(upTo range: Double, using generator: inout some RandomNumberGenerator) -> Double {
        guard range > 0 else { return 0 }
        return Double.random(in: 0...range, using: &generator)
    }

    /// `value`の向き（正なら正、負なら負）へ、0から`range`までの乱数。`value`が0なら、向きも乱数で決める。
    private static func outward(from value: Double, range: Double, using generator: inout some RandomNumberGenerator) -> Double {
        let amount = random(upTo: range, using: &generator)
        if value == 0 {
            return Bool.random(using: &generator) ? amount : -amount
        }
        return value > 0 ? amount : -amount
    }

    /// 1枚目の角度`front`との差を、正解の差`base`と同じ向きに保ち、最小の差を空けて、角度を返す。
    private static func keepingGap(from front: Double, base: Double, proposed: Double) -> Double {
        guard base != 0 else { return front + proposed }
        let minimum = min(minimumAngleGap, abs(base))
        let sign: Double = base > 0 ? 1 : -1
        return front + sign * max(proposed * sign, minimum)
    }

    /// 横のずらしを、正解と同じ側に保ち、1枚目の中心から最小の量だけ離す。
    private static func keepingSide(base: Double, proposed: Double) -> Double {
        guard base != 0 else { return proposed }
        let minimum = min(minimumSideOffset, abs(base))
        let sign: Double = base > 0 ? 1 : -1
        return sign * max(proposed * sign, minimum)
    }
}

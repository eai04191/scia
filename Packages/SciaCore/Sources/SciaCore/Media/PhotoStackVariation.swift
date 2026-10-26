/// 一覧で本文の右に重ねた写真の置き方を、投稿ごとに少しずつばらつかせる。どの投稿も同じ角度と重なりで並ぶと不自然なため。
///
/// 同じ投稿は、描き直しても、ブーストや通知の行、ほかのタブでも同じ形にするため、投稿のIDから決めた種で乱数を作る。
/// ばらつかせても、回す向き（角度の正負）とのぞかせる側（ずらす量の正負）は変えず、基準の値の半分より0に近づけない。
/// 基準の値が0なら、向きがないのでばらつかせない。角度を0にした写真は、まっすぐのままになる。
public enum PhotoStackVariation {
    /// 基準の置き方`base`（先頭が1枚目）を、`seed`から決まる量だけばらつかせる。1枚目のずらす量は使わないので変えない。
    /// - Parameters:
    ///   - maximumRotation: 角度に足す量の最大（度）。
    ///   - maximumOffset: ずらす量に足す量の最大。`base`のずらす量と同じ単位。
    public static func placements(_ base: [PhotoStackPlacement], seed: String, maximumRotation: Double, maximumOffset: Double) -> [PhotoStackPlacement] {
        var generator = SplitMix64(seed: hash(seed))
        return base.enumerated().map { index, placement in
            // 基準の値が0でも乱数は同じ数だけ引き、ほかの値のばらつきが基準の値によって変わらないようにする。
            let rotation = vary(placement.rotation, range: maximumRotation, using: &generator)
            let offsetX = vary(placement.offsetX, range: maximumOffset, using: &generator)
            let offsetY = vary(placement.offsetY, range: maximumOffset, using: &generator)
            return index == 0
                ? PhotoStackPlacement(rotation: rotation, offsetX: placement.offsetX, offsetY: placement.offsetY)
                : PhotoStackPlacement(rotation: rotation, offsetX: offsetX, offsetY: offsetY)
        }
    }

    /// `value`から`range`以内で、`value`と同じ向きのまま、`value`の半分より0に近づけない値。`value`が0なら0。
    private static func vary(_ value: Double, range: Double, using generator: inout SplitMix64) -> Double {
        let unit = Double.random(in: 0...1, using: &generator)
        guard value != 0, range > 0 else { return value }
        var lower = value - range
        var upper = value + range
        if value > 0 {
            lower = max(lower, value / 2)
        } else {
            upper = min(upper, value / 2)
        }
        return lower + (upper - lower) * unit
    }

    /// 文字列から種を作る（FNV-1a）。`String.hashValue`は起動のたびに変わるため使わない。
    private static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

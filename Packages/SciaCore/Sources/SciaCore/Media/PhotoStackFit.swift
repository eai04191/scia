public import CoreGraphics
import Foundation

/// 重ねた写真を、一辺`side`の正方形の中に、回した写真の角まで含めて収める大きさと位置。一覧で本文の右に添付ファイルを出すときに使う。
///
/// 写真を大きくすると、ずらす量も同じ比で大きくなるよう、ずらす量は写真の一辺に対する割合で受け取る。
/// 写真の大きさに比例して重なり全体が大きくなるので、一辺1の写真で重なりの幅と高さを測り、長いほうが`side`になるまで大きくする。
public struct PhotoStackFit: Equatable, Sendable {
    /// 写真の一辺（フチを含む）。
    public let photoSide: CGFloat
    /// 1枚目の写真の中心。正方形の左上を原点にする。重なり全体を正方形の真ん中に置く。
    public let frontCenter: CGPoint

    /// - Parameters:
    ///   - placements: 1枚目から順の置き方。ずらす量は写真の一辺に対する割合。1枚目のずらす量は使わない。
    ///   - count: 出す写真の数。`placements`の数より多い分は使わない。
    public init(placements: [PhotoStackPlacement], count: Int, side: CGFloat) {
        let side = max(side, 0)
        let shown = placements.prefix(max(count, 1)).enumerated().map { index, placement in
            (x: index == 0 ? 0 : placement.offsetX, y: index == 0 ? 0 : placement.offsetY, reach: Self.reach(rotation: placement.rotation))
        }
        let minX = shown.map { $0.x - $0.reach }.min() ?? -0.5
        let maxX = shown.map { $0.x + $0.reach }.max() ?? 0.5
        let minY = shown.map { $0.y - $0.reach }.min() ?? -0.5
        let maxY = shown.map { $0.y + $0.reach }.max() ?? 0.5
        let width = maxX - minX
        let height = maxY - minY
        let photoSide = side / max(width, height)
        self.photoSide = photoSide
        frontCenter = CGPoint(
            x: (side - width * photoSide) / 2 - minX * photoSide,
            y: (side - height * photoSide) / 2 - minY * photoSide
        )
    }

    /// 一辺1の写真を`rotation`度回したときの、中心から左右（上下も同じ）の端までの長さ。
    private static func reach(rotation: Double) -> Double {
        let radians = rotation * .pi / 180
        return 0.5 * (abs(cos(radians)) + abs(sin(radians)))
    }
}

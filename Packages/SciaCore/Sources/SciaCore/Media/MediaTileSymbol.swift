public import CoreGraphics

/// サムネイルの中央に置く印（動画の再生など）の大きさ。
///
/// 決まった大きさにすると、通知の小さなサムネイルでは印が画像をほとんど隠すため、タイルの短い辺に比例させる。
/// 大きなタイルで印ばかり目立たず、小さなタイルでも形が分かるよう、上限と下限で止める。
public enum MediaTileSymbol {
    /// - Parameters:
    ///   - tileSize: タイルの大きさ。
    ///   - ratio: 短い辺に対する印の大きさの比。
    ///   - range: 印の大きさの範囲（pt）。
    public static func pointSize(tileSize: CGSize, ratio: Double, range: ClosedRange<Double>) -> CGFloat {
        let side = Double(min(tileSize.width, tileSize.height))
        return CGFloat(min(max(side * ratio, range.lowerBound), range.upperBound).rounded())
    }
}

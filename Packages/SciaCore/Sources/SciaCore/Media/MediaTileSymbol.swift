public import CoreGraphics

/// サムネイルの中央に置くアイコン（動画の再生など）の大きさ。
///
/// 決まった大きさにすると、通知の小さなサムネイルではアイコンが画像をほとんど隠すため、タイルの短い辺に比例させる。
/// 大きなタイルでアイコンばかり目立たず、小さなタイルでも形が分かるよう、上限と下限で止める。
public enum MediaTileSymbol {
    /// - Parameters:
    ///   - tileSize: タイルの大きさ。
    ///   - ratio: 短い辺に対するアイコンの大きさの比。
    ///   - range: アイコンの大きさの範囲（pt）。
    public static func pointSize(tileSize: CGSize, ratio: Double, range: ClosedRange<Double>) -> CGFloat {
        let side = Double(min(tileSize.width, tileSize.height))
        return CGFloat(min(max(side * ratio, range.lowerBound), range.upperBound).rounded())
    }
}

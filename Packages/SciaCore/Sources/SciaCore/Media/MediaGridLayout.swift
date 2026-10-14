public import CoreGraphics

/// 投稿の添付ファイルを、一覧の行の中に並べる枠。
///
/// 高さは添付ファイルの情報だけで決め、画像が届いても変えない。行の高さが後から変わると、読んでいる位置がずれるため。
public struct MediaGridLayout: Equatable, Sendable {
    /// 一覧に並べる最大の数。超えた分は最後の枠に残りの数として出す。
    public static let maxTiles = 4
    /// 2つ以上を並べるときの、全体の幅と高さの比。
    static let gridAspectRatio = 16.0 / 9.0
    /// 大きさの分からない添付ファイルを1つだけ出すときの、幅と高さの比。
    static let fallbackAspectRatio = 16.0 / 9.0

    /// 全体の幅を高さで割った値。高さは幅だけで決まるため、幅に対する制約にできる。添付ファイルがなければnil。
    public let aspectRatio: Double?
    public let height: CGFloat
    /// 先頭から順に、添付ファイルを置く枠。左上が原点。
    public let frames: [CGRect]
    /// 枠が足りずに出していない数。
    public let hiddenCount: Int

    /// - Parameters:
    ///   - aspectRatios: 添付ファイルごとの幅と高さの比。分からなければnil。
    ///   - tallestAspectRatio: 1つだけ出すとき、これより縦長なものは上下を切り落とす。
    ///   - widestAspectRatio: 1つだけ出すとき、これより横長なものは左右を切り落とす。
    public init(aspectRatios: [Double?], width: CGFloat, spacing: CGFloat, tallestAspectRatio: Double, widestAspectRatio: Double) {
        let count = min(aspectRatios.count, Self.maxTiles)
        hiddenCount = aspectRatios.count - count
        switch count {
        case 0:
            aspectRatio = nil
            height = 0
            frames = []
        case 1:
            let ratio = min(max(aspectRatios[0] ?? Self.fallbackAspectRatio, tallestAspectRatio), widestAspectRatio)
            aspectRatio = ratio
            height = width / ratio
            frames = [CGRect(x: 0, y: 0, width: width, height: height)]
        default:
            aspectRatio = Self.gridAspectRatio
            height = width / Self.gridAspectRatio
            let half = (width - spacing) / 2
            let halfHeight = (height - spacing) / 2
            let right = half + spacing
            let lower = halfHeight + spacing
            frames = switch count {
            case 2: [
                CGRect(x: 0, y: 0, width: half, height: height),
                CGRect(x: right, y: 0, width: half, height: height),
            ]
            case 3: [
                CGRect(x: 0, y: 0, width: half, height: height),
                CGRect(x: right, y: 0, width: half, height: halfHeight),
                CGRect(x: right, y: lower, width: half, height: halfHeight),
            ]
            default: [
                CGRect(x: 0, y: 0, width: half, height: halfHeight),
                CGRect(x: right, y: 0, width: half, height: halfHeight),
                CGRect(x: 0, y: lower, width: half, height: halfHeight),
                CGRect(x: right, y: lower, width: half, height: halfHeight),
            ]
            }
        }
    }
}

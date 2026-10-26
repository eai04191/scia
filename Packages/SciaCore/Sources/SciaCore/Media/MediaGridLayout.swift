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

    /// 一辺`side`の正方形を、左から1列にすべて並べる。通知で投稿を控えめに再掲するときに使う。
    /// 行の幅に収まらない分は、置く側が横にスクロールして見せるため、数を切らない。
    public init(stripOf count: Int, side: CGFloat, spacing: CGFloat) {
        let shown = count
        hiddenCount = 0
        guard shown > 0 else {
            aspectRatio = nil
            height = 0
            frames = []
            return
        }
        let width = CGFloat(shown) * side + CGFloat(shown - 1) * spacing
        aspectRatio = width / side
        height = side
        frames = (0..<shown).map { CGRect(x: CGFloat($0) * (side + spacing), y: 0, width: side, height: side) }
    }

    /// 一辺`side`の正方形1つに、すべての添付ファイルをまとめて出す。本文の右に重ねて出すときに使う。
    /// 正方形の中での並べ方は置く側が決めるので、枠は正方形1つだけを返し、数も出さないので`hiddenCount`に数えない。
    public init(squareOf count: Int, side: CGFloat) {
        hiddenCount = 0
        guard count > 0 else {
            aspectRatio = nil
            height = 0
            frames = []
            return
        }
        let side = max(side, 0)
        aspectRatio = 1
        height = side
        frames = [CGRect(x: 0, y: 0, width: side, height: side)]
    }

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
            // すき間は設定で大きくできるので、並べる幅と高さに収める。収めないと、タイルの大きさが負になり、枠の外にはみ出す。
            let spacing = min(max(spacing, 0), width, height)
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

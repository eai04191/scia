public import CoreGraphics

/// 添付ファイルのビューアで、画像や動画を画面に収める大きさと置き場所。
/// 画面に収めるときは、画面の端の避ける範囲（アイランドなど）にかからないようにする。拡大して画面より大きくなったら、避ける範囲にも描く。
public enum MediaViewerFit {
    /// 画面の各辺から、画面に収めるときに避ける幅。
    public struct Edges: Equatable, Sendable {
        public var top: CGFloat
        public var left: CGFloat
        public var bottom: CGFloat
        public var right: CGFloat

        public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        public static let zero = Edges()
    }

    /// `contentSize`の中身を画面に収めるときに避ける、各辺の幅。`regions`は画面を覆う領域（アイランド、カメラ、ステータスバーなど）で、画面の座標。
    /// 収めた中身がかかる領域だけを避け、かからない領域は避けない。iPhone Duoの右上のステータスバーの帯のように辺の一部だけを覆う領域で、
    /// かからない横長や縦長の画像まで縮めないため。
    /// かかる領域は、上下左右のどの辺から避けるかを、中身がいちばん大きく残る辺にする（同じならそのために失う画面の広さが小さい辺）。
    /// 避けたあとに別の領域にかかれば、続けて避ける。重なる領域は1つにまとめてから選ぶ。
    public static func edges(for contentSize: CGSize, avoiding regions: [CGRect], in boundsSize: CGSize) -> Edges {
        let bounds = CGRect(origin: .zero, size: boundsSize)
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let rects = merged(regions.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 })
        var edges = Edges.zero
        for _ in rects {
            let fitted = frame(contentSize: contentSize, in: boundsSize, avoiding: edges)
            guard let rect = rects.first(where: { $0.intersection(fitted).width > 0.001 && $0.intersection(fitted).height > 0.001 }) else { break }
            var top = edges, bottom = edges, left = edges, right = edges
            top.top = max(edges.top, rect.maxY)
            bottom.bottom = max(edges.bottom, bounds.height - rect.minY)
            left.left = max(edges.left, rect.maxX)
            right.right = max(edges.right, bounds.width - rect.minX)
            let candidates = [
                (edges: bottom, lost: (bounds.height - rect.minY) * bounds.width),
                (edges: left, lost: rect.maxX * bounds.height),
                (edges: right, lost: (bounds.width - rect.minX) * bounds.height),
            ]
            edges = candidates.reduce((edges: top, lost: rect.maxY * bounds.width)) { best, candidate in
                let bestScale = scale(contentSize: contentSize, in: boundsSize, avoiding: best.edges)
                let candidateScale = scale(contentSize: contentSize, in: boundsSize, avoiding: candidate.edges)
                if abs(candidateScale - bestScale) > 0.0001 {
                    return candidateScale > bestScale ? candidate : best
                }
                return candidate.lost < best.lost ? candidate : best
            }.edges
        }
        return edges
    }

    /// 重なる枠を、両方を囲む枠にまとめる。まとめた枠がほかの枠と重なれば、続けてまとめる。
    private static func merged(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects {
            var current = rect
            while let index = result.firstIndex(where: { $0.intersects(current) }) {
                current = current.union(result.remove(at: index))
            }
            result.append(current)
        }
        return result
    }

    /// 縦横比を保って、避ける範囲を除いた中に収める倍率。
    public static func scale(contentSize: CGSize, in boundsSize: CGSize, avoiding edges: Edges) -> CGFloat {
        let width = max(boundsSize.width - edges.left - edges.right, 0)
        let height = max(boundsSize.height - edges.top - edges.bottom, 0)
        return min(width / contentSize.width, height / contentSize.height)
    }

    /// 収めた枠。画面の座標。
    public static func frame(contentSize: CGSize, in boundsSize: CGSize, avoiding edges: Edges) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return CGRect(origin: .zero, size: boundsSize) }
        let scale = scale(contentSize: contentSize, in: boundsSize, avoiding: edges)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let margins = margins(contentSize: size, in: boundsSize, avoiding: edges)
        return CGRect(origin: CGPoint(x: margins.left, y: margins.top), size: size)
    }

    /// 画面より小さい中身の、各辺から画面の端までの余白。スクロールビューの`contentInset`に使う。
    /// 避ける範囲を除いた中に収まる間は、画面の真ん中に置き、避ける範囲にかかる分だけずらす。
    /// 収まらないほど大きくなったら、はみ出した分を避ける範囲の幅の比で両側へ振り分け、拡大の途中で中身が跳ばないようにする。
    public static func margins(contentSize: CGSize, in boundsSize: CGSize, avoiding edges: Edges) -> Edges {
        let horizontal = axisMargins(content: contentSize.width, bounds: boundsSize.width, start: edges.left, end: edges.right)
        let vertical = axisMargins(content: contentSize.height, bounds: boundsSize.height, start: edges.top, end: edges.bottom)
        return Edges(top: vertical.start, left: horizontal.start, bottom: vertical.end, right: horizontal.end)
    }

    private static func axisMargins(content: CGFloat, bounds: CGFloat, start: CGFloat, end: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let free = bounds - content
        guard free > 0 else { return (0, 0) }
        let avoided = start + end
        let leading: CGFloat
        if free >= avoided {
            leading = min(max(free / 2, start), free - end)
        } else {
            leading = free * start / avoided
        }
        return (leading, free - leading)
    }
}

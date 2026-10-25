public import CoreGraphics

/// トリミングの画面で、枠に見えている画像の範囲。スクロールビューの倍率と位置から決まる。
/// ピンチとドラッグを使えないVoiceOverで、一段ずつ拡大縮小し、範囲を上下左右へ動かすために使う。
/// 枠はスクロールビューの見えている範囲の中の位置で、枠の外の余白は`contentInset`で空けている前提にする。
public struct CropViewport: Equatable, Sendable {
    public enum Direction: CaseIterable, Sendable {
        case up, down, left, right

        /// 操作の名前。範囲がどちらへ動くかで書く。
        public var actionName: String {
            switch self {
            case .up: "範囲を上へ"
            case .down: "範囲を下へ"
            case .left: "範囲を左へ"
            case .right: "範囲を右へ"
            }
        }
    }

    /// 一段の拡大縮小の倍率。
    public static let zoomStep: CGFloat = 1.25
    /// 一段で動かす量の、枠の幅か高さに対する割合。
    public static let moveFraction: CGFloat = 0.2

    public let box: CGRect
    public let imageSize: CGSize
    public let zoomScale: CGFloat
    public let contentOffset: CGPoint
    public let minimumZoomScale: CGFloat
    public let maximumZoomScale: CGFloat

    public init(box: CGRect, imageSize: CGSize, zoomScale: CGFloat, contentOffset: CGPoint, minimumZoomScale: CGFloat, maximumZoomScale: CGFloat) {
        self.box = box
        self.imageSize = imageSize
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
        self.minimumZoomScale = minimumZoomScale
        self.maximumZoomScale = maximumZoomScale
    }

    /// 枠に見えている範囲。画像の座標。
    public var visibleRect: CGRect {
        guard zoomScale > 0 else { return .zero }
        return CGRect(
            x: (contentOffset.x + box.minX) / zoomScale,
            y: (contentOffset.y + box.minY) / zoomScale,
            width: box.width / zoomScale,
            height: box.height / zoomScale
        )
    }

    /// 枠の中央に見えている、画像の中の点。
    public var centerInImage: CGPoint {
        CGPoint(x: visibleRect.midX, y: visibleRect.midY)
    }

    /// 倍率を`factor`倍にした範囲。枠の中央に見えている点を動かさず、上限と下限で止める。変わらなければnil。
    public func zoomed(by factor: CGFloat) -> CropViewport? {
        let scale = min(max(zoomScale * factor, minimumZoomScale), maximumZoomScale)
        guard abs(scale - zoomScale) > 0.0001 else { return nil }
        let center = centerInImage
        return with(zoomScale: scale, contentOffset: CGPoint(x: center.x * scale - box.midX, y: center.y * scale - box.midY))
    }

    /// 範囲を`direction`へ一段動かした範囲。画像の端で止める。動かなければnil。
    public func moved(_ direction: Direction) -> CropViewport? {
        let dx = box.width * Self.moveFraction, dy = box.height * Self.moveFraction
        let offset = switch direction {
        case .up: CGPoint(x: contentOffset.x, y: contentOffset.y - dy)
        case .down: CGPoint(x: contentOffset.x, y: contentOffset.y + dy)
        case .left: CGPoint(x: contentOffset.x - dx, y: contentOffset.y)
        case .right: CGPoint(x: contentOffset.x + dx, y: contentOffset.y)
        }
        let moved = with(zoomScale: zoomScale, contentOffset: offset)
        guard abs(moved.contentOffset.x - contentOffset.x) > 0.0001 || abs(moved.contentOffset.y - contentOffset.y) > 0.0001 else { return nil }
        return moved
    }

    /// 読み上げる値。一番小さい倍率からの拡大率と、範囲の中央の位置を、画像の幅と高さの割合で表す。
    public var accessibilityValue: String {
        let zoom = minimumZoomScale > 0 ? Int((zoomScale / minimumZoomScale * 100).rounded()) : 100
        let center = centerInImage
        let x = imageSize.width > 0 ? Int((center.x / imageSize.width * 100).rounded()) : 50
        let y = imageSize.height > 0 ? Int((center.y / imageSize.height * 100).rounded()) : 50
        return "拡大\(zoom)%、横\(x)%、縦\(y)%"
    }

    /// 倍率と位置を変え、画像が枠の外に出ないよう位置を画像の中に収めた範囲。
    private func with(zoomScale scale: CGFloat, contentOffset offset: CGPoint) -> CropViewport {
        let minX = -box.minX, maxX = max(imageSize.width * scale - box.maxX, minX)
        let minY = -box.minY, maxY = max(imageSize.height * scale - box.maxY, minY)
        return CropViewport(
            box: box,
            imageSize: imageSize,
            zoomScale: scale,
            contentOffset: CGPoint(x: min(max(offset.x, minX), maxX), y: min(max(offset.y, minY), maxY)),
            minimumZoomScale: minimumZoomScale,
            maximumZoomScale: maximumZoomScale
        )
    }
}

import Testing
import UIKit
@testable import Scia

@MainActor
struct ZoomingImageViewTests {
    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in }
    }

    /// 画面の中央に見えている点の、画像の中での位置。
    private func visibleCenter(of view: ZoomingImageView) throws -> CGPoint {
        let frame = try #require(view.imageFrame)
        return CGPoint(
            x: (view.contentOffset.x + view.bounds.width / 2 - frame.minX) / frame.width,
            y: (view.contentOffset.y + view.bounds.height / 2 - frame.minY) / frame.height
        )
    }

    /// サムネイルを拡大して見ている間に元の画像が届いても、倍率と見ている位置を保つ。
    @Test func replacingImageKeepsZoomAndVisiblePoint() throws {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.image = image(width: 400, height: 300)
        view.layoutIfNeeded()
        view.zoomScale = view.minimumZoomScale * 3
        view.contentOffset = CGPoint(x: 600, y: view.contentOffset.y + 50)
        let center = try visibleCenter(of: view)
        let width = try #require(view.imageFrame?.width)

        view.image = image(width: 1_600, height: 1_200)

        #expect(view.isZoomedIn)
        #expect(abs((view.imageFrame?.width ?? 0) - width) < 0.5)
        let after = try visibleCenter(of: view)
        #expect(abs(after.x - center.x) < 0.001)
        #expect(abs(after.y - center.y) < 0.001)
    }

    @Test func replacingImageWhileFittedStaysFitted() {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.image = image(width: 400, height: 300)
        view.layoutIfNeeded()

        view.image = image(width: 1_600, height: 1_200)

        #expect(!view.isZoomedIn)
        #expect(abs((view.imageFrame?.width ?? 0) - 400) < 0.5)
    }
}

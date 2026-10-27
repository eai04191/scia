import SciaTesting
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

    /// 一時的に小さい枠になっている間に画像が届き、レイアウトの前に元の大きさへ戻っても、戻った大きさに収める。
    /// 開く遷移の途中などで起き、小さい枠で決めた倍率のまま、画像が極端に小さく出ていた。
    @Test func fitsToRestoredBoundsWhenImageArrivesWhileTemporarilySmall() {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.image = image(width: 400, height: 300)
        view.layoutIfNeeded()

        view.frame = CGRect(x: 0, y: 0, width: 40, height: 80)
        view.image = image(width: 1_600, height: 1_200)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()

        #expect(abs((view.imageFrame?.width ?? 0) - 400) < 0.5)
    }

    /// 小さいプレースホルダーを出したあとで大きな画像へ差し替えても、画面に収める。
    /// プレースホルダーの最小倍率が1を超えていると、倍率を1に戻す操作が切り上げられ、画像が1/10ほどに縮んで出ていた。
    @Test func fitsToBoundsWhenReplacingPlaceholderWithLargeImage() {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.image = image(width: 32, height: 32)
        view.layoutIfNeeded()

        view.image = image(width: 1_600, height: 1_200)
        view.layoutIfNeeded()

        #expect(abs((view.imageFrame?.width ?? 0) - 400) < 0.5)
    }

    /// 元の大きさの分からない小さい画像が届いたら、画面に収めた大きさから等倍へ動かして縮める。
    /// 縮める途中の見えている枠は、動き始めでは画面に収めた枠のまま、行き着く先は等倍の枠にする。
    @Test func shrinksToNaturalSizeGraduallyWhenItBecomesKnown() throws {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let small = image(width: 100, height: 100)
        view.image = small
        view.layoutIfNeeded()
        let fitted = try #require(view.presentedImageFrame)
        #expect(abs(fitted.width - 400) < 0.5)

        view.setNaturalSize(small.size, duration: 0.3)

        #expect(abs((view.imageFrame?.width ?? 0) - 100) < 0.5, "等倍へ行き着きません: \(String(describing: view.imageFrame))")
        #expect(view.layer.animationKeys()?.isEmpty == false || view.subviews.contains { $0.layer.animationKeys()?.isEmpty == false }, "等倍へ1コマで縮めています")
    }

    /// 拡大して見ている間に元の大きさが分かっても、見ている大きさを変えない。
    @Test func keepsZoomWhenNaturalSizeBecomesKnownWhileZoomedIn() {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.image = image(width: 100, height: 100)
        view.layoutIfNeeded()
        view.zoomScale = view.minimumZoomScale * 2
        let width = view.imageFrame?.width ?? 0

        view.setNaturalSize(CGSize(width: 100, height: 100), duration: 0.3)

        #expect(abs((view.imageFrame?.width ?? 0) - width) < 0.5)
    }

    /// 等倍へ縮めている間に頼まれた処理は、縮め終えてから行う。重い処理を縮む動きに重ねて、止まって見えないようにするため。
    @Test func actionWaitsForShrinkToFinish() async throws {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let small = image(width: 100, height: 100)
        view.image = small
        view.layoutIfNeeded()
        var ran = false

        view.setNaturalSize(small.size, duration: 0.3)
        view.afterZoomAnimation { ran = true }

        #expect(!ran, "縮めている途中に行いました")
        try await waitUntil { ran }
    }

    /// 動いていなければ、頼まれた処理をすぐに行う。
    @Test func actionRunsImmediatelyWhenIdle() {
        let view = ZoomingImageView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.image = image(width: 100, height: 100)
        view.layoutIfNeeded()
        var ran = false

        view.afterZoomAnimation { ran = true }

        #expect(ran)
    }
}

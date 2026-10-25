import CoreGraphics
import SciaCore
import Testing

/// VoiceOverで切り抜く範囲を変える操作の計算。ピンチとドラッグの代わりに、一段ずつ拡大縮小し、範囲を動かす。
struct CropViewportTests {
    /// 枠は画面の(50, 100)から200×100。画像は1000×500で、枠いっぱいに収まる倍率0.2を下限にする。
    private func viewport(zoomScale: CGFloat = 0.4, contentOffset: CGPoint = CGPoint(x: 50, y: 0)) -> CropViewport {
        CropViewport(
            box: CGRect(x: 50, y: 100, width: 200, height: 100),
            imageSize: CGSize(width: 1000, height: 500),
            zoomScale: zoomScale,
            contentOffset: contentOffset,
            minimumZoomScale: 0.2,
            maximumZoomScale: 2
        )
    }

    /// 拡大と縮小は、枠の中央に見えている画像の点を動かさない。
    @Test func zoomKeepsTheCenterOfTheBox() throws {
        let start = viewport()
        let zoomed = try #require(start.zoomed(by: 1.5))

        #expect(abs(zoomed.zoomScale - 0.6) < 0.0001)
        #expect(abs(zoomed.centerInImage.x - start.centerInImage.x) < 0.0001)
        #expect(abs(zoomed.centerInImage.y - start.centerInImage.y) < 0.0001)
    }

    /// 倍率は上限と下限で止め、止まっていればそれ以上は変えない。縮めて画像の端が枠に入るときは、範囲を画像の中へ戻す。
    @Test func zoomStopsAtLimitsAndKeepsTheImageInTheBox() throws {
        #expect(viewport(zoomScale: 2).zoomed(by: 1.5) == nil)
        #expect(viewport(zoomScale: 0.2, contentOffset: CGPoint(x: -50, y: -100)).zoomed(by: 1 / 1.5) == nil)

        let shrunk = try #require(viewport(zoomScale: 0.4, contentOffset: CGPoint(x: -50, y: -100)).zoomed(by: 1 / 1.5))
        #expect(abs(shrunk.zoomScale - 0.4 / 1.5) < 0.0001)
        #expect(shrunk.visibleRect.minX >= -0.0001)
        #expect(shrunk.visibleRect.minY >= -0.0001)
    }

    /// 範囲は枠の幅か高さの5分の1ずつ動かし、画像の端で止める。端にいれば動かさない。
    @Test func moveStepsByAFifthAndStopsAtTheEdge() throws {
        let start = viewport()
        let right = try #require(start.moved(.right))
        #expect(abs(right.visibleRect.minX - (start.visibleRect.minX + start.visibleRect.width / 5)) < 0.0001)

        let atLeft = viewport(contentOffset: CGPoint(x: -40, y: 0))
        let left = try #require(atLeft.moved(.left))
        #expect(abs(left.visibleRect.minX) < 0.0001)
        #expect(left.moved(.left) == nil)
    }

    /// 読み上げる値は、一番小さい倍率からの拡大率と、範囲の中央の位置を、画像の幅と高さの割合で表す。
    @Test func accessibilityValueDescribesZoomAndPosition() {
        let centered = viewport(zoomScale: 0.4, contentOffset: CGPoint(x: 50, y: -50))
        #expect(centered.accessibilityValue == "拡大200%、横50%、縦50%")
    }
}

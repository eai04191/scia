import CoreGraphics
import Testing
@testable import SciaCore

struct MediaViewerFitTests {
    /// 縦向きのアイランドの機種の大きさ。上の62ptを避ける。
    private let screen = CGSize(width: 402, height: 874)
    private let island = MediaViewerFit.Edges(top: 62)

    /// 縦長の画像は、避ける範囲を除いた高さに収め、アイランドの下から画面の下端までに置く。
    @Test func tallImageStaysBelowIsland() {
        let frame = MediaViewerFit.frame(contentSize: CGSize(width: 1000, height: 3000), in: screen, avoiding: island)
        #expect(frame.minY == 62)
        #expect(frame.maxY == 874)
        #expect(abs(frame.height - 812) < 0.001)
    }

    /// 避ける範囲にかからない横長の画像は、これまでどおり画面の真ん中に置く。
    @Test func wideImageStaysCentered() {
        let frame = MediaViewerFit.frame(contentSize: CGSize(width: 2000, height: 1000), in: screen, avoiding: island)
        #expect(frame == CGRect(x: 0, y: 336.5, width: 402, height: 201))
    }

    /// 真ん中に置くとアイランドにかかる高さの画像は、かからないところまで下げる。
    @Test func pushesImageOutOfIsland() {
        let margins = MediaViewerFit.margins(contentSize: CGSize(width: 402, height: 780), in: screen, avoiding: island)
        #expect(margins.top == 62)
        #expect(margins.bottom == 32)
    }

    /// 拡大して避ける範囲まで広がるときは、収めたときの位置から画面の上端へ続けて動き、跳ばない。
    @Test func zoomingIntoAvoidedAreaIsContinuous() {
        let atFit = MediaViewerFit.margins(contentSize: CGSize(width: 402, height: 812), in: screen, avoiding: island)
        let slightlyLarger = MediaViewerFit.margins(contentSize: CGSize(width: 402, height: 812.1), in: screen, avoiding: island)
        let full = MediaViewerFit.margins(contentSize: CGSize(width: 402, height: 874), in: screen, avoiding: island)
        #expect(atFit.top == 62)
        #expect(abs(slightlyLarger.top - 61.9) < 0.001)
        #expect(full == .zero)
    }

    /// 画面より大きく拡大したら、避ける範囲にも描き、余白を付けない。
    @Test func largerThanScreenHasNoMargins() {
        let margins = MediaViewerFit.margins(contentSize: CGSize(width: 900, height: 2000), in: screen, avoiding: island)
        #expect(margins == .zero)
    }

    /// 横向きでは、左右の避ける範囲を除いた幅に収める。
    @Test func landscapeAvoidsSides() {
        let edges = MediaViewerFit.Edges(left: 62, right: 62)
        let frame = MediaViewerFit.frame(contentSize: CGSize(width: 1600, height: 900), in: CGSize(width: 874, height: 402), avoiding: edges)
        #expect(frame.minX >= 62)
        #expect(frame.maxX <= 874 - 62 + 0.001)
    }

    /// iPhone 16 Proの縦向きの予約領域（上端の横幅いっぱいの帯）。
    private let topBand = [CGRect(x: 0, y: 0, width: 402, height: 54)]
    /// 閉じたiPhone Duoの外側の画面（466×678pt）の予約領域。右上の隅のカメラと、それを含む右端のステータスバーの帯。
    private let duoScreen = CGSize(width: 466, height: 678)
    private let duoRegions = [CGRect(x: 399.67, y: 29.33, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: 174)]

    /// 縦長の画像は上端の帯にかかるので、上を避ける。
    @Test func tallImageAvoidsTopBand() {
        let edges = MediaViewerFit.edges(for: CGSize(width: 600, height: 2000), avoiding: topBand, in: screen)
        #expect(edges == MediaViewerFit.Edges(top: 54))
    }

    /// 真ん中に置いても帯にかからない横長の画像は、何も避けない。
    @Test func wideImageIgnoresTopBand() {
        let edges = MediaViewerFit.edges(for: CGSize(width: 1600, height: 900), avoiding: topBand, in: screen)
        #expect(edges == .zero)
    }

    /// 横向きで左端に沿った帯にかかる画像は、左を避ける。
    @Test func sideBandAvoidsThatSide() {
        let edges = MediaViewerFit.edges(for: CGSize(width: 3000, height: 1000), avoiding: [CGRect(x: 0, y: 0, width: 54, height: 402)], in: CGSize(width: 874, height: 402))
        #expect(edges == MediaViewerFit.Edges(left: 54))
    }

    /// Duoで、帯にかからない横長と縦長の画像は、画面いっぱいに収める。
    @Test func duoUsesFullScreenWhenClearOfRegions() {
        #expect(MediaViewerFit.edges(for: CGSize(width: 1600, height: 900), avoiding: duoRegions, in: duoScreen) == .zero)
        #expect(MediaViewerFit.edges(for: CGSize(width: 600, height: 2000), avoiding: duoRegions, in: duoScreen) == .zero)
    }

    /// Duoで帯にかかる正方形の画像は、右を避けると382pt角に縮むので、上を避けて466pt角のまま下へずらす。
    @Test func duoSquareMovesBelowBand() {
        let edges = MediaViewerFit.edges(for: CGSize(width: 1200, height: 1200), avoiding: duoRegions, in: duoScreen)
        #expect(edges == MediaViewerFit.Edges(top: 174))
        let frame = MediaViewerFit.frame(contentSize: CGSize(width: 1200, height: 1200), in: duoScreen, avoiding: edges)
        #expect(abs(frame.width - 466) < 0.001)
        #expect(frame.minY >= 174)
    }

    /// 画面の外にはみ出した部分は数えない。
    @Test func ignoresOutsideOfBounds() {
        let regions = [CGRect(x: -10, y: -20, width: 422, height: 74), CGRect(x: 500, y: 0, width: 10, height: 10)]
        #expect(MediaViewerFit.edges(for: CGSize(width: 600, height: 2000), avoiding: regions, in: screen) == MediaViewerFit.Edges(top: 54))
    }

    /// 拡大した横長の画像で代替テキストを書き始めると、見えている部分（画面との重なり）だけを縮めて収める。
    /// 画像全体の縦横比で避ける辺を決めると、帯にかからない判定になるが、見えている正方形の部分は上端まで届いて帯にかかる。
    @Test func visiblePartOfZoomedImageAvoidsTopBand() {
        let editable = CGSize(width: 402, height: 400)
        #expect(MediaViewerFit.edges(for: CGSize(width: 1608, height: 402), avoiding: topBand, in: editable) == .zero)
        let visible = CGRect(x: -603, y: 236, width: 1608, height: 402).intersection(CGRect(origin: .zero, size: screen)).size
        #expect(MediaViewerFit.edges(for: visible, avoiding: topBand, in: editable) == MediaViewerFit.Edges(top: 54))
    }
}

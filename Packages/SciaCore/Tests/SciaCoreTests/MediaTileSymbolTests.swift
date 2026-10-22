import CoreGraphics
import Testing
@testable import SciaCore

struct MediaTileSymbolTests {
    /// 短い辺に比例させ、範囲の外は上限と下限で止める。
    @Test(arguments: [
        (40.0, 40.0, 16.0),
        (44, 44, 18),
        (26, 26, 10),
        (10, 10, 10),
        (350, 200, 36),
        (60, 200, 24),
    ])
    func scalesWithShortSide(width: Double, height: Double, expected: Double) {
        let size = CGSize(width: width, height: height)
        #expect(MediaTileSymbol.pointSize(tileSize: size, ratio: 0.4, range: 10...36) == CGFloat(expected))
    }
}

import Testing
import UIKit
@testable import Scia

@MainActor
struct SettingsIconTests {
    /// 2/3で描くと見た目が一辺の2/3を超える記号は、ちょうど2/3に収まるまで縮める。
    @Test(arguments: ["camera.fill", "photo.fill", "textformat.size", "externaldrive.fill"])
    func wideSymbolShrinksToTwoThirds(name: String) throws {
        let side: CGFloat = 28
        let ratio = try #require(SettingsIcon.visualExtentRatio(of: name))
        try #require(ratio > 1)
        let size = SettingsIcon.glyphPointSize(side: side, systemImage: name)
        #expect(abs(size * ratio - side * 2 / 3) < 0.01)
    }

    /// 2/3で描いても見た目が2/3に収まる記号は、大きくも小さくもしない。
    @Test func smallSymbolKeepsTwoThirds() throws {
        let side: CGFloat = 28
        let ratio = try #require(SettingsIcon.visualExtentRatio(of: "hourglass"))
        try #require(ratio < 1)
        #expect(SettingsIcon.glyphPointSize(side: side, systemImage: "hourglass") == side * 2 / 3)
    }

    /// 記号がないときは、2/3の大きさで描く。
    @Test func missingSymbolKeepsTwoThirds() {
        let side: CGFloat = 28
        #expect(SettingsIcon.glyphPointSize(side: side, systemImage: "no.such.symbol") == side * 2 / 3)
    }
}

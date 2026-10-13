import SciaCore
import Testing
import UIKit
@testable import Scia

/// 先頭に新着を挿入したとき、読んでいる位置の投稿が画面上で動かないことを確かめる。
@MainActor
@Suite(.serialized)
struct ScrollAnchorTests {
    /// 画面の1ピクセル未満のずれは許容する。
    private var tolerance: CGFloat { 1 / max(UITraitCollection.current.displayScale, 1) }

    @Test(arguments: [1, 3, 20, 200], [0.0, 0.4, 1.0])
    func prependKeepsAnchorPosition(insertCount: Int, scrollFraction: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }

        harness.viewController.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: scrollFraction)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))

        harness.viewController.prependStatuses(StatusFactory.make(count: insertCount, startingAt: 1_000 + insertCount))

        let after = try #require(harness.windowMinY(of: anchor.id), "挿入後に基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }
}

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

    @Test(arguments: [0.0, 0.4, 1.0])
    func appendKeepsAnchorPosition(scrollFraction: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }

        harness.viewController.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: scrollFraction)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))

        harness.viewController.appendStatuses(StatusFactory.make(count: 40, startingAt: 940))

        let after = try #require(harness.windowMinY(of: anchor.id), "追加後に基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }

    @Test func changingParagraphSpacingKeepsAnchorPosition() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000).map { status in
            Status(
                id: status.id,
                createdAt: status.createdAt,
                account: status.account,
                content: "<p>一段落目</p><p>二段落目</p><p>三段落目</p>",
                spoilerText: "",
                url: nil
            )
        }
        harness.viewController.setStatuses(statuses)
        harness.scroll(toFraction: 0.4)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))
        let heightBefore = harness.collectionView.contentSize.height

        harness.tuning.setValue(24, for: TuningCatalog.paragraphSpacing)
        for _ in 0..<100 where harness.collectionView.contentSize.height == heightBefore {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.collectionView.contentSize.height > heightBefore, "段落間隔の変更が反映されていません")
        let after = try #require(harness.windowMinY(of: anchor.id), "描き直し後に基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }
}

import SciaCore
import Testing
import UIKit
@testable import Scia

/// 使う人の操作で行が消えるときは閉じる動きで消し、それ以外の更新では動かさずに読んでいる位置を保つことを確かめる。
@MainActor
@Suite(.serialized)
struct RemovalMotionTests {
    /// 画面の1ピクセル未満のずれは許容する。
    private var tolerance: CGFloat { 1 / max(UITraitCollection.current.displayScale, 1) }

    private func isAnimating(_ cell: UICollectionViewCell) -> Bool {
        !(cell.layer.animationKeys() ?? []).isEmpty
    }

    /// 消した行の下の行が、詰める動きで上がってくる。
    @Test(arguments: [0.0, 0.4])
    func removalByUserAnimatesRowsBelow(scrollFraction: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: scrollFraction)
        // 表示領域の上端にかかっている行の、次の行を消す。
        let ids = harness.viewController.displayedItemIDs
        let anchor = try #require(harness.viewController.currentAnchor())
        let anchorIndex = try #require(ids.firstIndex(of: anchor.id))
        let removed = ids[anchorIndex + 1]
        let below = ids[anchorIndex + 2]

        harness.viewController.setEntries(
            statuses.map(TimelineEntry.status).filter { $0.id != removed },
            animatesRemoval: true
        )

        let cell = try #require(harness.visibleCell(of: below))
        #expect(isAnimating(cell), "消した行の下の行が動いていません")
    }

    /// 使う人の操作によらない削除は、動かさずに読んでいる位置を保つ。
    @Test func removalNotByUserDoesNotAnimate() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0.4)
        // 表示領域の上端にかかっている行の、次の行を消す。
        let ids = harness.viewController.displayedItemIDs
        let anchor = try #require(harness.viewController.currentAnchor())
        let anchorIndex = try #require(ids.firstIndex(of: anchor.id))
        let removed = ids[anchorIndex + 1]
        let below = ids[anchorIndex + 2]

        harness.viewController.setEntries(statuses.map(TimelineEntry.status).filter { $0.id != removed })

        let cell = try #require(harness.visibleCell(of: below))
        #expect(!isAnimating(cell), "使う人の操作によらない削除で行が動きました")
    }

    /// 表示領域の上端より上の行が消えるときは、詰めると読んでいる行が上へずれるため、動かさずに位置を保つ。
    @Test func removalAboveVisibleTopKeepsAnchor() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0.4)
        let anchor = try #require(harness.viewController.currentAnchor())
        let anchorIndex = try #require(harness.viewController.displayedItemIDs.firstIndex(of: anchor.id))
        let removed = harness.viewController.displayedItemIDs[anchorIndex - 2]
        let before = try #require(harness.windowMinY(of: anchor.id))

        harness.viewController.setEntries(
            statuses.map(TimelineEntry.status).filter { $0.id != removed },
            animatesRemoval: true
        )

        let after = try #require(harness.windowMinY(of: anchor.id))
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
        let cell = try #require(harness.visibleCell(of: anchor.id))
        #expect(!isAnimating(cell), "上端より上の行が消えたときに行が動きました")
    }

    /// メニューを出している間に溜めた更新に、使う人の操作によらない変化が混ざっていたら、動かさずに位置を保つ。
    @Test func heldRemovalMixedWithOtherUpdateDoesNotAnimate() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0.4)
        let ids = harness.viewController.displayedItemIDs
        let anchor = try #require(harness.viewController.currentAnchor())
        let anchorIndex = try #require(ids.firstIndex(of: anchor.id))
        let streamed = ids[anchorIndex + 3]
        let removed = ids[anchorIndex + 1]
        let below = ids[anchorIndex + 2]

        harness.viewController.menuWillShow()
        let afterStream = statuses.map(TimelineEntry.status).filter { $0.id != streamed }
        harness.viewController.setEntries(afterStream)
        harness.viewController.setEntries(afterStream.filter { $0.id != removed }, animatesRemoval: true)
        harness.viewController.menuDidHide()

        let cell = try #require(harness.visibleCell(of: below))
        #expect(!isAnimating(cell), "操作によらない削除と混ざった更新で行が動きました")
    }

    /// 消すのと一緒に、残る行の中身が変わるときは、高さの変化で読んでいる行がずれうるため、動かさずに位置を保つ。
    @Test func removalWithContentChangeKeepsAnchor() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0.4)
        let ids = harness.viewController.displayedItemIDs
        let anchor = try #require(harness.viewController.currentAnchor())
        let anchorIndex = try #require(ids.firstIndex(of: anchor.id))
        let removed = ids[anchorIndex + 1]
        let before = try #require(harness.windowMinY(of: anchor.id))

        let entries: [TimelineEntry] = statuses.compactMap { status in
            let entry = TimelineEntry.status(status)
            guard entry.id != removed else { return nil }
            guard entry.id == anchor.id else { return entry }
            return .status(Status(
                id: status.id,
                createdAt: status.createdAt,
                account: status.account,
                content: String(repeating: "上端にかかっている行の本文が伸びる。", count: 10),
                spoilerText: "",
                url: nil
            ))
        }
        harness.viewController.setEntries(entries, animatesRemoval: true)

        let after = try #require(harness.windowMinY(of: anchor.id))
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
        let cell = try #require(harness.visibleCell(of: anchor.id))
        #expect(!isAnimating(cell), "中身が変わる行があるのに動きました")
    }
}

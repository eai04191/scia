import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// コンテキストメニューを出している間も、並びの更新と再描画はすぐ反映し、メニューの元になった行は追従で流さないことを確かめる。
/// スワイプのボタンを閉じる途中は、閉じ終えるまで並びを溜めることも確かめる。
@MainActor
@Suite(.scratch, .serialized, .failureState)
struct RowHoldTests {
    /// 最上部でメニューを出している間に届いた並びは、すぐ反映する。追従はせず、メニューの元になった行の位置を保つ。
    /// 新着を待たせないよう、メニューを出している間は、操作の最中と見なさない。閉じたあとも、追従には戻らない。
    @Test func entriesAreAppliedWhileMenuIsShownWithoutFollowing() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let existing = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let touched = try #require(harness.windowMinY(of: .status(existing[0].id)))

        harness.viewController.menuWillShow()
        #expect(!harness.viewController.isUserInteracting)
        let arrivals = StatusFactory.make(count: 3, startingAt: 1_003)
        harness.setStatuses(arrivals + existing)

        #expect(harness.viewController.displayedStatusIDs == (arrivals + existing).map(\.id))
        #expect(try abs(#require(harness.windowMinY(of: .status(existing[0].id))) - touched) < 0.5, "メニューの元になった行が動きました")

        harness.viewController.menuDidHide()

        #expect(try abs(#require(harness.windowMinY(of: .status(existing[0].id))) - touched) < 0.5, "閉じたあとに追従して行が動きました")
    }

    /// メニューを出している間に中身が変わった投稿は、閉じるのを待たずに再描画する。
    @Test func contentChangeIsRedrawnWhileMenuIsShown() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0)
        let id = TimelineViewController.ItemID.status(statuses[1].id)
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        harness.viewController.menuWillShow()
        let base = statuses[1]
        statuses[1] = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "<p>" + String(repeating: "伸びた本文。", count: 60) + "</p>", spoilerText: "", url: nil)
        harness.setStatuses(statuses)
        harness.collectionView.layoutIfNeeded()

        #expect(try #require(harness.visibleCell(of: id)?.bounds.height) > height, "メニューを出している間に再描画していません")
    }

    /// スワイプのボタンを閉じる途中の行は、閉じ終えるまで前の縦の位置に描かれるため、閉じ終えてから並びを変える。
    @Test func entriesAreAppliedAfterSwipeCloses() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let existing = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let cell = try #require(harness.visibleCell(of: .status(existing[2].id)))

        Self.startSwipeClose(on: cell)
        let arrivals = StatusFactory.make(count: 3, startingAt: 1_003)
        harness.setStatuses(arrivals + existing)
        harness.frames.step()

        #expect(harness.viewController.displayedStatusIDs == existing.map(\.id))

        Self.finishSwipeClose(on: cell)
        harness.frames.step()

        #expect(harness.viewController.displayedStatusIDs == (arrivals + existing).map(\.id))
    }

    /// 閉じ終えてから次のコマで溜めた分を反映するまでに届いた更新も、溜めた分より新しいものとして扱う。
    @Test func entriesArrivingBeforeSwipeCloseIsNoticedAreNotOverwritten() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let existing = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let cell = try #require(harness.visibleCell(of: .status(existing[2].id)))

        Self.startSwipeClose(on: cell)
        harness.setStatuses(StatusFactory.make(count: 3, startingAt: 1_003) + existing)
        Self.finishSwipeClose(on: cell)
        let latest = StatusFactory.make(count: 5, startingAt: 1_005) + existing
        harness.setStatuses(latest)
        harness.frames.step()

        #expect(harness.viewController.displayedStatusIDs == latest.map(\.id))
    }

    /// スワイプのボタンを閉じる途中に溜めた更新に、使う人の操作によらない変化が混ざっていたら、動かさずに位置を保つ。
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
        let swiped = try #require(harness.visibleCell(of: anchor.id))

        Self.startSwipeClose(on: swiped)
        let afterStream = statuses.map(TimelineEntry.status).filter { $0.id != streamed }
        harness.viewController.setEntries(afterStream)
        harness.viewController.setEntries(afterStream.filter { $0.id != removed }, animatesRemoval: true)
        Self.finishSwipeClose(on: swiped)
        harness.frames.step()

        #expect(harness.viewController.displayedItemIDs == afterStream.filter { $0.id != removed }.map(\.id))
        let cell = try #require(harness.visibleCell(of: below))
        #expect((cell.layer.animationKeys() ?? []).isEmpty, "操作によらない削除と混ざった更新で行が動きました")
    }

    private static let swipeCloseKey = "testSwipeClose"

    /// 行を横にずらした位置から戻す動きを始める。止めるまで終わらない長さにする。
    private static func startSwipeClose(on cell: UICollectionViewCell) {
        let closing = CABasicAnimation(keyPath: "position.x")
        closing.fromValue = cell.layer.position.x - 70
        closing.toValue = cell.layer.position.x
        closing.duration = 10_000
        cell.layer.add(closing, forKey: swipeCloseKey)
        CATransaction.flush()
    }

    private static func finishSwipeClose(on cell: UICollectionViewCell) {
        cell.layer.removeAnimation(forKey: swipeCloseKey)
        CATransaction.flush()
    }

    /// 本文のリンクのメニューは、セルのメニューと別の部品が出すため、同じように追従を止めることを確かめる。
    @Test func linkMenuStopsFollowingUntilItHides() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let existing = [Self.statusWithLink(number: 1_000)] + StatusFactory.make(count: 29, startingAt: 999)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let touched = try #require(harness.windowMinY(of: .status(existing[0].id)))
        let cell = try #require(harness.visibleCell(of: .status(existing[0].id)))
        let hitArea = try #require(Self.subviews(of: cell).compactMap { $0 as? LinkHitArea }.first)
        let interaction = try #require(hitArea.interactions.lazy.compactMap { $0 as? UIContextMenuInteraction }.first)
        let delegate = try #require(interaction.delegate)
        let configuration = UIContextMenuConfiguration()

        delegate.contextMenuInteraction?(interaction, willDisplayMenuFor: configuration, animator: nil)
        let arrivals = StatusFactory.make(count: 3, startingAt: 1_003)
        harness.setStatuses(arrivals + existing)

        #expect(harness.viewController.displayedStatusIDs == (arrivals + existing).map(\.id))
        #expect(try abs(#require(harness.windowMinY(of: .status(existing[0].id))) - touched) < 0.5, "メニューの元になった行が動きました")

        delegate.contextMenuInteraction?(interaction, willEndFor: configuration, animator: nil)

        #expect(try abs(#require(harness.windowMinY(of: .status(existing[0].id))) - touched) < 0.5, "閉じたあとに追従して行が動きました")
        #expect(!harness.viewController.isShowingMenu)
    }

    private static func statusWithLink(number: Int) -> Status {
        Status(
            id: String(format: "%018d", number),
            createdAt: Date(timeIntervalSince1970: TimeInterval(number)),
            account: Account(
                id: "1",
                username: "alice",
                acct: "alice",
                displayName: "Alice #\(number)",
                avatar: URL(string: "https://example.social/avatars/alice.png")
            ),
            content: #"<p>見て <a href="https://example.com/a">example.com/a</a></p>"#,
            spoilerText: "",
            url: nil
        )
    }

    private static func subviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    /// まとめて行う操作のために投稿を選んでいる間は、新着を入れずに溜め、選び終えたら1度だけ知らせることを確かめる。
    /// 新着で行がずれると、選択しようとした行を選択し損なうため。
    @Test func selectingPostsHoldsUntilSelectionEnds() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let existing = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.viewController.onBatchReblog = { _ in }
        harness.viewController.onBatchShare = { _ in }
        var settled = 0
        harness.viewController.onInteractionSettle = { settled += 1 }

        harness.viewController.beginPostSelection(with: .status(existing[0].id))
        #expect(harness.viewController.isUserInteracting)

        #expect(settled == 0)

        harness.viewController.endPostSelection()
        #expect(!harness.viewController.isUserInteracting)
        #expect(settled == 1)
    }
}

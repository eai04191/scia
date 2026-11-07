import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// コンテキストメニューを出している間は、タイムラインの並びを変えず、閉じてから反映することを確かめる。
/// メニューの元になった行が動くと、メニューと表示がずれるため。
@MainActor
@Suite(.scratch, .serialized)
struct RowHoldTests {
    @Test func entriesAreAppliedAfterMenuHides() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let existing = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let touched = try #require(harness.windowMinY(of: .status(existing[0].id)))
        var settled = 0
        harness.viewController.onInteractionSettle = { settled += 1 }

        harness.viewController.menuWillShow()
        let arrivals = StatusFactory.make(count: 3, startingAt: 1_003)
        harness.setStatuses(arrivals + existing)

        #expect(harness.viewController.displayedStatusIDs == existing.map(\.id))
        #expect(harness.windowMinY(of: .status(existing[0].id)) == touched)
        #expect(harness.viewController.isUserInteracting)

        harness.viewController.menuDidHide()

        #expect(harness.viewController.displayedStatusIDs == (arrivals + existing).map(\.id))
        #expect(!harness.viewController.isUserInteracting)
        #expect(settled == 1)
    }

    /// 本文のリンクのメニューは、セルのメニューと別の部品が出すため、同じように溜めることを確かめる。
    @Test func entriesAreAppliedAfterLinkMenuHides() throws {
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

        #expect(harness.viewController.displayedStatusIDs == existing.map(\.id))
        #expect(harness.windowMinY(of: .status(existing[0].id)) == touched)

        delegate.contextMenuInteraction?(interaction, willEndFor: configuration, animator: nil)

        #expect(harness.viewController.displayedStatusIDs == (arrivals + existing).map(\.id))
        #expect(!harness.viewController.isUserInteracting)
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
    /// 選んでいる間にメニューを閉じても知らせない。新着で行がずれると、押そうとした行を押し損なうため。
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

        harness.viewController.menuWillShow()
        harness.viewController.menuDidHide()
        #expect(harness.viewController.isUserInteracting)
        #expect(settled == 0)

        harness.viewController.endPostSelection()
        #expect(!harness.viewController.isUserInteracting)
        #expect(settled == 1)
    }

    @Test func hidingMenuTwiceAppliesOnce() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 30, startingAt: 1_000))
        var settled = 0
        harness.viewController.onInteractionSettle = { settled += 1 }

        harness.viewController.menuWillShow()
        harness.viewController.menuDidHide()
        harness.viewController.menuDidHide()

        #expect(settled == 1)
    }
}

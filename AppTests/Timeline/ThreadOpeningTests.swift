import SciaCore
import Testing
import UIKit
@testable import Scia

/// スレッドを開くとき、押した投稿を一覧で見えていた画面上の位置に置き、会話を読んで前後に並べても、その位置から動かさないことを確かめる。
@MainActor
@Suite(.serialized)
struct ThreadOpeningTests {
    /// 画面の1ピクセル未満のずれは許容する。
    private var tolerance: CGFloat { 1 / max(UITraitCollection.current.displayScale, 1) }

    private let focus = StatusFactory.make(count: 1, startingAt: 1_000)[0]
    private var focusID: TimelineViewController.ItemID { .status(focus.id) }

    /// `windowY`で押した投稿を開いたスレッド。押した投稿だけを並べ、画面に出す。
    private func openThread(atWindowY windowY: CGFloat) throws -> TimelineHarness {
        try TimelineHarness { [focus] viewController in
            viewController.threadFocusID = focus.id
            viewController.setEntries([.status(focus)])
            viewController.placeOnAppearing(.status(focus.id), atWindowY: windowY)
        }
    }

    /// 会話を読んだときの並び。祖先は古い順に上へ、返信は下へ並べる。
    private func loadContext(into harness: TimelineHarness, ancestorCount: Int) {
        let ancestors = StatusFactory.make(count: ancestorCount, startingAt: 900).reversed()
        let replies = StatusFactory.make(count: 5, startingAt: 1_100).reversed()
        harness.viewController.setEntries((ancestors + [focus] + replies).map(TimelineEntry.status), keeping: focusID)
        harness.viewController.releaseOpeningInset()
        harness.collectionView.layoutIfNeeded()
    }

    /// 祖先が押した位置より上に収まらないときは、押した投稿は動かない。
    /// 押した行の上端がバーの下に隠れていたとき（`windowY`が小さいとき）も、同じだけ隠れた位置に置く。
    @Test(arguments: [500.0, 300.0, 60.0])
    func focusStaysWhenAncestorsFillAbove(windowY: CGFloat) throws {
        let harness = try openThread(atWindowY: windowY)
        defer { harness.tearDown() }
        let opened = try #require(harness.windowMinY(of: focusID))
        #expect(abs(opened - windowY) <= tolerance, "開いた時点で押した投稿が\(opened - windowY)pt動きました")

        loadContext(into: harness, ancestorCount: 30)

        let loaded = try #require(harness.windowMinY(of: focusID), "読んだあとに押した投稿が画面外へ出ました")
        #expect(abs(loaded - windowY) <= tolerance, "読んだあとに押した投稿が\(loaded - windowY)pt動きました")
    }

    /// 祖先が押した位置より上に足りないときは、最上部まで動かして祖先を上端に置き、上の空きを詰める。
    @Test func closesGapAboveAncestors() async throws {
        let harness = try openThread(atWindowY: 500)
        defer { harness.tearDown() }

        loadContext(into: harness, ancestorCount: 1)
        try await harness.waitUntilScrollingToTopEnds()

        let inset = harness.collectionView.adjustedContentInset.top
        #expect(abs(harness.collectionView.contentOffset.y + inset) <= tolerance)
    }

    /// 押した投稿が返信なら、開いた時点では返信先がまだ並んでおらず札を出している。返信先がすぐ上に並んでも札を残し、行の高さを変えない。
    /// 札を消すと、読み終えた瞬間に名前と本文が札の1行分だけ上へ跳ねるため。押した投稿でない返信は、すぐ上が返信先なら札を出さない。
    @Test func focusKeepsReplyLabelWhenParentLoadsAbove() throws {
        let parent = StatusFactory.make(count: 1, startingAt: 900)[0]
        let reply = Status(
            id: focus.id,
            createdAt: focus.createdAt,
            account: focus.account,
            content: focus.content,
            spoilerText: "",
            url: nil,
            inReplyToId: parent.id,
            inReplyToAccountId: parent.account.id
        )
        let replyToFocus = Status(
            id: String(format: "%018d", 1_100),
            createdAt: focus.createdAt.addingTimeInterval(100),
            account: focus.account,
            content: "返信先がすぐ上にある返信",
            spoilerText: "",
            url: nil,
            inReplyToId: reply.id,
            inReplyToAccountId: reply.account.id
        )
        let harness = try TimelineHarness { viewController in
            viewController.threadFocusID = reply.id
            viewController.hidesReplyLabelBelowParent = true
            viewController.setEntries([.status(reply)])
            viewController.placeOnAppearing(.status(reply.id), atWindowY: 500)
        }
        defer { harness.tearDown() }
        let opened = try #require(harness.visibleCell(of: focusID))
        let openedHeight = opened.bounds.height
        #expect((opened.contentConfiguration as? PostContentConfiguration)?.context != nil)

        harness.viewController.setEntries([parent, reply, replyToFocus].map(TimelineEntry.status), keeping: focusID)
        harness.viewController.releaseOpeningInset()
        harness.collectionView.layoutIfNeeded()

        let loaded = try #require(harness.visibleCell(of: focusID))
        #expect((loaded.contentConfiguration as? PostContentConfiguration)?.context != nil, "押した投稿の札が消えました")
        #expect(abs(loaded.bounds.height - openedHeight) <= tolerance, "押した投稿の行の高さが\(loaded.bounds.height - openedHeight)pt変わりました")
        let other = try #require(harness.visibleCell(of: .status(replyToFocus.id)))
        #expect((other.contentConfiguration as? PostContentConfiguration)?.context == nil, "押した投稿でない返信に札が出ました")
    }
}

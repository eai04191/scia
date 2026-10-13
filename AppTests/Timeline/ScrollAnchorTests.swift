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
        harness.tuning.setValue(false, for: TuningCatalog.followsNewArrivalsAtTop)

        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: scrollFraction)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))

        harness.setStatuses(StatusFactory.make(count: insertCount, startingAt: 1_000 + insertCount) + existing)

        let after = try #require(harness.windowMinY(of: anchor.id), "挿入後に基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }

    @Test(arguments: [0.0, 0.4, 1.0])
    func appendKeepsAnchorPosition(scrollFraction: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }

        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: scrollFraction)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))

        harness.setStatuses(existing + StatusFactory.make(count: 40, startingAt: 940))

        let after = try #require(harness.windowMinY(of: anchor.id), "追加後に基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }

    @Test(arguments: [1, 20])
    func prependAtTopFollowsNewArrivals(insertCount: Int) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }

        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let inserted = StatusFactory.make(count: insertCount, startingAt: 1_000 + insertCount)

        harness.setStatuses(inserted + existing)

        #expect(harness.viewController.isAtTop)
        let newest = try #require(inserted.first)
        #expect(harness.viewController.currentAnchor()?.id == .status(newest.id))
    }

    @Test func visibleStatusesAreReportedAfterInsertion() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.tuning.setValue(false, for: TuningCatalog.followsNewArrivalsAtTop)
        var reported: [Status.ID] = []
        harness.viewController.onVisibleStatusesChange = { reported = $0 }

        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let visibleBefore = reported
        harness.setStatuses(StatusFactory.make(count: 5, startingAt: 1_005) + existing)

        #expect(!visibleBefore.isEmpty)
        #expect(Set(reported) == Set(visibleBefore), "位置を保った挿入で、見えている投稿が変わりました")
    }

    /// 切れていた間の投稿、ギャップ、切れる前の投稿の順に並べる。
    private func entriesWithGap(loadedInGap: [Status] = [], remainingGap: Bool = true) -> (entries: [TimelineEntry], gap: TimelineGap, above: Status, below: Status) {
        let newer = StatusFactory.make(count: 20, startingAt: 2_000)
        let older = StatusFactory.make(count: 60, startingAt: 1_000)
        // StatusFactoryのIDは数字の文字列なので、両端の投稿のIDでギャップを作れる。
        let gap = TimelineGap(newerID: newer[newer.count - 1].id, olderID: older[0].id)
        let gapEntries: [TimelineEntry] = remainingGap ? [.gap(gap)] : []
        let entries = newer.map(TimelineEntry.status) + gapEntries + loadedInGap.map(TimelineEntry.status) + older.map(TimelineEntry.status)
        return (entries, gap, newer[newer.count - 1], older[0])
    }

    /// 下から遡ってギャップを古い側から読むと、ギャップのすぐ下の投稿が画面上で動かない。
    @Test(arguments: [3, 40])
    func loadingGapFromOlderKeepsStatusBelowGap(loadedCount: Int) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let (entries, gap, _, below) = entriesWithGap()
        harness.viewController.setEntries(entries)
        try harness.scroll(to: .gap(gap.id), at: .top)
        let before = try #require(harness.windowMinY(of: .status(below.id)))

        let loaded = StatusFactory.make(count: loadedCount, startingAt: 1_500)
        harness.viewController.setEntries(entriesWithGap(loadedInGap: loaded).entries, keeping: .status(below.id))

        let after = try #require(harness.windowMinY(of: .status(below.id)), "読み込み後にギャップの下の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "ギャップの下の投稿が\(after - before)pt動きました")
    }

    /// 上から読み進めてギャップを新しい側から読むと、ギャップのすぐ上の投稿が画面上で動かない。
    @Test(arguments: [3, 40])
    func loadingGapFromNewerKeepsStatusAboveGap(loadedCount: Int) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let (entries, gap, above, _) = entriesWithGap()
        harness.viewController.setEntries(entries)
        try harness.scroll(to: .gap(gap.id), at: .bottom)
        let before = try #require(harness.windowMinY(of: .status(above.id)))

        let loaded = StatusFactory.make(count: loadedCount, startingAt: 1_500)
        harness.viewController.setEntries(entriesWithGap(loadedInGap: loaded, remainingGap: false).entries, keeping: .status(above.id))

        let after = try #require(harness.windowMinY(of: .status(above.id)), "読み込み後にギャップの上の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "ギャップの上の投稿が\(after - before)pt動きました")
    }

    /// 指で動かしていないときは、画面上の位置で向きを決める。上の方で近づいたギャップは、下の投稿に続く古い側から読ませる。
    /// 指で動かしたときの向きはパンの速度から取るため、ここでは確かめられず、シミュレーターで確かめる。
    @Test func gapApproachingInUpperHalfLoadsFromOlder() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var approached: [(String, TimelineStore.GapDirection)] = []
        harness.viewController.onGapApproach = { approached.append(($0, $1)) }
        let (entries, gap, _, _) = entriesWithGap()
        harness.viewController.setEntries(entries)
        harness.scroll(toFraction: 1)
        approached.removeAll()
        #expect(approached.isEmpty)

        try harness.scroll(to: .gap(gap.id), at: .top)

        #expect(approached.last?.0 == gap.id)
        #expect(approached.last?.1 == .fromOlder)
    }

    /// 下の方で近づいたギャップは、上の投稿に続く新しい側から読ませる。遠いうちは知らせない。
    @Test func gapApproachingInLowerHalfLoadsFromNewer() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.tuning.setValue(0, for: TuningCatalog.gapAutoLoadDistance)
        var approached: [(String, TimelineStore.GapDirection)] = []
        harness.viewController.onGapApproach = { approached.append(($0, $1)) }
        let newer = StatusFactory.make(count: 40, startingAt: 2_000)
        let older = StatusFactory.make(count: 60, startingAt: 1_000)
        let gap = TimelineGap(newerID: newer[newer.count - 1].id, olderID: older[0].id)
        harness.viewController.setEntries(newer.map(TimelineEntry.status) + [.gap(gap)] + older.map(TimelineEntry.status))
        #expect(approached.isEmpty, "まだ遠いギャップを知らせました")

        try harness.scroll(to: .gap(gap.id), at: .bottom)

        #expect(approached.last?.0 == gap.id)
        #expect(approached.last?.1 == .fromNewer)
    }

    /// 既読位置から読み始めるとき、その投稿が上端に来て、それより新しい投稿を見たとは報告しない。
    /// 下に1画面分の投稿がない位置は上端まで動かせないため対象にしない。既読位置より古いページも読むので、そうなるのはタイムラインの終端だけ。
    @Test(arguments: [0, 20, 45])
    func placingAtTopShowsItemAtVisibleTopWithoutReportingNewer(index: Int) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var reported: [[Status.ID]] = []
        harness.viewController.onVisibleStatusesChange = { reported.append($0) }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        let marker = statuses[index]

        harness.viewController.setEntries(statuses.map(TimelineEntry.status), placingAtTop: .status(marker.id))

        let newer = Set(statuses[..<index].map(\.id))
        #expect(reported.allSatisfy { newer.isDisjoint(with: $0) }, "既読位置より新しい投稿を見たと報告しました")
        let visibleTop = harness.collectionView.adjustedContentInset.top
        let markerY = try #require(harness.windowMinY(of: .status(marker.id)))
        #expect(abs(markerY - visibleTop) <= tolerance, "既読位置の投稿が上端にありません: \(markerY)")
    }

    /// 新着ボタンで最上部へ戻ると、上のセルの高さが見積もりから実寸へ変わっても、最上部まで届く。
    @Test func scrollingToNewestReachesTop() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 200, startingAt: 1_000))
        harness.scroll(toFraction: 1)

        harness.viewController.scrollToNewest()
        for _ in 0..<200 where !harness.viewController.isAtTop {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(harness.viewController.isAtTop, "最上部に届きませんでした: contentOffset.y=\(harness.collectionView.contentOffset.y)")
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
        harness.setStatuses(statuses)
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

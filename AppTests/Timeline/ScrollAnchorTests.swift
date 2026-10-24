import SciaCore
import SciaTesting
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
    func prependAtTopFollowsNewArrivals(insertCount: Int) async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }

        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let inserted = StatusFactory.make(count: insertCount, startingAt: 1_000 + insertCount)

        harness.setStatuses(inserted + existing)
        try await harness.waitUntilScrollingToTopEnds()

        #expect(harness.viewController.isAtTop)
        let newest = try #require(inserted.first)
        #expect(harness.viewController.currentAnchor()?.id == .status(newest.id))
    }

    /// 最上部で新着に追従するとき、アニメーションで挿入しても、終わった時点で最上部に新着が並んでいる。
    @Test(arguments: [true, false])
    func prependAtTopWithAnimationEndsAtTop(animates: Bool) async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.insertionMotion = animates ? .animated : .instant
        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let inserted = StatusFactory.make(count: 3, startingAt: 1_003)

        harness.setStatuses(inserted + existing)
        try await harness.waitUntilScrollingToTopEnds()

        #expect(harness.viewController.isAtTop, "最上部から外れました: contentOffset.y=\(harness.collectionView.contentOffset.y)")
        #expect(harness.viewController.currentAnchor()?.id == .status(inserted[0].id))
    }

    /// アニメーションで挿入するときは、行を足した瞬間はいままで最上部にあった投稿を同じ位置に残し、そこから最上部へ動く。
    /// 行が先に動いてから一覧が戻る2段の動きにしない。
    @Test(arguments: [1, 20])
    func animatedPrependAtTopStartsFromPreviousTopAndMovesUp(insertCount: Int) async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.insertionMotion = .animated
        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0)
        let previousTop = try #require(existing.first)
        let before = try #require(harness.windowMinY(of: .status(previousTop.id)))
        let inserted = StatusFactory.make(count: insertCount, startingAt: 1_000 + insertCount)

        harness.setStatuses(inserted + existing)

        let start = try #require(harness.windowMinY(of: .status(previousTop.id)), "挿入した直後に、それまで最上部にあった投稿が画面外へ出ました")
        #expect(abs(start - before) <= tolerance, "挿入した直後に、それまで最上部にあった投稿が\(start - before)pt動きました")
        #expect(harness.viewController.isScrollingToTop)
        // 上のセルが見積もりから実寸に変わると、スクロール位置は補正で戻ることがあるが、画面上の中身は動かない。
        // 見えている間の、それまで最上部にあった投稿の画面上の位置で、最上部へ向かって下がり続けることを確かめる。
        var previousY = start
        while harness.viewController.isScrollingToTop {
            harness.frames.step()
            guard let y = harness.windowMinY(of: .status(previousTop.id)) else { break }
            #expect(y >= previousY - tolerance, "最上部へ向かう途中で上へ戻りました: \(previousY) → \(y)")
            previousY = y
        }
        try await harness.waitUntilScrollingToTopEnds()

        #expect(harness.viewController.isAtTop, "最上部から外れました: contentOffset.y=\(harness.collectionView.contentOffset.y)")
        #expect(harness.viewController.currentAnchor()?.id == .status(inserted[0].id))
    }

    /// 最上部へ動かしている途中で指が触れたら、そこで止まり、それ以上は動かさない。
    @Test func touchWhileScrollingToNewestStops() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.tuning.setValue(1, for: TuningCatalog.scrollToTopDuration)
        harness.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: 0.4)
        let start = harness.collectionView.contentOffset.y

        harness.viewController.scrollToNewest()
        harness.frames.advance(by: 0.2)
        harness.viewController.scrollViewWillBeginDragging(harness.collectionView)
        let stopped = harness.collectionView.contentOffset.y
        harness.frames.advance(by: 0.3)

        #expect(stopped < start, "触れる前に動いていません")
        #expect(!harness.viewController.isScrollingToTop)
        #expect(harness.collectionView.contentOffset.y == stopped, "触れたあとも動きました")
        #expect(!harness.viewController.isAtTop)
    }

    /// 最上部より下で読んでいるときは、アニメーションの設定によらず、読んでいる位置を保つ。
    @Test func prependBelowTopKeepsAnchorEvenWhenAnimationIsOn() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.insertionMotion = .animated
        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: 0.4)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))

        harness.setStatuses(StatusFactory.make(count: 3, startingAt: 1_003) + existing)

        let after = try #require(harness.windowMinY(of: anchor.id))
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }

    /// 表示領域の上端にかかっている行が消え、別の行が先頭に入っても（まとめた通知が新着で一番上へ移るときなど）、
    /// 消えた行のすぐ下の行の位置を保つ。消えた行を基準にすると、基準がなくなって読んでいる行が流れる。
    @Test(arguments: [0.4, 1.0])
    func removingTopEdgeRowKeepsTheRowBelow(scrollFraction: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.tuning.setValue(false, for: TuningCatalog.followsNewArrivalsAtTop)
        let existing = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(existing)
        harness.scroll(toFraction: scrollFraction)
        let edge = try #require(harness.viewController.currentAnchor())
        let edgeIndex = try #require(existing.firstIndex { TimelineViewController.ItemID.status($0.id) == edge.id })
        let below = TimelineViewController.ItemID.status(existing[edgeIndex + 1].id)
        let before = try #require(harness.windowMinY(of: below))

        var moved = existing
        moved.remove(at: edgeIndex)
        harness.setStatuses(StatusFactory.make(count: 1, startingAt: 1_001) + moved)

        let after = try #require(harness.windowMinY(of: below), "消えた行の下の行が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "消えた行の下の行が\(after - before)pt動きました")
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

    /// 投稿欄のキーボードで下端を覆ったり外したりしても、読んでいる位置は動かない。
    /// 一覧の末尾までスクロールしているときは、覆いを外すと末尾が下端に合わせて下がるため、ここでは確かめない。
    @Test(arguments: [0.0, 0.4])
    func coveringBottomKeepsAnchorPosition(scrollFraction: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: scrollFraction)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))

        harness.viewController.setObscuredBottomHeight(400)
        let covered = try #require(harness.windowMinY(of: anchor.id))
        harness.viewController.setObscuredBottomHeight(0)
        let uncovered = try #require(harness.windowMinY(of: anchor.id))

        #expect(abs(covered - before) <= tolerance, "覆ったときに基準の投稿が\(covered - before)pt動きました")
        #expect(abs(uncovered - before) <= tolerance, "外したときに基準の投稿が\(uncovered - before)pt動きました")
    }

    /// 画面を読み込む前に覆う高さを渡しても、画面は読み込まない。読み込むと、投稿ボタンなどを付ける設定より先に画面ができてしまう。
    /// 渡した高さは、画面を読み込んだあとに反映する。
    @Test func coveringBeforeViewLoadsDoesNotLoadView() throws {
        let viewController = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline)

        viewController.setObscuredBottomHeight(400)

        #expect(!viewController.isViewLoaded)
    }

    /// キーボードの裏に隠れた投稿は、表示中として報告しない。通知を見ていないのに既読にしないため。
    @Test func coveredStatusesAreNotReportedAsVisible() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var reported: [Status.ID] = []
        harness.viewController.onVisibleStatusesChange = { reported = $0 }
        harness.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: 0)
        harness.viewController.reportVisibleItems()
        let uncovered = reported

        harness.viewController.setObscuredBottomHeight(500)

        #expect(!reported.isEmpty)
        #expect(reported.count < uncovered.count, "覆われた投稿も表示中として報告しました")
    }

    /// 返信先の札から、一覧にある返信先の投稿を、入力欄のすぐ上に出す。
    @Test func scrollingToStatusShowsItAboveCoveredBottom() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0)
        harness.viewController.setObscuredBottomHeight(400)
        let target = statuses[30]

        #expect(harness.viewController.scrollToStatus(target.id, animated: false))

        let cell = try #require(harness.visibleCell(of: .status(target.id)), "返信先の投稿が表示されていません")
        let frame = cell.convert(cell.bounds, to: harness.collectionView)
        let visibleBottom = harness.collectionView.bounds.maxY - harness.collectionView.adjustedContentInset.bottom
        #expect(abs(frame.maxY - visibleBottom) <= 1, "返信先の投稿の下端が、覆われていない領域の下端から\(frame.maxY - visibleBottom)pt離れています")
    }

    /// 最上部へ動かしている途中で返信先の札を押したら、返信先で止まり、最上部へ動かし直さない。
    @Test func scrollingToStatusCancelsScrollingToNewest() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0.4)
        let target = statuses[30]

        harness.viewController.scrollToNewest()
        harness.frames.advance(by: 0.05)
        #expect(harness.viewController.scrollToStatus(target.id))
        // 最上部へ動かすのをやめていれば、コマを送っても最上部へ戻らない。返信先へは、UIKitのスクロールのアニメーションで動く。
        harness.frames.advance(by: 1.5)
        try await waitUntil { harness.visibleCell(of: .status(target.id)) != nil }

        #expect(!harness.viewController.isAtTop, "返信先へ動いたあとで最上部へ戻りました")
        #expect(harness.visibleCell(of: .status(target.id)) != nil, "返信先の投稿が表示されていません")
    }

    /// 同じ投稿が、元の投稿とブーストの2か所に並んでいても、返信を選んだ方へ移る。
    @Test(arguments: [false, true])
    func scrollingToStatusPrefersChosenItemOverSameStatusElsewhere(choosesBoost: Bool) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        let original = statuses[40]
        let boost = Status(id: "000000000000005000", createdAt: original.createdAt, account: original.account, content: "", spoilerText: "", url: nil, reblog: original)
        statuses.insert(boost, at: 10)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0)
        harness.viewController.setObscuredBottomHeight(400)
        let chosen = choosesBoost ? boost : original

        #expect(harness.viewController.scrollToStatus(chosen.id, animated: false))

        let cell = try #require(harness.visibleCell(of: .status(chosen.id)), "選んだ方の投稿が表示されていません")
        let frame = cell.convert(cell.bounds, to: harness.collectionView)
        let visibleBottom = harness.collectionView.bounds.maxY - harness.collectionView.adjustedContentInset.bottom
        #expect(abs(frame.maxY - visibleBottom) <= 1, "選んだ方ではない投稿へ移りました")
    }

    /// ブーストから返信を選んでも、そのブーストが一覧になければ、元の投稿へ移る。
    @Test func scrollingToStatusFallsBackToDisplayedStatus() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0)
        let original = statuses[30]

        #expect(harness.viewController.scrollToStatus("000000000000005000", displayedID: original.id, animated: false))
        #expect(harness.visibleCell(of: .status(original.id)) != nil, "元の投稿が表示されていません")
    }

    @Test func scrollingToMissingStatusDoesNothing() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: 0)
        let offset = harness.collectionView.contentOffset

        #expect(!harness.viewController.scrollToStatus("1", animated: false))
        #expect(harness.collectionView.contentOffset == offset)
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
        try await harness.waitUntilScrollingToTopEnds()

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
        try await waitUntil { harness.collectionView.contentSize.height != heightBefore }

        #expect(harness.collectionView.contentSize.height > heightBefore, "段落間隔の変更が反映されていません")
        let after = try #require(harness.windowMinY(of: anchor.id), "描き直し後に基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }

    private func spoilerStatuses(count: Int) -> [Status] {
        StatusFactory.make(count: count, startingAt: 1_000).map {
            Status(id: $0.id, createdAt: $0.createdAt, account: $0.account, content: $0.content, spoilerText: "ネタバレ", url: nil)
        }
    }

    /// 注意書きの本文を開閉しても、押した行の上端は画面上で動かない。表示領域の上端にかかって一部が隠れた行でも同じ。
    @Test(arguments: [0.0, -40.0])
    func togglingSpoilerKeepsRowTop(offsetFromVisibleTop: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = spoilerStatuses(count: 60)
        harness.setStatuses(statuses)
        let target = statuses[20]
        try harness.scroll(to: .status(target.id), at: .top)
        harness.collectionView.contentOffset.y -= offsetFromVisibleTop
        harness.collectionView.layoutIfNeeded()
        let before = try #require(harness.windowMinY(of: .status(target.id)))
        let heightBefore = try #require(harness.visibleCell(of: .status(target.id))).bounds.height

        harness.viewController.toggleSpoiler(of: target)
        let opened = try #require(harness.windowMinY(of: .status(target.id)))
        let heightOpened = try #require(harness.visibleCell(of: .status(target.id))).bounds.height
        harness.viewController.toggleSpoiler(of: target)
        let closed = try #require(harness.windowMinY(of: .status(target.id)))

        #expect(heightOpened > heightBefore)
        #expect(abs(opened - before) <= tolerance, "開いたときに\(opened - before)pt動きました")
        #expect(abs(closed - before) <= tolerance, "閉じたときに\(closed - before)pt動きました")
    }

    /// 画面の中ほどの行を開いても、その上の行は動かない。
    @Test func togglingSpoilerInMiddleKeepsRowsAbove() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = spoilerStatuses(count: 60)
        harness.setStatuses(statuses)
        try harness.scroll(to: .status(statuses[20].id), at: .top)
        let above = statuses[20], target = statuses[22]
        let aboveBefore = try #require(harness.windowMinY(of: .status(above.id)))
        let targetBefore = try #require(harness.windowMinY(of: .status(target.id)))

        harness.viewController.toggleSpoiler(of: target)

        #expect(abs(try #require(harness.windowMinY(of: .status(above.id))) - aboveBefore) <= tolerance)
        #expect(abs(try #require(harness.windowMinY(of: .status(target.id))) - targetBefore) <= tolerance)
    }

    /// 同じ投稿のブーストが上に並んでいても、押した行は動かない。上の行も一緒に伸びるため、表示領域の上端の行を基準にするとずれる。
    @Test func togglingSpoilerKeepsTappedRowWhenSameStatusIsAbove() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = spoilerStatuses(count: 60)
        let original = statuses[22]
        let booster = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: original.account.avatar)
        let boost = Status(id: String(format: "%018d", 5_000), createdAt: original.createdAt, account: booster, content: "", spoilerText: "", url: nil, reblog: original)
        statuses.insert(boost, at: 20)
        harness.setStatuses(statuses)
        try harness.scroll(to: .status(boost.id), at: .top)
        let before = try #require(harness.windowMinY(of: .status(original.id)))

        harness.viewController.toggleSpoiler(of: original, keeping: .status(original.id))

        let after = try #require(harness.windowMinY(of: .status(original.id)), "開いたあとに押した行が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "押した行が\(after - before)pt動きました")
    }
}

import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// 長い本文を切って「続きを読む」で広げる。決まりは`docs/long-post.md`。
@MainActor
@Suite(.scratch, .serialized)
struct LongBodyTests {
    /// 1行ずつの段落を`lines`個並べた本文。既定の「投稿の見た目」では、32行を超えたら15行に切る。
    private static func content(lines: Int) -> String {
        (1...lines).map { "<p>\($0)行目</p>" }.joined()
    }

    private func long(_ base: Status, lines: Int = 40, quote: Quote? = nil) -> Status {
        Status(id: base.id, createdAt: base.createdAt, account: base.account, content: Self.content(lines: lines), spoilerText: "", url: nil, quote: quote)
    }

    private func post(in harness: TimelineHarness, of id: Status.ID) -> PostContentView? {
        harness.visibleCell(of: .status(id))?.contentView as? PostContentView
    }

    private func configuration(in harness: TimelineHarness, of id: Status.ID) -> PostContentConfiguration? {
        post(in: harness, of: id)?.configuration as? PostContentConfiguration
    }

    private func height(in harness: TimelineHarness, of id: Status.ID) -> CGFloat? {
        harness.visibleCell(of: .status(id))?.bounds.height
    }

    /// 切り始める行数を超えた本文だけを切る。ちょうど切り始める行数の本文は切らない。
    @Test func cutsOnlyBodiesLongerThanThreshold() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let longer = long(statuses[0], lines: 33)
        let exact = long(statuses[1], lines: 32)
        harness.setStatuses([longer, exact] + statuses.dropFirst(2))

        try harness.scroll(to: .status(longer.id), at: .top)
        #expect(post(in: harness, of: longer.id)?.postBody.isBodyTruncated == true)
        try harness.scroll(to: .status(exact.id), at: .top)
        #expect(post(in: harness, of: exact.id)?.postBody.isBodyTruncated == false)
    }

    /// 広げると全文になり、押した行の画面上の位置は動かず、下の行が下がる。
    @Test func expandingKeepsRowPositionAndPushesRowsBelow() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let status = long(statuses[1])
        let below = statuses[2]
        harness.setStatuses([statuses[0], status] + statuses.dropFirst(2))
        try harness.scroll(to: .status(status.id), at: .top)
        let y = try #require(harness.windowMinY(of: .status(status.id)))
        let belowY = try #require(harness.windowMinY(of: .status(below.id)))
        let cutHeight = try #require(height(in: harness, of: status.id))
        #expect(configuration(in: harness, of: status.id)?.bodyTruncation != nil)

        harness.viewController.expandBody(.status(status.id))

        #expect(configuration(in: harness, of: status.id)?.bodyTruncation == nil)
        #expect(post(in: harness, of: status.id)?.postBody.isBodyTruncated == false)
        // 位置を当て直す計算で、浮動小数の誤差だけずれる。
        #expect(abs(try #require(harness.windowMinY(of: .status(status.id))) - y) < 0.01)
        #expect(try #require(height(in: harness, of: status.id)) > cutHeight)
        if let newBelowY = harness.windowMinY(of: .status(below.id)) {
            #expect(newBelowY > belowY)
        }
    }

    /// 上端が表示領域より上にある行を広げても、その行の位置は動かない。
    @Test func expandingRowAboveVisibleTopKeepsItsPosition() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let status = long(statuses[1])
        harness.setStatuses([statuses[0], status] + statuses.dropFirst(2))
        try harness.scroll(to: .status(status.id), at: .top)
        harness.collectionView.contentOffset.y += 100
        let y = try #require(harness.windowMinY(of: .status(status.id)))

        harness.viewController.expandBody(.status(status.id))

        #expect(configuration(in: harness, of: status.id)?.bodyTruncation == nil)
        // 位置を当て直す計算で、浮動小数の誤差だけずれる。
        #expect(abs(try #require(harness.windowMinY(of: .status(status.id))) - y) < 0.01)
    }

    /// 広げたことは投稿ごとに覚え、同じ投稿のブーストの行も全文にする。
    @Test func expandingAlsoExpandsBoosts() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let original = long(statuses[1])
        let boost = Status(id: statuses[0].id, createdAt: statuses[0].createdAt, account: statuses[0].account, content: "", spoilerText: "", url: nil, reblog: original)
        harness.setStatuses([boost, original] + statuses.dropFirst(2))

        harness.viewController.expandBody(.status(original.id))

        #expect(configuration(in: harness, of: boost.id)?.bodyTruncation == nil)
    }

    /// 同じ投稿のブーストが上にも並んでいて一緒に伸びても、押した行の画面上の位置は動かない。
    @Test func expandingKeepsPressedRowWhenSamePostIsAbove() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let original = long(statuses[2])
        let boost = Status(id: statuses[1].id, createdAt: statuses[1].createdAt, account: statuses[1].account, content: "", spoilerText: "", url: nil, reblog: original)
        harness.setStatuses([statuses[0], boost, original] + statuses.dropFirst(3))
        try harness.scroll(to: .status(boost.id), at: .top)
        let y = try #require(harness.windowMinY(of: .status(original.id)))

        harness.viewController.expandBody(.status(original.id), keeping: .status(original.id))

        #expect(configuration(in: harness, of: boost.id)?.bodyTruncation == nil)
        // 位置を当て直す計算で、浮動小数の誤差だけずれる。
        #expect(abs(try #require(harness.windowMinY(of: .status(original.id))) - y) < 0.01)
    }

    /// 広げると、ほかのタイムラインにそろえるために、広げたあとの状態を知らせる。ほかのタイムラインから受け取ると、動かさずに全文にする。
    @Test func sharesExpansionWithOtherTimelines() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let status = long(statuses[0])
        harness.setStatuses([status] + statuses.dropFirst())
        var shared: (expansion: LongBodyExpansion, key: LongBodyExpansion.Key)?
        harness.viewController.onChangeLongBodyExpansion = { shared = ($0, $1) }
        harness.viewController.expandBody(.status("other"))
        let received = try #require(shared)
        #expect(received.key == .status("other"))
        #expect(received.expansion.isExpanded(.status("other")))
        #expect(configuration(in: harness, of: status.id)?.bodyTruncation != nil)

        var expansion = received.expansion
        expansion.expand(.status(status.id))
        harness.viewController.applyLongBodyExpansion(expansion, changed: .status(status.id))

        #expect(configuration(in: harness, of: status.id)?.bodyTruncation == nil)
    }

    /// スレッドの画面で開いている投稿と、注意書きのある投稿は切らない。
    @Test func keepsThreadFocusAndSpoilerBodiesWhole() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let focus = long(statuses[0])
        let base = long(statuses[1])
        let spoiler = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "ネタバレ", url: nil)
        harness.viewController.threadFocusID = focus.id
        harness.setStatuses([focus, spoiler] + statuses.dropFirst(2))

        #expect(configuration(in: harness, of: focus.id)?.bodyTruncation == nil)
        #expect(configuration(in: harness, of: spoiler.id)?.bodyTruncation == nil)
    }

    /// 引用元の本文も切り、外側の本文とは別に広げる。
    @Test func cutsQuotedBodySeparately() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let quoted = Status(id: "q1", createdAt: Date(timeIntervalSince1970: 0), account: statuses[5].account, content: Self.content(lines: 40), spoilerText: "", url: nil)
        let status = long(statuses[0], quote: Quote(state: "accepted", quotedStatus: quoted))
        harness.setStatuses([status] + statuses.dropFirst())
        #expect(configuration(in: harness, of: status.id)?.bodyTruncation != nil)
        #expect(configuration(in: harness, of: status.id)?.embed?.truncation != nil)

        harness.viewController.expandBody(.status(quoted.id))

        #expect(configuration(in: harness, of: status.id)?.bodyTruncation != nil)
        #expect(configuration(in: harness, of: status.id)?.embed?.truncation == nil)
    }

    /// 切った本文では「テキストを選択」をできず、広げるとできる。
    @Test func textSelectionNeedsWholeBody() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let status = long(statuses[0])
        harness.setStatuses([status] + statuses.dropFirst())
        try harness.scroll(to: .status(status.id), at: .top)
        #expect(post(in: harness, of: status.id)?.postBody.canSelectText == false)

        harness.viewController.expandBody(.status(status.id))

        #expect(post(in: harness, of: status.id)?.postBody.canSelectText == true)
    }
}

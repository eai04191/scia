import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 行の高さが変わる描き直しを、原因によらず、下の行ごと動かしてつなぐことを確かめる（docs/vision.mdの「タイムラインの動き」）。
@MainActor
@Suite(.scratch, .failureState)
struct RowResizeMotionTests {
    private func hasRowShift(_ view: UIView) -> Bool {
        view.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true
    }

    private func replacing(_ base: Status, content: String, spoilerText: String = "") -> Status {
        Status(id: base.id, createdAt: base.createdAt, account: base.account, content: content, spoilerText: spoilerText, url: nil)
    }

    /// 注意書きを開くと、下の行を元の位置から動かす。閉じると、なくなる本文の像を重ねて下の端から縮め、下の行が詰めてくる前に空きを見せない。
    /// 切り抜きの境は、行の下端ではなく、短いほうの中身の下の端にする。行の下端にすると、開き始めは余白だった部分に本文が1コマで見え、
    /// 閉じ始めは余白になる部分の本文が1コマで消える。
    @Test func togglingSpoilerShiftsRowsBelowAndConcealsShrink() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[10] = replacing(statuses[10], content: "<p>" + String(repeating: "注意書きの下の本文。", count: 20) + "</p>", spoilerText: "注意書き")
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        try harness.scroll(to: id, at: .centeredVertically)
        let closed = try #require(harness.visibleCell(of: id))
        let height = closed.bounds.height
        let contentBottom = height - (try #require(closed.contentView as? PostContentView)).rowBottomMargin

        harness.viewController.toggleSpoiler(of: statuses[10], keeping: id)

        #expect(try #require(harness.visibleCell(of: id)?.bounds.height) > height, "注意書きを開いても行が伸びていません")
        let grow = try #require(harness.visibleCell(of: id)?.layer.mask?.animation(forKey: "rowGrowth") as? CASpringAnimation)
        #expect(abs((grow.fromValue as? CGFloat ?? 0) - contentBottom) < 0.01, "閉じていたときの中身の下の端から切り抜いていません")
        #expect(try hasRowShift(#require(harness.visibleCell(of: below))), "開いたときに下の行を動かしていません")

        // 描かれる前の行は像を取れないため、描かれるのを待つ。
        try await waitUntil { harness.visibleCell(of: id)?.snapshotView(afterScreenUpdates: false) != nil }
        harness.viewController.toggleSpoiler(of: statuses[10], keeping: id)

        let cell = try #require(harness.visibleCell(of: id))
        #expect(abs(cell.bounds.height - height) < 0.5, "注意書きを閉じても行が縮んでいません")
        let mask = try #require(cell.subviews.lazy.compactMap { $0.layer.mask }.first { $0.animation(forKey: TimelineViewController.shrinkName) != nil }, "閉じたときに、なくなる本文の像を縮めていません")
        #expect(abs(mask.frame.minY - contentBottom) < 0.01, "閉じたあとの中身の下の端まで縮めていません")
    }

    /// 編集で本文が伸びた行も、その行の位置を保ち、下の行を元の位置から動かす。
    @Test func editedRowShiftsRowsBelow() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        try harness.scroll(to: id, at: .centeredVertically)
        let y = try #require(harness.windowMinY(of: id))
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        statuses[10] = replacing(statuses[10], content: "<p>" + String(repeating: "編集で伸びた本文。", count: 20) + "</p>")
        harness.setStatuses(statuses)

        #expect(try #require(harness.visibleCell(of: id)?.bounds.height) > height, "編集しても行が伸びていません")
        #expect(try abs(#require(harness.windowMinY(of: id)) - y) < 0.5, "編集した行が動きました")
        #expect(try hasRowShift(#require(harness.visibleCell(of: below))), "下の行を動かしていません")
    }
}

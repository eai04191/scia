import SciaCore
import Testing
import UIKit
@testable import Scia

/// セルの状態と、表示中の投稿の報告を確かめる。
@MainActor
@Suite(.serialized)
struct CellStateTests {
    /// 遠くから最上部へ戻ったときも、止まった時点で最上部の投稿を見たと報告する。
    /// スクロールの通知の時点では表示中のセルの一覧が前のフレームのままで、新着ボタンで遠くから戻ると、
    /// 最後の通知に最上部の投稿が入らないことがあるため。ここでは、レイアウトを確定させずに最上部へ跳んで止まった状態を作る。
    @Test func reportsTopStatusesWhenScrollStopsAfterJump() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 200, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 1)
        var reported: [Status.ID] = []
        harness.viewController.onVisibleStatusesChange = { reported = $0 }

        harness.collectionView.contentOffset.y = -harness.collectionView.adjustedContentInset.top
        harness.viewController.scrollViewDidEndScrollingAnimation(harness.collectionView)

        #expect(reported.contains(statuses[0].id), "最上部の投稿を見たと報告しませんでした: \(reported.prefix(3))")
    }

    /// アプリ内のSafariを全画面に広げている間は一覧が見えないため、流れ込んだ新着を見たと報告せず、中くらいの高さに戻したら報告する。
    @Test func reportsVisibleStatusesOnlyWhileNotCoveredByInAppBrowser() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 5, startingAt: 1_000)
        harness.setStatuses(statuses)
        var reported: [Status.ID] = []
        harness.viewController.onVisibleStatusesChange = { reported = $0 }

        harness.viewController.setCoveredByInAppBrowser(true)
        harness.viewController.reportVisibleItems()
        #expect(reported.isEmpty, "全画面のSafariで覆っている間に報告しました: \(reported.prefix(3))")

        harness.viewController.setCoveredByInAppBrowser(false)
        #expect(reported.contains(statuses[0].id), "覆いが外れたのに報告しませんでした")
    }

    /// 投稿にはまだ開く画面がないため、タップしても選んだ状態にしない。
    @Test func statusCellsAreNotSelectable() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 5, startingAt: 1_000))
        let indexPath = IndexPath(item: 0, section: 0)

        let delegate = try #require(harness.collectionView.delegate)
        #expect(delegate.collectionView?(harness.collectionView, shouldSelectItemAt: indexPath) == false)
        #expect(delegate.collectionView?(harness.collectionView, shouldHighlightItemAt: indexPath) == false)
    }
}

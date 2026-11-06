import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// セルの状態と、表示中の投稿の報告を確かめる。
@MainActor
@Suite(.scratch, .serialized)
struct CellStateTests {
    /// 遠くから最上部へ戻ったときも、止まった時点で最上部の投稿を見たと報告する。
    /// スクロールの通知の時点では表示中のセルのリストが前のフレームのままで、新着ボタンで遠くから戻ると、
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

    /// アプリ内のSafariを全画面に広げている間はタイムラインが見えないため、流れ込んだ新着を見たと報告せず、中くらいの高さに戻したら報告する。
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
        #expect(reported.contains(statuses[0].id), "覆われなくなったのに報告しませんでした")
    }

    /// ウィンドウが前面にない間は見ているとは限らないため、流れ込んだ新着を見たと報告しない。スクロールしたときと、前面に戻ったときは報告する。
    /// 既読位置はほかの端末と同期するため、前面にないMacで報告すると、iPhoneで読んでいない新着まで既読になる。
    @Test func reportsVisibleStatusesOnlyWhileWindowIsActive() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 5, startingAt: 1_000)
        harness.setStatuses(statuses)
        var reported: [Status.ID] = []
        harness.viewController.onVisibleStatusesChange = { reported = $0 }

        harness.viewController.setWindowInactive(true)
        harness.viewController.reportVisibleItems()
        #expect(reported.isEmpty, "ウィンドウが前面にない間に報告しました: \(reported.prefix(3))")

        harness.viewController.reportVisibleItems(byUser: true)
        #expect(reported.contains(statuses[0].id), "ウィンドウが前面にない間にスクロールしたのに報告しませんでした")

        reported = []
        harness.viewController.setWindowInactive(false)
        #expect(reported.contains(statuses[0].id), "前面に戻ったのに報告しませんでした")
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

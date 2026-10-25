import SciaCore
import Testing
import UIKit
@testable import Scia

/// 表示している間に端末の文字の大きさが変わったとき、読んでいる位置へ戻し終えるまで、通り過ぎた投稿を表示中として報告しない。
/// 端末の文字の大きさが変わると、UIKitは画面の外の行の高さを見積もりに戻して測り直し、一覧が一時的に別の場所を見せる。
/// そのときに見えた投稿を報告すると、読んでいない投稿まで既読になり、位置を戻しても既読は戻らない。
@MainActor
@Suite(.serialized)
struct ContentSizeChangeTests {
    @Test func doesNotReportRowsPassedWhileRestoringThePosition() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.window.traitOverrides.preferredContentSizeCategory = .large
        harness.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: 0.4)
        var reported: [[Status.ID]] = []
        harness.viewController.onVisibleStatusesChange = { reported.append($0) }

        NotificationCenter.default.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        // 測り直しで一覧が一時的に先へ動いたときに見える投稿は、報告しない。
        harness.scroll(toFraction: 0.8)
        harness.viewController.reportVisibleItems()
        #expect(reported.isEmpty)

        harness.window.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        harness.window.layoutIfNeeded()
        reported = []

        // 戻し終えたら、ふだんどおり報告する。
        harness.viewController.reportVisibleItems()
        #expect(!reported.isEmpty)
    }
}

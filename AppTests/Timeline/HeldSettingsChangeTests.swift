import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 見えていない一覧と、設定の画面が手前にある間の一覧は、設定が変わっても描き直さずに溜め、見えたときに1回だけ描き直す。
@MainActor
@Suite(.scratch, .serialized)
struct HeldSettingsChangeTests {
    private func bodyPointSize(_ harness: TimelineHarness, _ id: Status.ID) -> CGFloat? {
        let content = harness.visibleCell(of: .status(id))?.contentConfiguration as? PostContentConfiguration
        return (content?.body.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
    }

    @Test func shownTimelineAppliesChangeAtOnce() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 5, startingAt: 100)
        harness.setStatuses(statuses)
        let before = try #require(bodyPointSize(harness, statuses[0].id))

        harness.settings.setValue(3, for: AppearanceCatalog.bodyText)

        try await waitUntil { bodyPointSize(harness, statuses[0].id) != before }
        #expect(!harness.viewController.hasHeldSettingsChange)
    }

    @Test func heldChangeAppliesWhenReleased() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 5, startingAt: 100)
        harness.setStatuses(statuses)
        let before = try #require(bodyPointSize(harness, statuses[0].id))
        harness.viewController.holdsSettingsChanges = true

        harness.settings.setValue(3, for: AppearanceCatalog.bodyText)
        try await waitUntil { harness.viewController.hasHeldSettingsChange }
        #expect(bodyPointSize(harness, statuses[0].id) == before, "設定の画面が手前にあるのに描き直しました")

        harness.viewController.holdsSettingsChanges = false
        #expect(bodyPointSize(harness, statuses[0].id) != before, "設定の画面を閉じたのに描き直していません")
        #expect(!harness.viewController.hasHeldSettingsChange)
    }

    @Test func hiddenTimelineAppliesChangeWhenAppearing() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 5, startingAt: 100)
        harness.setStatuses(statuses)
        let before = try #require(bodyPointSize(harness, statuses[0].id))
        harness.navigation.pushViewController(UIViewController(), animated: false)
        harness.window.layoutIfNeeded()
        #expect(harness.viewController.view.window == nil)

        harness.settings.setValue(3, for: AppearanceCatalog.bodyText)
        try await waitUntil { harness.viewController.hasHeldSettingsChange }
        #expect(bodyPointSize(harness, statuses[0].id) == before, "見えていない一覧を描き直しました")

        harness.navigation.popViewController(animated: false)
        harness.window.layoutIfNeeded()
        #expect(bodyPointSize(harness, statuses[0].id) != before, "画面に戻ったのに描き直していません")
        #expect(!harness.viewController.hasHeldSettingsChange)
    }
}

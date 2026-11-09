import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.scratch, .serialized)
struct CrashQuarantineTimelineTests {
    private func makeGuard() -> PostCrashGuard {
        let crashGuard = PostCrashGuard(defaults: TestScratch.defaults("crash-guard"), build: "1")
        crashGuard.activate(accountID: "account")
        return crashGuard
    }

    private func item(_ harness: TimelineHarness, _ id: Status.ID) -> IndexPath? {
        harness.viewController.collectionView.indexPathsForVisibleItems.first { path in
            harness.viewController.collectionView.cellForItem(at: path).map { $0 === harness.visibleCell(of: .status(id)) } ?? false
        }
    }

    @Test func 隔離した投稿は読めない行になりIDは保つ() throws {
        let crashGuard = makeGuard()
        let statuses = StatusFactory.make(count: 5, startingAt: 1_000)
        crashGuard.quarantineForTesting(statuses[2].id)
        let harness = try TimelineHarness(crashGuard: crashGuard)
        defer { harness.tearDown() }
        harness.setStatuses(statuses)
        let quarantined = try #require(harness.visibleCell(of: .status(statuses[2].id)) as? TimelineCell)
        #expect(quarantined.contentConfiguration is UIListContentConfiguration)
        #expect(quarantined.crashMarkID == nil)
        let other = try #require(harness.visibleCell(of: .status(statuses[1].id)) as? TimelineCell)
        #expect(!(other.contentConfiguration is UIListContentConfiguration))
        #expect(other.crashMarkID == statuses[1].id)
    }

    @Test func タップすると送る内容の画面を開く() throws {
        let crashGuard = makeGuard()
        let statuses = StatusFactory.make(count: 5, startingAt: 1_000)
        crashGuard.quarantineForTesting(statuses[2].id)
        var opened: Status.ID?
        let harness = try TimelineHarness(crashGuard: crashGuard)
        defer { harness.tearDown() }
        harness.notices.openCrashReport = { opened = $0 }
        harness.setStatuses(statuses)
        let collectionView = harness.viewController.collectionView
        let path = try #require(item(harness, statuses[2].id))
        #expect(harness.viewController.collectionView(collectionView, shouldSelectItemAt: path))
        harness.viewController.collectionView(collectionView, didSelectItemAt: path)
        #expect(opened == statuses[2].id)
    }

    @Test func ブーストは元の投稿のIDで見る() {
        let status = StatusFactory.make(count: 1, startingAt: 1_000)[0]
        #expect(TimelineEntry.status(status).quarantinableStatusID == status.displayed.id)
    }
}

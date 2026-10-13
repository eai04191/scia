import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.serialized)
struct TimelineContentTests {
    @Test func setStatusesReflectsChangedContentOfSameID() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let original = StatusFactory.make(count: 5, startingAt: 100)
        harness.viewController.setStatuses(original)

        let edited = original.map { status in
            Status(
                id: status.id,
                createdAt: status.createdAt,
                account: status.account,
                content: "編集後: \(status.id)",
                spoilerText: status.spoilerText,
                url: status.url
            )
        }
        harness.viewController.setStatuses(edited)

        let firstID = try #require(edited.first?.id)
        #expect(harness.secondaryText(of: firstID) == "編集後: \(firstID)")
    }
}

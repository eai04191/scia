import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 新着ボタンの出し入れ。`isHidden`は動かないため、濃さで出し入れし、消え終えてから隠す。
@Suite(.scratch)
@MainActor
struct NewArrivalsButtonTests {
    private func button(in harness: TimelineHarness) throws -> UIButton {
        try #require(harness.viewController.view.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel?.hasSuffix("の新着") == true })
    }

    /// 出すときは、見えるようにして、濃くする向きにする。
    @Test func showsWhenThereAreArrivals() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }

        harness.viewController.setUnreadCount(3)
        let button = try button(in: harness)

        #expect(!button.isHidden)
        #expect(button.alpha == 1)
        #expect(button.isUserInteractionEnabled)
    }

    /// 消すときは、すぐには隠さず、薄くする向きにする。すぐ隠すと1コマで消えるため。隠すのは薄くし終えてから。
    @Test func staysVisibleWhileFadingOut() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.setUnreadCount(3)
        let button = try button(in: harness)

        harness.viewController.setUnreadCount(0)

        #expect(!button.isHidden)
        #expect(button.alpha == 0)
        #expect(!button.isUserInteractionEnabled)
    }
}

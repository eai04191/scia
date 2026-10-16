import SciaCore
import Testing
import UIKit
@testable import Scia

/// タイムラインの上のボタンの列の下に出す知らせ。決まりはdocs/notices.mdの「チップ」と「置き場所」にある。
@MainActor
struct TimelineNoticeTests {
    private let failure = Notice.interactionFailure(title: "お気に入りを変更できませんでした") {}

    private func chipMinY(in harness: TimelineHarness) throws -> CGFloat {
        let chip = try #require(harness.viewController.noticeStack.chips.first)
        harness.viewController.view.layoutIfNeeded()
        return chip.convert(chip.bounds, to: nil).minY
    }

    /// 新着のボタンが出たら、その下へ動き、消えたら戻る。
    @Test func chipFollowsNewArrivalsButton() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)
        let alone = try chipMinY(in: harness)

        harness.viewController.setUnreadCount(5)
        let belowButton = try chipMinY(in: harness)
        #expect(belowButton > alone + 20)

        harness.viewController.setUnreadCount(0)
        #expect(try chipMinY(in: harness) == alone)
    }

    /// 指が触れている間（VoiceOverの読み上げ位置が乗っている間も）は、新着のボタンが出ても動かさず、離したら動かす。
    @Test func heldChipStaysUntilReleased() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)
        let before = try chipMinY(in: harness)
        let chip = try #require(harness.viewController.noticeStack.chips.first)

        chip.accessibilityElementDidBecomeFocused()
        harness.viewController.setUnreadCount(5)
        #expect(try chipMinY(in: harness) == before)

        chip.accessibilityElementDidLoseFocus()
        #expect(try chipMinY(in: harness) > before + 20)
    }

    /// 新着のボタンが出て動いている途中に触れたら、その場で止めて留める。
    @Test func chipStopsWhereItIsWhenHeldWhileMoving() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.tuning.setValue(1, for: TuningCatalog.noticeAnimationDuration)
        let viewController = harness.viewController
        viewController.showNotice(failure)
        let start = try chipMinY(in: harness)
        let chip = try #require(viewController.noticeStack.chips.first)

        viewController.setUnreadCount(5)
        viewController.view.layoutIfNeeded()
        let end = try chipMinY(in: harness)
        try await Task.sleep(for: .milliseconds(200))
        let shown = try #require(viewController.noticeStack.layer.presentation()?.position.y)
        chip.accessibilityElementDidBecomeFocused()
        viewController.view.layoutIfNeeded()

        #expect(viewController.noticeStack.layer.animationKeys()?.isEmpty ?? true)
        let held = viewController.noticeStack.center.y
        #expect(abs(held - shown) < 1)
        let heldMinY = try chipMinY(in: harness)
        #expect(heldMinY > start && heldMinY < end)
    }
}

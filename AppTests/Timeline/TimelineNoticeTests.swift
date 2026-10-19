import SciaCore
import Testing
import UIKit
@testable import Scia

/// ウインドウに重ねたチップの列の置き場所。決まりはdocs/notices.mdの「チップ」と「置き場所」にある。
@MainActor
struct TimelineNoticeTests {
    private let failure = Notice.interactionFailure(title: "お気に入りを変更できませんでした") {}

    private func chipMinY(in harness: TimelineHarness) throws -> CGFloat {
        let chip = try #require(harness.overlay.column.stack.chips.first)
        harness.window.layoutIfNeeded()
        return chip.convert(chip.bounds, to: nil).minY
    }

    /// 一覧ではナビゲーションバーのすぐ下に置く。
    @Test func chipSitsBelowNavigationBar() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)

        let navigationBar = try #require(harness.viewController.navigationController?.navigationBar)
        let barBottom = navigationBar.convert(navigationBar.bounds, to: nil).maxY
        #expect(try abs(chipMinY(in: harness) - (barBottom + 8)) < 1)
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
        let chip = try #require(harness.overlay.column.stack.chips.first)

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
        let column = harness.overlay.column
        harness.viewController.showNotice(failure)
        let start = try chipMinY(in: harness)
        let chip = try #require(column.stack.chips.first)

        harness.viewController.setUnreadCount(5)
        let end = try chipMinY(in: harness)
        try await Task.sleep(for: .milliseconds(200))
        let shown = try #require(column.layer.presentation()?.position.y)
        chip.accessibilityElementDidBecomeFocused()

        #expect(column.layer.animationKeys()?.isEmpty ?? true)
        #expect(abs(column.center.y - shown) < 1)
        let heldMinY = try chipMinY(in: harness)
        #expect(heldMinY > start && heldMinY < end)
    }

    /// 一番上から引っぱったら、引っぱった分だけ列も下げる。ストリーミングの状態の表示を覆わないため。
    @Test func pullingDownMovesChipWithList() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 20, startingAt: 1000))
        harness.viewController.showNotice(failure)
        let before = try chipMinY(in: harness)

        let collectionView = harness.collectionView
        collectionView.contentOffset.y = -collectionView.adjustedContentInset.top - 50

        #expect(try abs(chipMinY(in: harness) - (before + 50)) < 1)
    }

    /// ログインし直しの段は列の一番上に出し、チップはその下へ動かす。押すとログインし直しを始める。
    @Test func reauthenticationRowSitsAboveChips() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)
        let before = try chipMinY(in: harness)
        var started = 0

        harness.notices.reauthentication = NoticeCenter.Reauthentication(handle: "@alice@example.social") { started += 1 }

        let button = harness.overlay.column.reauthenticationButton
        harness.window.layoutIfNeeded()
        #expect(abs(button.convert(button.bounds, to: nil).minY - before) < 1)
        #expect(try chipMinY(in: harness) > before + button.bounds.height)
        #expect(button.configuration?.subtitle == "@alice@example.social")
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        #expect(harness.window.hitTest(center, with: nil) === button)
        button.sendActions(for: .primaryActionTriggered)
        #expect(started == 1)
    }

    /// チップに触れている間にログインし直しの段が出ても、チップは動かさず、離したら段の下へ動かす。
    @Test func heldChipStaysWhenReauthenticationAppears() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)
        let before = try chipMinY(in: harness)
        let chip = try #require(harness.overlay.column.stack.chips.first)

        chip.accessibilityElementDidBecomeFocused()
        harness.notices.reauthentication = NoticeCenter.Reauthentication(handle: "@alice@example.social") {}
        #expect(try chipMinY(in: harness) == before)

        chip.accessibilityElementDidLoseFocus()
        let button = harness.overlay.column.reauthenticationButton
        #expect(try chipMinY(in: harness) > before + button.bounds.height)
    }

    /// チップを押して出すものは、押した時点のウインドウのいちばん手前の画面に出す。出した時点の画面が閉じていても出せるようにするため。
    @Test func noticePresenterIsResolvedWhenTapped() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let context = NoticeContext(viewer: nil, window: harness.window)
        let navigation = try #require(harness.viewController.navigationController)
        #expect(context.presenter === navigation)

        let sheet = UIViewController()
        harness.viewController.present(sheet, animated: false)
        defer { sheet.dismiss(animated: false) }
        #expect(context.presenter === sheet)
    }

    /// 出たままのアプリ内通知の決め方を外したら、そのチップを消す。
    @Test func removingPersistentContentRemovesChip() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.notices.setPersistent({ _ in Notice(id: "progress", kind: .progress, title: "処理中") }, in: .download)
        #expect(harness.overlay.column.stack.persistentNotice?.title == "処理中")

        harness.notices.setPersistent(nil, in: .download)

        #expect(harness.overlay.column.stack.persistentNotice == nil)
    }

    /// チップのない場所に触れたら、下の一覧へ通す。
    @Test func touchesOutsideChipsReachList() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)
        let chip = try #require(harness.overlay.column.stack.chips.first)
        harness.window.layoutIfNeeded()
        let below = chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.maxY + 80), to: nil)

        let hit = try #require(harness.window.hitTest(below, with: nil))
        #expect(hit.isDescendant(of: harness.collectionView))
    }

    /// 画面を移ったら、チップは前の画面と一緒に流れず、次の画面の位置へ動く。戻れば元の位置に戻る。
    @Test func chipMovesToPushedScreenAndBack() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let navigation = try #require(harness.viewController.navigationController)
        let delegate = NoticeNavigationDelegate()
        navigation.delegate = delegate
        harness.viewController.setUnreadCount(5)
        harness.viewController.showNotice(failure)
        let onTimeline = try chipMinY(in: harness)

        let pushed = UIViewController()
        navigation.pushViewController(pushed, animated: false)
        harness.window.layoutIfNeeded()
        let onPushed = try chipMinY(in: harness)
        #expect(onPushed < onTimeline - 20)
        #expect(abs(onPushed - (pushed.view.safeAreaInsets.top + 8)) < 1)
        #expect(harness.overlay.column.stack.chips.count == 1)

        navigation.popViewController(animated: false)
        harness.window.layoutIfNeeded()
        #expect(try chipMinY(in: harness) == onTimeline)
    }
}

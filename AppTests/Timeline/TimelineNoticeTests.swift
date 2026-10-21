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

    /// 新着のボタンが出入りしても動かさず、ボタンの上に重ねる。出たままのチップを押そうとしている間に、位置が変わらないようにするため。
    @Test func chipStaysWhenNewArrivalsButtonAppears() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)
        let alone = try chipMinY(in: harness)

        harness.viewController.setUnreadCount(5)
        #expect(try chipMinY(in: harness) == alone)

        harness.viewController.setUnreadCount(0)
        #expect(try chipMinY(in: harness) == alone)
    }

    /// 指が触れている間（VoiceOverの読み上げ位置が乗っている間も）は、画面を移っても動かさず、離したら動かす。
    @Test func heldChipStaysUntilReleased() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.showNotice(failure)
        let before = try chipMinY(in: harness)
        let chip = try #require(harness.overlay.column.stack.chips.first)

        chip.accessibilityElementDidBecomeFocused()
        try pushLowerScreen(on: harness, below: before)
        #expect(try chipMinY(in: harness) == before)

        chip.accessibilityElementDidLoseFocus()
        #expect(try chipMinY(in: harness) > before + 20)
    }

    /// 画面を移って動いている途中に触れたら、その場で止めて留める。
    @Test func chipStopsWhereItIsWhenHeldWhileMoving() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.tuning.setValue(1, for: TuningCatalog.noticeAnimationDuration)
        let column = harness.overlay.column
        harness.viewController.showNotice(failure)
        let start = try chipMinY(in: harness)
        let chip = try #require(column.stack.chips.first)

        try pushLowerScreen(on: harness, below: start)
        let end = try chipMinY(in: harness)
        try await Task.sleep(for: .milliseconds(200))
        let shown = try #require(column.layer.presentation()?.position.y)
        chip.accessibilityElementDidBecomeFocused()

        #expect(column.layer.animationKeys()?.isEmpty ?? true)
        #expect(abs(column.center.y - shown) < 1)
        let heldMinY = try chipMinY(in: harness)
        #expect(heldMinY > start && heldMinY < end)
    }

    /// 一番上から引っぱっても、列は下げない。十分に引っぱれば、一番上の投稿が列の下に見えるため。
    @Test func pullingDownLeavesChipInPlace() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 20, startingAt: 1000))
        harness.viewController.showNotice(failure)
        let before = try chipMinY(in: harness)

        let collectionView = harness.collectionView
        collectionView.contentOffset.y = -collectionView.adjustedContentInset.top - 50

        #expect(try chipMinY(in: harness) == before)
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

    /// しまった出たままのチップは、進み具合が変わっただけでは出さず、種類が変わったときと、新しいアプリ内通知が出たときに、また出す。
    @Test func dismissedChipReturnsWhenItChanges() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let stack = harness.overlay.column.stack
        let source = NoticeSource(Notice(id: "download", kind: .progress, title: "ダウンロード中", value: "10%", valueIsProgress: true))
        harness.notices.setPersistent({ _ in source.notice }, in: .download)
        try dismiss(try #require(stack.chips.first))
        #expect(stack.persistentNotice == nil)

        source.notice?.value = "20%"
        harness.notices.persistentDidChange()
        #expect(stack.persistentNotice == nil)

        source.notice = Notice(id: "download", kind: .failure, title: "ダウンロードできませんでした")
        harness.notices.persistentDidChange()
        #expect(stack.persistentNotice?.kind == .failure)

        try dismiss(try #require(stack.chips.first))
        #expect(stack.persistentNotice == nil)
        harness.viewController.showNotice(failure)
        #expect(stack.persistentNotice?.kind == .failure)
        #expect(stack.transientNotice != nil)
    }

    /// テストの中で書き換える、出たままのアプリ内通知の中身。
    @MainActor
    private final class NoticeSource {
        var notice: Notice?
        init(_ notice: Notice) { self.notice = notice }
    }

    /// 件数のように進み具合でない値が変わったら、しまったチップをまた出す。
    @Test func dismissedChipReturnsWhenCountChanges() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let stack = harness.overlay.column.stack
        let source = NoticeSource(.downloads(count: 2, action: .none))
        harness.notices.setPersistent({ _ in source.notice }, in: .download)
        try dismiss(try #require(stack.chips.first))

        source.notice = .downloads(count: 3, action: .none)
        harness.notices.persistentDidChange()

        #expect(stack.persistentNotice?.value == "3件")
    }

    /// 選ばれていない出どころに新しい出たままのアプリ内通知が出ても、しまったチップをまた出す。
    @Test func dismissedChipReturnsWhenAnotherPersistentNoticeArrives() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let stack = harness.overlay.column.stack
        harness.notices.setPersistent({ _ in Notice(id: "failure", kind: .failure, title: "ダウンロードできませんでした") }, in: .download)
        let debug = NoticeSource(Notice(id: "progress.1", kind: .progress, title: "処理中", valueIsProgress: true))
        harness.notices.setPersistent({ _ in debug.notice }, in: .debug)
        try dismiss(try #require(stack.chips.first))
        #expect(stack.persistentNotice == nil)

        debug.notice = Notice(id: "progress.2", kind: .progress, title: "処理中", valueIsProgress: true)
        harness.notices.persistentDidChange()

        #expect(stack.persistentNotice?.id == "failure")
    }

    private func dismiss(_ chip: NoticeChip) throws {
        let action = try #require(chip.accessibilityCustomActions?.first { $0.name == "しまう" })
        #expect(action.actionHandler?(action) == true)
    }

    /// ログインし直しの段はしまえない。
    @Test func reauthenticationRowCannotBeDismissed() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.notices.reauthentication = NoticeCenter.Reauthentication(handle: "@alice@example.social") {}

        let button = harness.overlay.column.reauthenticationButton
        #expect(button.accessibilityCustomActions?.isEmpty ?? true)
        #expect(!(button.gestureRecognizers ?? []).contains { $0 is UIPanGestureRecognizer })
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
        harness.viewController.showNotice(failure)
        let onTimeline = try chipMinY(in: harness)

        let pushed = try pushLowerScreen(on: harness, below: onTimeline)
        #expect(try abs(chipMinY(in: harness) - pushed.top) < 1)
        #expect(harness.overlay.column.stack.chips.count == 1)

        pushed.navigationController?.popViewController(animated: false)
        harness.window.layoutIfNeeded()
        #expect(try chipMinY(in: harness) == onTimeline)
    }

    /// 位置を決めない画面では、上の安全領域のすぐ下に置く。
    @Test func chipSitsBelowSafeAreaOnPlainScreen() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let navigation = try #require(harness.viewController.navigationController)
        let delegate = NoticeNavigationDelegate()
        navigation.delegate = delegate
        harness.viewController.showNotice(failure)

        let pushed = UIViewController()
        navigation.pushViewController(pushed, animated: false)
        harness.window.layoutIfNeeded()
        #expect(try abs(chipMinY(in: harness) - (pushed.view.safeAreaInsets.top + 8)) < 1)
    }

    /// 一覧より100pt下にチップを置く画面を、動きなしで重ねる。チップを動かすきっかけに使う。
    @discardableResult
    private func pushLowerScreen(on harness: TimelineHarness, below top: CGFloat) throws -> LowerNoticeScreen {
        let navigation = try #require(harness.viewController.navigationController)
        let delegate = NoticeNavigationDelegate()
        navigation.delegate = delegate
        let screen = LowerNoticeScreen(top: top + 100)
        screen.navigationDelegate = delegate
        navigation.pushViewController(screen, animated: false)
        harness.window.layoutIfNeeded()
        return screen
    }
}

/// チップの列を、決まった位置（ウインドウの座標）に置く画面。
private final class LowerNoticeScreen: UIViewController, NoticeScreen {
    let top: CGFloat
    /// ナビゲーションのdelegateは弱く持たれるため、画面が生きている間ここで持つ。
    var navigationDelegate: NoticeNavigationDelegate?

    init(top: CGFloat) {
        self.top = top
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    func noticePlacement(below: CGFloat) -> NoticePlacement {
        NoticePlacement(top: top)
    }
}

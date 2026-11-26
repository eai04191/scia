import SafariServices
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// アプリ内のSafariを全画面で開く流れ（`InAppBrowser.openFullScreen`）。
/// 読み込みの間は、Safariを持たない伏せたシートに、重ねたウインドウから出したSafariを重ね、読み込み終えたら全画面に広げる。
@MainActor
@Suite(.scratch, .serialized, .failureState)
struct InAppBrowserFullScreenTests {
    private let notices = NoticeCenter()

    /// 読み込みの間は、伏せたシートのSafariを出す場所に重ね、見えているところの外で触れたことは、下のウインドウへ通す。通さないと、読み込みを待つ間にタイムラインもシートも触れなくなる。
    /// Safariのバーの上の引ける範囲は、Safariより手前に、シートの引ける範囲と同じ位置に置き、引くとシートを引いたのと同じに動く。
    /// Safariの上で触れたことは`hitTest`を通らずにSafariへ行くので、下のウインドウのシートに範囲を置いても、Safariに重なる部分では引けない。
    @Test func loadingOverlaysCollapsedSheetAndPassesTouchesBehind() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let frames = ManualFrameSource()
        let (browser, sheet, overlay) = try await openFullScreen(from: harness.viewController, frames: frames)

        #expect(sheet.safari == nil)
        #expect(sheet.sheetPresentation?.selected == .collapsed)
        frames.advance(by: ManualFrameSource.frame)
        #expect(overlay.isCollapsed)
        #expect(overlay.alpha == 1)

        let top = try #require(sheet.safariTopOnScreen)
        #expect(overlay.hitTest(CGPoint(x: 30, y: top - 40), with: nil) == nil)
        #expect(overlay.hitTest(CGPoint(x: 30, y: top + 20), with: nil) != nil)
        #expect(sheet.barGrabArea.superview == nil)
        let grab = try #require(overlay.hitTest(CGPoint(x: overlay.bounds.midX, y: top + 4), with: nil) as? InAppBrowserBarGrabView)
        #expect(overlay.subviews.last === grab)
        let shape = try #require(sheet.shapeOnScreen)
        #expect(grab.frame == grab.barGrab.frame(width: shape.frame.width, safariTop: top).offsetBy(dx: shape.frame.minX, dy: 0))

        // 引き上げると、シートを引いたのと同じに、伏せた高さを離れて全画面に広げる。
        overlay.onBarGrabPan?(.began, 0, 0)
        overlay.onBarGrabPan?(.changed, -400, 0)
        overlay.onBarGrabPan?(.ended, -400, -1000)
        #expect(!overlay.isCollapsed)
        try await close(browser, overlay: overlay, from: harness.viewController)
    }

    /// 読み込み終えたら全画面に広げ、広げ終えたら裏に隠れた伏せたシートを閉じる。
    @Test func completingLoadExpandsAndClosesTheSheet() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, _, overlay) = try await openFullScreen(from: root, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        var docked: [(height: CGFloat, animated: Bool)] = []
        browser.onDockedHeightChange = { docked.append(($0, $1)) }

        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)

        #expect(!overlay.isCollapsed)
        #expect(overlay.hitTest(CGPoint(x: 30, y: 200), with: nil) != nil)
        #expect(frames.isRunning)
        try await clock.advance(until: { root.presentedViewController == nil })
        #expect(!browser.isPresented)
        #expect(!overlay.isHidden)
        // 広げる動きの間だけ120Hzを頼み、広げ終えたら止める。
        #expect(!frames.isRunning)
        // 縮めた後ろの画面は、全画面のSafariが覆っていて見えないので、動かさずに戻す。動かすと、見えない動きのために画面の合成が働く。
        #expect(docked.last?.height == 0)
        #expect(docked.last?.animated == false)
        try await close(browser, overlay: overlay, from: root)
    }

    /// 全画面に広げたあと、Safariのバーの上の引ける範囲のタップで、伏せたシートを出し直して伏せた見え方に戻し、タイムラインを覆うのをやめる。シートを引き上げると、また広げる。
    /// 引ける範囲は、伏せている間と同じく、Safariのバーの上端から同じ位置に置く。
    @Test func tappingBarCollapsesAndPullingUpExpandsAgain() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, _, overlay) = try await openFullScreen(from: root, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)
        try await clock.advance(until: { root.presentedViewController == nil })
        // 引ける範囲は、Safariより手前に重ねる。Safariの上のタッチは、ウインドウの`hitTest`を通らずにSafariへ届くため。
        let barMiddle = CGPoint(x: overlay.bounds.midX, y: overlay.safeAreaInsets.top + 4)
        let grab = try #require(overlay.hitTest(barMiddle, with: nil) as? InAppBrowserBarGrabView)
        #expect(overlay.subviews.last === grab)
        #expect(grab.frame == grab.barGrab.frame(width: overlay.bounds.width, safariTop: overlay.safeAreaInsets.top))
        var covered: [Bool] = []
        browser.onCoverageChange = { covered.append($0) }

        overlay.onBarGrabTap?()

        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false && overlay.isCollapsed }
        #expect(!browser.showsFullScreen)
        #expect(covered.last == false)
        // 伏せる途中は、引ける範囲を、行き先ではなく見えている位置で受ける。
        try await clock.advance(by: 0.1)
        let shown = try #require(grab.layer.presentation()?.frame)
        #expect(abs(shown.minY - grab.frame.minY) > 10)
        #expect(overlay.hitTest(CGPoint(x: shown.midX, y: shown.midY), with: nil) === grab)
        try await clock.advance(until: { LayerClock.finiteAnimations(in: overlay.layer).isEmpty })
        frames.advance(by: ManualFrameSource.frame)
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let top = try #require(sheet.safariTopOnScreen)
        #expect(overlay.hitTest(CGPoint(x: 30, y: top - 40), with: nil) == nil)
        #expect(overlay.hitTest(barMiddle, with: nil) == nil)
        #expect(overlay.hitTest(CGPoint(x: overlay.bounds.midX, y: top + 4), with: nil) === grab)

        let presentation = try #require(sheet.sheetPresentation)
        presentation.select(.medium, animated: false)
        presentation.onSelectionChange?()

        #expect(!overlay.isCollapsed)
        try await clock.advance(until: { root.presentedViewController == nil })
        #expect(browser.showsFullScreen)
        try await close(browser, overlay: overlay, from: root)
    }

    /// 全画面に広げている間は、伏せられる画面のときだけ引ける範囲を出す。iPhoneの横向きには伏せた高さがないので、出すとタップで何も起きず、
    /// 重ねた範囲にあるSafariのバーのボタン（横向きでは戻る・共有などがバーの左右に並ぶ）を押せなくなる。縦に戻したら、また出す。
    @Test func expandedBarGrabFollowsWhetherItCanCollapse() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, _, overlay) = try await openFullScreen(from: root, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)
        try await clock.advance(until: { root.presentedViewController == nil })
        let barMiddle = CGPoint(x: overlay.bounds.midX, y: overlay.safeAreaInsets.top + 4)
        #expect(overlay.hitTest(barMiddle, with: nil) is InAppBrowserBarGrabView)

        overlay.traitOverrides.verticalSizeClass = .compact
        overlay.layoutIfNeeded()
        #expect(!(overlay.hitTest(barMiddle, with: nil) is InAppBrowserBarGrabView))

        overlay.traitOverrides.verticalSizeClass = .regular
        overlay.layoutIfNeeded()
        #expect(overlay.hitTest(barMiddle, with: nil) is InAppBrowserBarGrabView)
        overlay.traitOverrides.remove(UITraitVerticalSizeClass.self)
        try await close(browser, overlay: overlay, from: root)
    }

    /// シートのバーで引ける範囲の高さが0（バーを覆わない）なら、全画面でも引ける範囲を重ねない。
    @Test func zeroBarGrabHeightAddsNoBarGrab() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let tuning = TuningStore.withoutBrowserMotion()
        tuning.setValue(0, for: TuningCatalog.inAppBrowserBarGrabHeight)
        let (browser, _, overlay) = try await openFullScreen(from: root, frames: frames, tuning: tuning)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)
        try await clock.advance(until: { root.presentedViewController == nil })

        let hit = overlay.hitTest(CGPoint(x: overlay.bounds.midX, y: overlay.safeAreaInsets.top + 4), with: nil)
        #expect(!(hit is InAppBrowserBarGrabView))
        try await close(browser, overlay: overlay, from: root)
    }

    /// 読み込み終える前に引き上げて広げ、手で伏せたあとに読み込みを終えても、伏せたままにする。読み込み終えたときに広げるのは、まだ一度も広げていない間だけ。
    @Test func loadCompletingAfterManualCollapseKeepsItCollapsed() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, sheet, overlay) = try await openFullScreen(from: root, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        let presentation = try #require(sheet.sheetPresentation)
        presentation.select(.medium, animated: false)
        presentation.onSelectionChange?()
        try await clock.advance(until: { root.presentedViewController == nil })
        overlay.onBarGrabTap?()
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false && overlay.isCollapsed }

        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)

        #expect(overlay.isCollapsed)
        #expect(!browser.showsFullScreen)
        try await close(browser, overlay: overlay, from: root)
    }

    /// シートの上に別の画面を重ねている間に読み込み終えても広げず、その画面を閉じてから広げる。
    /// 重ねたまま広げると、伏せたシートを片付けるときに、上の画面まで閉じてしまう。
    @Test func coveredSheetDefersExpansionUntilUncovered() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let frames = ManualFrameSource()
        let (browser, sheet, overlay) = try await openFullScreen(from: harness.viewController, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let above = UIViewController()
        try await sheet.presentForTesting(above)
        frames.advance(by: ManualFrameSource.frame)
        #expect(overlay.alpha == 0)

        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)

        #expect(overlay.isCollapsed)
        #expect(sheet.presentedViewController === above)
        try await above.dismissForTesting()
        frames.advance(by: ManualFrameSource.frame)
        #expect(!overlay.isCollapsed)
        try await close(browser, overlay: overlay, from: harness.viewController)
    }

    /// 伏せたままSafari自身が閉じると（×）、Safariの右へ抜ける動きを止めて、下がるシートに付いていかせ、シートが下がりきったら閉じ終えて、重ねたウインドウを隠す。
    /// 止めないと、Safariは右へ抜け、シートは下へ下がる。下がりきったあとに止めた動きを終わらせないと、Safariが閉じ終えずに残る。
    @Test func closingSafariWhileCollapsedClosesWithTheSheet() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let window = try #require(root.view.window)
        let scene = try #require(window.windowScene)
        let existing = scene.windows
        // 層の時計は、動きのないときに止める（`LayerClock`）ので、開く前に止め、開く動きも時計で進める。
        let appClock = LayerClock(freezing: window.layer)
        defer { appClock.release() }
        let browser = InAppBrowser(tuning: AppDependencies.tuning, settings: AppDependencies.settings, frameSource: frames)
        browser.openFullScreen(try #require(URL(string: "https://example.com/1")), from: root)
        try await appClock.advance(until: { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false })
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let overlay = try #require(scene.windows.compactMap { $0 as? InAppBrowserOverlayWindow }.first { overlay in !existing.contains { $0 === overlay } })
        try await waitUntil { overlay.presenter?.presentedViewController is SFSafariViewController }
        let overlayClock = LayerClock(freezing: overlay.layer)
        defer { overlayClock.release() }
        frames.advance(by: ManualFrameSource.frame)
        let safari = try safari(in: overlay)
        let startX = safari.view.layer.position.x
        let startTop = try #require(sheet.safariTopOnScreen)

        safari.dismiss(animated: true)

        #expect(safari.isBeingDismissed)
        try await overlayClock.advance(by: LayerClock.frame)
        try await waitUntil { safari.view.layer.speed == 0 }
        try await overlayClock.advance(by: 0.1)
        try await appClock.advance(by: 0.1)
        frames.advance(by: ManualFrameSource.frame)
        let shownX = try #require(safari.view.layer.presentation()?.position.x)
        #expect(abs(shownX - startX) < 0.5)
        let top = try #require(sheet.safariTopOnScreen)
        #expect(top > startTop + 10)
        let container = try #require(safari.view.superview)
        #expect(abs(container.transform.ty - (top - overlay.safeAreaInsets.top)) < 0.5)

        try await appClock.advance(until: { root.presentedViewController == nil })
        try await overlayClock.advance(until: { overlay.isHidden })
        #expect(!browser.isPresented)
        #expect(safari.view.layer.speed == 1)
    }

    /// 伏せたシートの上に、Safariの範囲にかからない画面（メニューと同じく、画面の上の隅の小さなビュー）を重ねても、Safariを隠さない。
    /// 隠すと、Safariを持たない伏せたシートだけが残って見える。範囲にかかる画面を重ねたときに隠すのは、`coveredSheetDefersExpansionUntilUncovered`で確かめる。
    @Test func smallScreenAboveSheetKeepsSafariShown() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let frames = ManualFrameSource()
        let (browser, sheet, overlay) = try await openFullScreen(from: harness.viewController, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let menu = UIViewController()
        let transitioning = CornerPresentationTransitioning()
        menu.modalPresentationStyle = .custom
        menu.transitioningDelegate = transitioning
        try await sheet.presentForTesting(menu)

        frames.advance(by: ManualFrameSource.frame)

        #expect(overlay.alpha == 1)
        #expect(overlay.isCollapsed)
        // 重ねている間に読み込み終えたら、広げるのは閉じてから。それまで合わせ続ける。
        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)
        frames.advance(by: ManualFrameSource.frame)
        #expect(overlay.isCollapsed)
        #expect(frames.isRunning)
        try await menu.dismissForTesting()
        frames.advance(by: ManualFrameSource.frame)
        #expect(!overlay.isCollapsed)
        try await close(browser, overlay: overlay, from: harness.viewController)
    }

    /// 伏せている間にブラウザーを手放しても（アカウントを切り替えて画面を作り直したなど）、重ねたウインドウが残らない。
    /// 毎コマ合わせる処理とセッションが互いを強く持つと、どちらも解放されず、Safariのバーだけが新しい画面の上に残る。
    @Test func releasingBrowserWhileCollapsedReleasesOverlay() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        weak var weakOverlay: InAppBrowserOverlayWindow?
        do {
            let (_, _, overlay) = try await openFullScreen(from: root, frames: frames)
            frames.advance(by: ManualFrameSource.frame)
            weakOverlay = overlay
        }
        root.dismissPresentedScreens(animated: false)
        frames.advance(by: ManualFrameSource.frame)
        try await waitUntil { weakOverlay == nil }
    }

    /// アプリのセッションを終えるとき（`stop`）は、伏せている間でも重ねたウインドウを閉じる。重ねたウインドウはアプリのウインドウの外にあり、画面を作り直しても残るため。
    @Test func stoppingClosesOverlay() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, _, overlay) = try await openFullScreen(from: root, frames: frames)
        frames.advance(by: ManualFrameSource.frame)

        browser.stop()

        #expect(overlay.isHidden)
        frames.advance(by: ManualFrameSource.frame)
        #expect(!frames.isRunning)
        root.dismissPresentedScreens(animated: false)
    }

    /// 広げている途中に、もう一度広げる操作をしても始め直さず、伏せたシートは広げ終えてから片付ける。
    /// 始め直すと、広げ終える前に伏せたシートを片付け、あとから届く最初の広げる動きの終わりの処理が、次に伏せたシートまで片付ける。
    @Test func expandingAgainWhileExpandingKeepsTheSheetUntilDone() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        // 出す動きは実際の時間で待つので、0で出してから、確かめる間の動きを既定の長さに戻す。
        let tuning = TuningStore.withoutBrowserMotion()
        let (browser, sheet, overlay) = try await openFullScreen(from: root, frames: frames, tuning: tuning)
        tuning.setValue(TuningCatalog.inAppBrowserDockDuration.defaultValue, for: TuningCatalog.inAppBrowserDockDuration)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        let presentation = try #require(sheet.sheetPresentation)
        presentation.select(.medium, animated: false)
        presentation.onSelectionChange?()
        try await clock.advance(by: 0.1)
        #expect(overlay.isExpanding)

        presentation.select(.large, animated: false)
        presentation.onSelectionChange?()

        #expect(overlay.isExpanding)
        #expect(!browser.showsFullScreen)
        #expect(root.presentedViewController === sheet)
        try await clock.advance(until: { root.presentedViewController == nil })
        #expect(browser.showsFullScreen)
        try await close(browser, overlay: overlay, from: root)
    }

    /// 広げている途中にシートの上に画面を重ねたら（行き先を開いたなど）、広げ終えてもその画面を閉じない。Safariを隠し、その画面を閉じてから広げる。
    @Test func screenPresentedWhileExpandingStaysOpen() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, sheet, overlay) = try await openFullScreen(from: root, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)
        #expect(overlay.isExpanding)
        let above = UIViewController()
        try await sheet.presentForTesting(above)

        try await clock.advance(until: { !overlay.isExpanding })
        frames.advance(by: ManualFrameSource.frame)

        #expect(sheet.presentedViewController === above)
        #expect(overlay.alpha == 0)
        try await above.dismissForTesting()
        frames.advance(by: ManualFrameSource.frame)
        try await waitUntil { root.presentedViewController == nil }
        #expect(browser.showsFullScreen)
        try await close(browser, overlay: overlay, from: root)
    }

    /// 伏せたシートが止まったら、毎コマ合わせる処理を止める（止めないと、タイムラインを読む間も80〜120Hzを頼み続ける）。引くとまた始める。
    @Test func followingStopsWhileStillAndResumesOnDrag() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, sheet, overlay) = try await openFullScreen(from: root, frames: frames)
        for _ in 0..<4 { frames.advance(by: ManualFrameSource.frame) }
        #expect(!frames.isRunning)
        #expect(overlay.isCollapsed)

        try #require(sheet.sheetPresentation).drag(.began, translation: 0, velocity: 0)

        #expect(frames.isRunning)
        try #require(sheet.sheetPresentation).drag(.cancelled, translation: 0, velocity: 0)
        try await close(browser, overlay: overlay, from: root)
    }

    /// 毎コマ合わせる処理を止めたあと、シートを通らずに出る画面（タイムラインのメニューなど）が重なっている間に読み込み終えたら、合わせる処理を始め直し、その画面が閉じたら広げる。
    @Test func loadCompletingUnderUnnoticedScreenExpandsAfterItCloses() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, sheet, overlay) = try await openFullScreen(from: root, frames: frames)
        for _ in 0..<4 { frames.advance(by: ManualFrameSource.frame) }
        #expect(!frames.isRunning)
        // メニューは、シートの`present`を通らずに出る。
        sheet.onMayMove = nil
        let menu = UIViewController()
        let transitioning = CornerPresentationTransitioning()
        menu.modalPresentationStyle = .custom
        menu.transitioningDelegate = transitioning
        try await sheet.presentForTesting(menu)

        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)

        #expect(frames.isRunning)
        try await menu.dismissForTesting()
        frames.advance(by: ManualFrameSource.frame)
        #expect(!overlay.isCollapsed)
        try await close(browser, overlay: overlay, from: root)
    }

    /// 読み込みの間に重ねた画面をまとめて閉じると、伏せたシートと一緒に重ねたSafariも閉じる。
    /// 重ねたウインドウは、`dismissPresentedScreens`が辿るアプリのウインドウの外にあるため、閉じたことを受けて閉じないとSafariだけが残る。
    @Test func closingScreensWhileLoadingAlsoHidesOverlay() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, _, overlay) = try await openFullScreen(from: root, frames: frames)

        browser.closeFullScreen()
        #expect(!overlay.isHidden)
        root.dismissPresentedScreens(animated: false)

        try await waitUntil { root.presentedViewController == nil && overlay.isHidden }
        // 閉じる動き用の毎コマの処理（120Hzの頼み）は、ウインドウを隠したら次のコマで止める。止めないと、実機では120Hzを頼み続ける。
        frames.advance(by: ManualFrameSource.frame)
        #expect(!frames.isRunning)
        #expect(!browser.isPresented)
    }

    /// 全画面に広げたあとは、アプリのウインドウに何も重ねていないので、`closeFullScreen`で重ねたウインドウを閉じる。
    @Test func closeFullScreenHidesExpandedOverlay() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let (browser, _, overlay) = try await openFullScreen(from: root, frames: frames)
        frames.advance(by: ManualFrameSource.frame)
        let clock = LayerClock(freezing: overlay.layer)
        defer { clock.release() }
        browser.safariViewController(try safari(in: overlay), didCompleteInitialLoad: true)
        try await clock.advance(until: { root.presentedViewController == nil })
        #expect(browser.showsFullScreen)

        browser.closeFullScreen()

        #expect(overlay.isHidden)
        #expect(!browser.showsFullScreen)
    }

    /// 読み込みの間に別のリンクを全画面で開くと、伏せたシートを閉じ終えてから、新しいSafariで出し直す。
    @Test func openingAnotherLinkWhileLoadingReplacesIt() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let frames = ManualFrameSource()
        let scene = try #require(root.view.window?.windowScene)
        // 番地（ObjectIdentifier）だけで覚えると、解放されたウインドウの番地を新しいウインドウが使い回したときに取り違えるので、ウインドウを持ち続ける。
        let existing = scene.windows
        let (browser, firstSheet, firstOverlay) = try await openFullScreen(from: root, frames: frames)

        browser.openFullScreen(try #require(URL(string: "https://example.com/2")), from: root)

        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController !== firstSheet && root.presentedViewController?.isBeingPresented == false }
        #expect(firstOverlay.isHidden)
        let overlays = scene.windows.compactMap { $0 as? InAppBrowserOverlayWindow }.filter { overlay in !existing.contains { $0 === overlay } && !overlay.isHidden }
        #expect(overlays.count == 1)
        #expect(browser.isPresented)
        try await close(browser, overlay: try #require(overlays.first), from: root)
    }

    /// アプリと同じく、全画面に広げたSafariを閉じてから、重ねた画面をまとめて閉じる。読み込みの間の重ねたウインドウは、伏せたシートを閉じ終えたときに閉じる。
    /// 閉じ終えたという知らせが`InAppBrowser`に届くまで待つ。待たずにテストを終えると、知らせを受ける`InAppBrowser`がいなくなり、ウインドウが残る。
    private func close(_ browser: InAppBrowser, overlay: InAppBrowserOverlayWindow, from root: UIViewController) async throws {
        browser.closeFullScreen()
        root.dismissPresentedScreens(animated: false)
        try await waitUntil { root.presentedViewController == nil && overlay.isHidden }
    }

    private func openFullScreen(from root: UIViewController, frames: ManualFrameSource, tuning: TuningStore = .withoutBrowserMotion()) async throws -> (InAppBrowser, InAppBrowserSheet, InAppBrowserOverlayWindow) {
        let scene = try #require(root.view.window?.windowScene)
        // 番地（ObjectIdentifier）だけで覚えると、解放されたウインドウの番地を新しいウインドウが使い回したときに取り違えるので、ウインドウを持ち続ける。
        let existing = scene.windows
        let browser = InAppBrowser(tuning: tuning, settings: AppDependencies.settings, frameSource: frames)
        browser.openFullScreen(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let overlay = try #require(scene.windows.compactMap { $0 as? InAppBrowserOverlayWindow }.first { overlay in !existing.contains { $0 === overlay } })
        try await waitUntil { overlay.presenter?.presentedViewController is SFSafariViewController }
        return (browser, sheet, overlay)
    }

    private func safari(in overlay: InAppBrowserOverlayWindow) throws -> SFSafariViewController {
        try #require(overlay.presenter?.presentedViewController as? SFSafariViewController)
    }
}

/// 画面の左上の隅に小さく出す画面。メニューの画面（iOSの`_UIContextMenuActionsOnlyViewController`）と同じく、Safariの範囲にかからない。
private final class CornerPresentationTransitioning: NSObject, UIViewControllerTransitioningDelegate {
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        CornerPresentationController(presentedViewController: presented, presenting: presenting)
    }
}

private final class CornerPresentationController: UIPresentationController {
    override var frameOfPresentedViewInContainerView: CGRect { CGRect(x: 0, y: 0, width: 44, height: 44) }
}

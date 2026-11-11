import SafariServices
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.scratch, .serialized, .failureState)
struct InAppBrowserDockTests {
    private let notices = NoticeCenter()

    @Test func containerShrinksContentAndRestoresIt() throws {
        let content = UIViewController()
        let container = InAppBrowserDockContainer(content: content)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.rootViewController = container
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        #expect(content.view.frame.height == 800)

        let visibleArea = try #require(content.view.superview)
        container.setReservedHeight(160, contentOverhang: 14, cornerRadius: 44, duration: 0)
        #expect(visibleArea.frame == CGRect(x: 0, y: 0, width: 400, height: 640))
        #expect(visibleArea.clipsToBounds)
        #expect(visibleArea.layer.cornerRadius == 44)
        #expect(content.view.frame == CGRect(x: 0, y: 0, width: 400, height: 654))

        container.setReservedHeight(0, contentOverhang: 14, cornerRadius: 44, duration: 0)
        #expect(visibleArea.frame.height == 800)
        #expect(visibleArea.layer.cornerRadius == 0)
        #expect(content.view.frame.height == 800)
    }

    /// 手で伏せた高さまで下げたときだけ後ろの画面を縮める。開く途中に伏せた高さを通るときと、投稿欄のために下げたときは縮めない。
    @Test func docksOnlyWhenLoweredByHand() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
        var docked: [CGFloat] = []
        var obscured: CGFloat = 0
        browser.onDockedHeightChange = { docked.append($0) }
        browser.onObscuredHeightChange = { obscured = $0 }
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false && obscured > 0 }
        #expect(docked.allSatisfy { $0 == 0 })
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)

        browser.lowerForCompose()
        #expect(docked.last == 0)
        browser.restoreAfterCompose()

        presentation.select(.collapsed, animated: false)
        presentation.onSelectionChange?()
        #expect(docked.last == CGFloat(try #require(presentation.layout.collapsed)))
        #expect(obscured == 0)

        presentation.select(.large, animated: false)
        presentation.onSelectionChange?()
        #expect(docked.last == 0)
        root.dismiss(animated: false)
    }

    /// 後ろの画面に別の画面を開くときは、どの高さからでも伏せた高さへ下げ、後ろの画面を縮める。
    @Test func lowersToCollapsedToShowScreenBehind() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
        var docked: CGFloat = 0
        browser.onDockedHeightChange = { docked = $0 }
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)
        presentation.select(.large, animated: false)

        #expect(browser.lowerToShowScreenBehind())

        #expect(presentation.selected == .collapsed)
        #expect(docked == CGFloat(try #require(presentation.layout.collapsed)))
        root.dismiss(animated: false)
    }

    /// シートは伏せた段でも画面の幅いっぱいに出す。
    @Test func collapsedSheetSpansScreenWidth() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)

        presentation.select(.collapsed, animated: false)

        let container = try #require(presentation.containerView)
        #expect(sheet.view.frame.width == container.bounds.width)
        #expect(sheet.view.frame.minY == container.bounds.height - CGFloat(try #require(presentation.layout.collapsed)))
        root.dismiss(animated: false)
    }

    /// ホームバーのある機種では、伏せた高さにSafariのボタンを画面の角から離す長さを足す。
    @Test func collapsedHeightLeavesRoomForHomeIndicator() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let tuning = TuningStore.withoutBrowserMotion()
        tuning.setValue(70, for: TuningCatalog.inAppBrowserCollapsedHeight)
        tuning.setValue(20, for: TuningCatalog.inAppBrowserCollapsedHomeIndicatorSpace)
        let browser = InAppBrowser(tuning: tuning)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)
        let window = try #require(sheet.view.window)
        try #require(window.safeAreaInsets.bottom > 0)

        #expect(presentation.layout.collapsed == 90)
        root.dismiss(animated: false)
    }

    /// 動いている途中は、ビューの行き先ではなく、画面に見えている引ける範囲に触れたものをシートで受ける。
    @Test func grabsSheetAtVisiblePositionWhileMoving() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let tuning = TuningStore.withoutBrowserMotion()
        let browser = InAppBrowser(tuning: tuning)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)
        let window = try #require(sheet.view.window)
        #expect(presentation.moveGrabTarget(at: CGPoint(x: 200, y: sheet.view.frame.minY + 2), in: window) == nil)

        tuning.setValue(2, for: TuningCatalog.inAppBrowserDockDuration)
        presentation.select(.large, animated: true)

        let visible = try #require(sheet.view.layer.presentation()?.frame)
        let point = CGPoint(x: visible.midX, y: visible.minY + 2)
        #expect(presentation.moveGrabTarget(at: point, in: window) === sheet.barGrabArea)
        root.dismiss(animated: false)
    }

    /// 引ける範囲のタップで、伏せた高さ、中くらい、全画面の順に進み、全画面の次は伏せた高さに戻る。
    @Test func tapCyclesThroughDetents() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)
        #expect(sheet.barGrabArea.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } == true)
        presentation.select(.collapsed, animated: false)
        var changes = 0
        let forward = presentation.onSelectionChange
        presentation.onSelectionChange = {
            changes += 1
            forward?()
        }

        presentation.selectNextDetent()
        #expect(presentation.selected == .medium)
        presentation.selectNextDetent()
        #expect(presentation.selected == .large)
        presentation.selectNextDetent()
        #expect(presentation.selected == .collapsed)
        #expect(changes == 3)
        root.dismiss(animated: false)
    }

    /// 指が止まったらスナップ点を作り、そこへ止められる。ほかの段へ動かすと消える。
    @Test func dwellCreatesTemporaryDetentUntilLeaving() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let browser = InAppBrowser(tuning: .withoutBrowserMotion(), clock: clock)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)
        let dwell = Duration.seconds(TuningCatalog.inAppBrowserSnapDwell.defaultValue)

        presentation.updateDwell(height: 301)
        try await clock.advance(afterSleeping: dwell)
        try await waitUntil { presentation.layout.temporary != nil }
        #expect(presentation.layout.temporary == 300)

        presentation.select(.temporary, animated: false)
        let container = try #require(presentation.containerView)
        #expect(sheet.view.frame.minY == container.bounds.height - 300)

        presentation.select(.large, animated: false)
        #expect(presentation.layout.temporary == nil)
        root.dismiss(animated: false)
    }

    private func openBrowser(_ browser: InAppBrowser, from root: UIViewController) async throws -> (InAppBrowserSheet, InAppBrowserPresentationController) {
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.frontmostPresented is InAppBrowserSheet || root.frontmostPresented is SFSafariViewController }
        var current: UIViewController = root
        while !(current is InAppBrowserSheet), let next = current.presentedViewController { current = next }
        let sheet = try #require(current as? InAppBrowserSheet)
        try await waitUntil { sheet.isBeingPresented == false }
        return (sheet, try #require(sheet.sheetPresentation))
    }

    private func makeTemporaryDetent(_ presentation: InAppBrowserPresentationController, height: CGFloat, expected: Double, clock: TestClock) async throws {
        presentation.updateDwell(height: height)
        try await clock.advance(afterSleeping: .seconds(TuningCatalog.inAppBrowserSnapDwell.defaultValue))
        try await waitUntil { presentation.layout.temporary == expected }
    }

    /// 一時スナップ点に止めたあと、別の高さのスナップ点へ移したら、高さの変化を知らせる。
    @Test func movingBetweenTemporaryDetentsReportsHeight() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let browser = InAppBrowser(tuning: .withoutBrowserMotion(), clock: clock)
        var obscured: CGFloat = 0
        browser.onObscuredHeightChange = { obscured = $0 }
        let (_, presentation) = try await openBrowser(browser, from: root)
        try await makeTemporaryDetent(presentation, height: 301, expected: 300, clock: clock)
        presentation.finishDrag(height: 300, velocity: 0)
        #expect(obscured == 300)
        presentation.updateDwell(height: 500)
        try await clock.advance(afterSleeping: .seconds(TuningCatalog.inAppBrowserSnapDwell.defaultValue))
        try await waitUntil { presentation.layout.temporary == 500 }

        presentation.finishDrag(height: 500, velocity: 0)

        #expect(obscured == 500)
        root.dismiss(animated: false)
    }

    /// 別のリンクで中身を差し替えても、一時スナップ点の高さを保つ。
    @Test func replacingPageKeepsTemporaryHeight() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let browser = InAppBrowser(tuning: .withoutBrowserMotion(), clock: clock)
        let (first, presentation) = try await openBrowser(browser, from: root)
        try await makeTemporaryDetent(presentation, height: 301, expected: 300, clock: clock)
        presentation.select(.temporary, animated: false)

        browser.open(try #require(URL(string: "https://example.com/2")), from: root)

        try await waitUntil { (root.presentedViewController as? InAppBrowserSheet).map { $0 !== first && $0.sheetPresentation != nil } == true }
        let replaced = try #require((root.presentedViewController as? InAppBrowserSheet)?.sheetPresentation)
        #expect(replaced.selected == .temporary)
        #expect(replaced.layout.height(of: .temporary) == 300)
        root.dismiss(animated: false)
    }

    /// 高さの狭い画面では中くらいの高さが全画面になるので、後ろの画面を覆っていると知らせる。
    @Test func reportsCoverageWhenLayoutBecomesFullScreenOnly() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
        var covered = false
        browser.onCoverageChange = { covered = $0 }
        let (_, presentation) = try await openBrowser(browser, from: root)
        presentation.select(.medium, animated: false)
        #expect(presentation.passesTouchesOutsideSheet)

        harness.window.traitOverrides.verticalSizeClass = .compact
        let container = try #require(presentation.containerView)
        container.setNeedsLayout()
        container.layoutIfNeeded()

        try await waitUntil { covered }
        #expect(!presentation.passesTouchesOutsideSheet)
        root.dismiss(animated: false)
    }

    /// Safariがほかの画面の上にあるときは、シートの外に触れたものをSafariのすぐ下の画面へ通す。
    @Test func windowPassesTouchesToScreenUnderSheet() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = ShakeDetectingWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let overlay = UIViewController()
        overlay.modalPresentationStyle = .overFullScreen
        try await root.presentForTesting(overlay)
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
        let (_, presentation) = try await openBrowser(browser, from: root)
        presentation.select(.medium, animated: false)

        #expect(window.hitTest(CGPoint(x: 100, y: 5), with: nil) === overlay.view)
        root.dismiss(animated: false)
    }

    /// シートの外に触れたものは、中くらいの高さまでは後ろの画面へ通し、全画面では通さない。
    @Test func windowPassesTouchesOutsideSheet() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = ShakeDetectingWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)
        presentation.select(.medium, animated: false)

        #expect(window.hitTest(CGPoint(x: 100, y: 5), with: nil) === root.view)

        presentation.select(.large, animated: false)
        #expect(window.hitTest(CGPoint(x: 100, y: 5), with: nil) === presentation.containerView)
        root.dismiss(animated: false)
    }
}

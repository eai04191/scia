import SafariServices
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.scratch, .serialized)
struct InAppBrowserTests {
    private let notices = NoticeCenter()

    /// シートを出している間に別のリンクを開くと、上に重ねた画面ごと閉じて差し替え、重ねた画面にも閉じたことを知らせる。
    /// 投稿欄のシートは手前のSafariの上に出すので、知らせないと投稿欄がシートを出したままの扱いになる。
    @Test func replacingClosesScreensAboveAndNotifiesThem() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser()
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let first = try #require(root.presentedViewController)
        var closed = 0
        let sheet = ScheduleDateSheet(title: "予約の日時", date: Date(timeIntervalSince1970: 1_800_000_000), minimumDate: Date(timeIntervalSince1970: 1_700_000_000), confirmTitle: "完了") { _ in } onClose: {
            closed += 1
        }
        try await first.presentForTesting(sheet)

        browser.open(try #require(URL(string: "https://example.com/2")), from: root)

        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController !== first }
        #expect(root.presentedViewController?.presentedViewController == nil)
        #expect(closed == 1)
        #expect(browser.isPresented)
        root.dismiss(animated: false)
    }

    /// Safariはシートの帯の下にモーダルで重ね、Safariを閉じたら（×）、帯だけの空のシートを残さず、シートごと閉じる。
    @Test func closingSafariClosesTheSheet() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser()
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        #expect(sheet.presentedViewController == nil)
        #expect(sheet.safari.presentingViewController?.parent === sheet)

        sheet.safari.dismiss(animated: true)

        try await waitUntil { root.presentedViewController == nil }
    }

    /// シートの上端からSafariのバーの真ん中までには、シートを引ける範囲をSafariより手前に重ねる。左右のSafariのボタンの上には重ねない。
    @Test func barGrabAreaSitsAboveSafariBar() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser(tuning: TuningStore(defaults: nil))
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        try await waitUntil { sheet.safari.viewIfLoaded?.window != nil }
        sheet.view.layoutIfNeeded()

        let handle = CGFloat(TuningCatalog.inAppBrowserHandleHeight.defaultValue)
        let inset = CGFloat(TuningCatalog.inAppBrowserBarGrabInset.defaultValue)
        let height = CGFloat(TuningCatalog.inAppBrowserBarGrabHeight.defaultValue)

        #expect(sheet.view.subviews.last === sheet.barGrabArea)
        #expect(sheet.safari.view.isDescendant(of: sheet.view))
        #expect(sheet.barGrabArea.frame == CGRect(x: inset, y: 0, width: sheet.view.bounds.width - inset * 2, height: handle + height))
        root.dismiss(animated: false)
    }

    /// シートの段が変わった直後は、引ける範囲を広げ、シートが落ち着くころに元の高さへ戻す。動いている範囲から指が外れると、Safariへ行ってシートを引けないため。
    @Test func barGrabAreaWidensWhileSheetSettles() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let browser = InAppBrowser(tuning: TuningStore(defaults: nil), clock: clock)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        try await waitUntil { sheet.barGrabArea.superview != nil }
        let controller = try #require(sheet.sheetPresentationController)
        let height = CGFloat(TuningCatalog.inAppBrowserBarGrabHeight.defaultValue)
        let settlingHeight = CGFloat(TuningCatalog.inAppBrowserBarGrabSettlingHeight.defaultValue)
        let duration = Duration.seconds(TuningCatalog.inAppBrowserBarGrabSettlingDuration.defaultValue)

        browser.sheetPresentationControllerDidChangeSelectedDetentIdentifier(controller)
        let handle = CGFloat(TuningCatalog.inAppBrowserHandleHeight.defaultValue)
        #expect(sheet.barGrabArea.frame.minY == 0)
        #expect(sheet.barGrabArea.frame.height == handle + settlingHeight)

        try await waitUntil { clock.sleeperCount(dueWithin: duration) >= 1 }
        clock.advance(by: duration)
        try await waitUntil { sheet.barGrabArea.frame.height == handle + height }
        #expect(sheet.barGrabArea.frame.minY == 0)
        root.dismiss(animated: false)
    }

    /// 前の待ちが終わった直後に段が変わったら、前の待ちは広げ直した範囲を戻さない。
    @Test func earlierWaitDoesNotNarrowWidenedAgainBarGrabArea() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let browser = InAppBrowser(tuning: TuningStore(defaults: nil), clock: clock)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        try await waitUntil { sheet.barGrabArea.superview != nil }
        let duration = Duration.seconds(TuningCatalog.inAppBrowserBarGrabSettlingDuration.defaultValue)
        let widened = CGFloat(TuningCatalog.inAppBrowserHandleHeight.defaultValue + TuningCatalog.inAppBrowserBarGrabSettlingHeight.defaultValue)

        sheet.widenBarGrabAreaWhileSettling()
        try await waitUntil { clock.sleeperCount(dueWithin: duration) >= 1 }
        clock.advance(by: duration)
        sheet.widenBarGrabAreaWhileSettling()
        try await waitUntil { clock.sleeperCount(dueWithin: duration) >= 1 }
        // 前の待ちの続きは、起こされた時点でメインアクターの列に入っているので、後ろに並んで終わるのを待つ。
        await Task { @MainActor in }.value

        #expect(sheet.barGrabArea.frame.height == widened)
        root.dismiss(animated: false)
    }

    /// 引ける範囲の高さを0にすると、Safariのバーの上に何も重ねない。
    @Test func zeroBarGrabHeightAddsNothing() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(0, for: TuningCatalog.inAppBrowserBarGrabHeight)
        let browser = InAppBrowser(tuning: tuning)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)

        #expect(sheet.barGrabArea.superview == nil)
        root.dismiss(animated: false)
    }

    /// シートの段を変えると、Safariも帯の下の範囲いっぱいに広がる。出したときの大きさのまま残ると、広げたシートの下が空く。
    @Test func safariFollowsSheetSize() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser()
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentationController)
        try await waitUntil { sheet.safari.viewIfLoaded?.window != nil }
        let before = sheet.view.bounds.height

        presentation.selectedDetentIdentifier = presentation.selectedDetentIdentifier == .large ? nil : .large
        sheet.view.window?.layoutIfNeeded()

        try await waitUntil { sheet.view.bounds.height != before }
        sheet.view.layoutIfNeeded()
        let safariFrame = sheet.safari.view.convert(sheet.safari.view.bounds, to: sheet.view)
        #expect(safariFrame.maxY == sheet.view.bounds.maxY)
        root.dismiss(animated: false)
    }

    /// 指を離してから大きさを変える設定では、指が触れている間はSafariの大きさを変えず、離したらシートに合わせる。
    @Test func safariResizesAfterFingerLiftsWhenEnabled() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let browser = makeBrowser(resizesOnRelease: true, clock: clock)
        let sheet = try await openSheet(with: browser, from: root)
        #expect(sheet.isWatchingFinger)
        let safariHeight = sheet.safari.view.frame.height
        let before = sheet.view.bounds.height
        let presentation = try #require(sheet.sheetPresentationController)

        sheet.isFingerDown = true
        presentation.selectedDetentIdentifier = .large
        sheet.view.window?.layoutIfNeeded()
        try await waitUntil { sheet.view.bounds.height != before }
        sheet.view.layoutIfNeeded()
        #expect(sheet.safari.view.frame.height == safariHeight)

        sheet.isFingerDown = false
        sheet.view.layoutIfNeeded()
        // 離したあとも、待つ時間が過ぎるまでは大きさを変えない。続けて届くシートの大きさの変化を1回にまとめるため。
        #expect(sheet.safari.view.frame.height == safariHeight)
        let delay = Duration.seconds(TuningCatalog.inAppBrowserSafariResizeDelay.defaultValue)
        try await waitUntil { clock.sleeperCount(dueWithin: delay) >= 1 }
        clock.advance(by: delay)
        try await waitUntil { sheet.safari.view.frame.height != safariHeight }
        let safariFrame = sheet.safari.view.convert(sheet.safari.view.bounds, to: sheet.view)
        #expect(safariFrame.maxY == sheet.view.bounds.maxY)
        root.dismiss(animated: false)
    }

    /// 既定では、指が触れている間もSafariの大きさをシートに合わせる。
    @Test func safariFollowsSheetWhileFingerIsDownByDefault() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = makeBrowser(resizesOnRelease: false, clock: TestClock())
        let sheet = try await openSheet(with: browser, from: root)
        let before = sheet.view.bounds.height
        let presentation = try #require(sheet.sheetPresentationController)

        sheet.isFingerDown = true
        presentation.selectedDetentIdentifier = .large
        sheet.view.window?.layoutIfNeeded()
        try await waitUntil { sheet.view.bounds.height != before }
        sheet.view.layoutIfNeeded()

        let safariFrame = sheet.safari.view.convert(sheet.safari.view.bounds, to: sheet.view)
        #expect(safariFrame.maxY == sheet.view.bounds.maxY)
        root.dismiss(animated: false)
    }

    /// シートの高さを決める間は、覆う高さを知らせず、決め終えてから知らせる。
    /// 知らせを受けたタイムラインが安全領域を変えると、UIKitが高さを決めている途中のシートに位置を聞き直し、入れ子になって落ちるため。
    @Test func reportsObscuredHeightAfterResolvingDetents() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser()
        var resolving = false
        var reportedWhileResolving = false
        var reported: [CGFloat] = []
        browser.onObscuredHeightChange = { height in
            if resolving { reportedWhileResolving = true }
            reported.append(height)
        }
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController?.sheetPresentationController)
        reported.removeAll()

        resolving = true
        let values = sheet.detents.map { $0.resolvedValue(in: DetentResolutionContext(maximumDetentValue: 1000)) }
        resolving = false

        #expect(values.contains { $0 != nil })
        #expect(!reportedWhileResolving)
        try await waitUntil { !reported.isEmpty }
        root.dismiss(animated: false)
    }

    private func makeBrowser(resizesOnRelease: Bool, clock: TestClock) -> InAppBrowser {
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(resizesOnRelease, for: TuningCatalog.inAppBrowserResizesSafariOnRelease)
        return InAppBrowser(tuning: tuning, clock: clock)
    }

    private func openSheet(with browser: InAppBrowser, from root: UIViewController) async throws -> InAppBrowserSheet {
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        try await waitUntil { sheet.safari.viewIfLoaded?.window != nil }
        return sheet
    }
}

private final class DetentResolutionContext: NSObject, UISheetPresentationControllerDetentResolutionContext {
    let containerTraitCollection = UITraitCollection(verticalSizeClass: .regular)
    let maximumDetentValue: CGFloat

    init(maximumDetentValue: CGFloat) {
        self.maximumDetentValue = maximumDetentValue
    }
}

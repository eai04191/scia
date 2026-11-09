import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.scratch, .serialized)
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

        container.setReservedHeight(160, cornerRadius: 44, duration: 0)
        #expect(content.view.frame == CGRect(x: 0, y: 0, width: 400, height: 640))
        #expect(content.view.layer.cornerRadius == 44)

        container.setReservedHeight(0, cornerRadius: 44, duration: 0)
        #expect(content.view.frame.height == 800)
        #expect(content.view.layer.cornerRadius == 0)
    }

    /// 手で伏せた高さまで下げたときだけ後ろの画面を縮める。開く途中に伏せた高さを通るときと、投稿欄のために下げたときは縮めない。
    @Test func docksOnlyWhenLoweredByHand() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser()
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

    /// シートは伏せた段でも画面の幅いっぱいに出す。
    @Test func collapsedSheetSpansScreenWidth() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let browser = InAppBrowser()
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

    /// 動いている途中は、ビューの行き先ではなく、画面に見えている引ける範囲に触れたものをシートで受ける。
    @Test func grabsSheetAtVisiblePositionWhileMoving() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(2, for: TuningCatalog.inAppBrowserDockDuration)
        let browser = InAppBrowser(tuning: tuning)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        let presentation = try #require(sheet.sheetPresentation)
        let window = try #require(sheet.view.window)
        #expect(presentation.moveGrabTarget(at: CGPoint(x: 200, y: sheet.view.frame.minY + 2), in: window) == nil)

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
        let browser = InAppBrowser()
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

    /// シートの外に触れたものは、中くらいの高さまでは後ろの画面へ通し、全画面では通さない。
    @Test func windowPassesTouchesOutsideSheet() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = ShakeDetectingWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let browser = InAppBrowser()
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

import SafariServices
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

    /// 伏せた段でも、Safariのビューは下限より縮めない。ツールバーをシートの下へはみ出させるため。
    @Test func safariKeepsMinimumHeight() throws {
        let sheet = InAppBrowserSheet(
            safari: SFSafariViewController(url: try #require(URL(string: "https://example.com"))),
            handleHeight: 0,
            barGrab: InAppBrowserSheet.BarGrab(height: 0, inset: 0, settlingHeight: 0, settlingDuration: .zero, isVisible: false),
            safariResizeDelay: .zero,
            clock: TestClock()
        )
        sheet.minimumSafariHeight = 500
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 90))
        #expect(sheet.safariFrame(in: container) == CGRect(x: 0, y: 0, width: 400, height: 500))
        container.frame.size.height = 700
        #expect(sheet.safariFrame(in: container) == CGRect(x: 0, y: 0, width: 400, height: 700))
    }

    /// 手で伏せた高さまで下げたときだけ後ろの画面を縮める。開く途中に伏せた高さを通るときと、投稿欄のために下げたときは縮めない。
    @Test func docksOnlyWhenLoweredByHand() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let browser = InAppBrowser(clock: clock)
        var docked: [CGFloat] = []
        var obscured: CGFloat = 0
        browser.onDockedHeightChange = { docked.append($0) }
        browser.onObscuredHeightChange = { obscured = $0 }
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false && obscured > 0 }
        #expect(docked.allSatisfy { $0 == 0 })
        let sheet = try #require(root.presentedViewController?.sheetPresentationController)
        let collapsed = sheet.detents[0].identifier

        browser.lowerForCompose()
        #expect(docked.last == 0)
        browser.restoreAfterCompose()

        sheet.selectedDetentIdentifier = collapsed
        browser.sheetPresentationControllerDidChangeSelectedDetentIdentifier(sheet)
        #expect(obscured == 0)
        try await clock.advance(afterSleeping: .seconds(AppDependencies.tuning.value(of: TuningCatalog.inAppBrowserDockSettleDelay)))
        try await waitUntil { (docked.last ?? 0) > 0 }

        sheet.selectedDetentIdentifier = .large
        browser.sheetPresentationControllerDidChangeSelectedDetentIdentifier(sheet)
        #expect(docked.last == 0)
        root.dismiss(animated: false)
    }
}

import SafariServices
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
        try await waitUntil { root.presentedViewController is SFSafariViewController && root.presentedViewController?.isBeingPresented == false }
        let first = try #require(root.presentedViewController)
        var closed = 0
        let sheet = ScheduleDateSheet(title: "予約の日時", date: Date(timeIntervalSince1970: 1_800_000_000), minimumDate: Date(timeIntervalSince1970: 1_700_000_000), confirmTitle: "決定") { _ in } onClose: {
            closed += 1
        }
        try await first.presentForTesting(sheet)

        browser.open(try #require(URL(string: "https://example.com/2")), from: root)

        try await waitUntil { root.presentedViewController is SFSafariViewController && root.presentedViewController !== first }
        #expect(root.presentedViewController?.presentedViewController == nil)
        #expect(closed == 1)
        #expect(browser.isPresented)
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
        try await waitUntil { root.presentedViewController is SFSafariViewController && root.presentedViewController?.isBeingPresented == false }
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
}

private final class DetentResolutionContext: NSObject, UISheetPresentationControllerDetentResolutionContext {
    let containerTraitCollection = UITraitCollection(verticalSizeClass: .regular)
    let maximumDetentValue: CGFloat

    init(maximumDetentValue: CGFloat) {
        self.maximumDetentValue = maximumDetentValue
    }
}

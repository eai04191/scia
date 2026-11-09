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
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
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
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
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
        let browser = InAppBrowser(tuning: .withoutBrowserMotion())
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
        let safariInset = CGFloat(TuningCatalog.inAppBrowserSafariTopInset.defaultValue)
        #expect(sheet.barGrabArea.frame == CGRect(x: inset, y: 0, width: sheet.view.bounds.width - inset * 2, height: safariInset + handle + height))
        root.dismiss(animated: false)
    }

    /// 引ける範囲の高さを0にすると、Safariのバーの上に何も重ねない。
    @Test func zeroBarGrabHeightAddsNothing() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let tuning = TuningStore.withoutBrowserMotion()
        tuning.setValue(0, for: TuningCatalog.inAppBrowserBarGrabHeight)
        let browser = InAppBrowser(tuning: tuning)
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)

        #expect(sheet.barGrabArea.superview == nil)
        root.dismiss(animated: false)
    }

    /// シートが止まったら、Safariをシートの見えている高さに合わせる。出したときの大きさのまま残ると、広げたシートの下が空く。
    @Test func safariFollowsSheetSize() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(0, for: TuningCatalog.inAppBrowserDockDuration)
        let browser = InAppBrowser(tuning: tuning, clock: clock)
        let sheet = try await openSheet(with: browser, from: root)
        let presentation = try #require(sheet.sheetPresentation)

        presentation.select(.large, animated: false)
        let delay = Duration.seconds(TuningCatalog.inAppBrowserSafariResizeDelay.defaultValue)
        try await clock.advance(afterSleeping: delay)
        let large = CGFloat(presentation.layout.large)
        try await waitUntil { sheet.safari.view.frame.maxY == large }
        root.dismiss(animated: false)
    }

    /// 伏せた段ではSafariを中くらいの高さのままにして、下のツールバーをシートの下へはみ出させる。
    @Test func safariKeepsMediumHeightWhenCollapsed() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let clock = TestClock()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(0, for: TuningCatalog.inAppBrowserDockDuration)
        let browser = InAppBrowser(tuning: tuning, clock: clock)
        let sheet = try await openSheet(with: browser, from: root)
        let presentation = try #require(sheet.sheetPresentation)

        presentation.select(.collapsed, animated: false)
        let delay = Duration.seconds(TuningCatalog.inAppBrowserSafariResizeDelay.defaultValue)
        try await clock.advance(afterSleeping: delay)
        let medium = try #require(presentation.layout.medium)
        try await waitUntil { sheet.safari.view.frame.maxY == CGFloat(medium) }
        root.dismiss(animated: false)
    }

    private func openSheet(with browser: InAppBrowser, from root: UIViewController) async throws -> InAppBrowserSheet {
        browser.open(try #require(URL(string: "https://example.com/1")), from: root)
        try await waitUntil { root.presentedViewController is InAppBrowserSheet && root.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(root.presentedViewController as? InAppBrowserSheet)
        try await waitUntil { sheet.safari.viewIfLoaded?.window != nil }
        return sheet
    }
}

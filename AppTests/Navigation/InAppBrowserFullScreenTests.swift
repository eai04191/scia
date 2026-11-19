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

    /// 読み込みの間は、伏せたシートのSafariを出す場所に重ね、見えているところの外とシートのバーを引ける範囲で触れたことは、下のウインドウへ通す。
    /// 通さないと、読み込みを待つ間にタイムラインもシートも触れなくなる。
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
        let grab = sheet.barGrabRectOnScreen
        #expect(overlay.hitTest(CGPoint(x: 30, y: top - 40), with: nil) == nil)
        #expect(overlay.hitTest(CGPoint(x: grab.midX, y: grab.maxY - 1), with: nil) == nil)
        #expect(overlay.hitTest(CGPoint(x: 30, y: top + 20), with: nil) != nil)
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

    private func openFullScreen(from root: UIViewController, frames: ManualFrameSource) async throws -> (InAppBrowser, InAppBrowserSheet, InAppBrowserOverlayWindow) {
        let scene = try #require(root.view.window?.windowScene)
        // 番地（ObjectIdentifier）だけで覚えると、解放されたウインドウの番地を新しいウインドウが使い回したときに取り違えるので、ウインドウを持ち続ける。
        let existing = scene.windows
        let browser = InAppBrowser(tuning: .withoutBrowserMotion(), settings: AppDependencies.settings, frameSource: frames)
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

import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 共有で投稿欄に入れるときに、一覧の上に重ねた画面のうち、ビューアとメニューだけを閉じる。
@MainActor
@Suite(.serialized)
struct ComposerRevealTests {
    private let notices = NoticeCenter()
    private let drag = DragToDismiss(distanceThreshold: 0.12, velocityThreshold: 0.8, smallestScale: 0.6, fadeDistance: 0.5, restoreDuration: 0.35)
    private let timing = MediaViewerController.Timing(openDuration: 0.1, closeDuration: 0.1, dragCloseBounce: 0, drawsUnderBars: true, openHandoffEnd: 0.3, openBarOverlapFadeStart: 0.7, handoffStart: 0.7, barOverlapFadeEnd: 0.3, savedChipDuration: 1.5, videoControlsHideDelay: 3, videoSkipEffectDuration: 0.3, doubleTapZoomDuration: 0.2)

    private func makeViewer() -> MediaViewerController {
        let attachment = MediaAttachment(id: "1", type: .image, url: URL(string: "https://x.example/1.png"), previewUrl: nil)
        return MediaViewerController(attachments: [attachment], startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, sourceTile: { _ in nil })
    }

    /// ビューアを閉じ、画面の重なりから外れてから続きを呼ぶ。続きで出すアラートが、閉じる途中のビューアに捨てられないようにするため。
    @Test func closesViewerBeforeContinuing() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        try await root.presentForTesting(makeViewer())

        var presentedWhenContinued: UIViewController??
        root.closeScreensForSharedContent { presentedWhenContinued = .some(root.presentedViewController) }

        try await waitUntil { presentedWhenContinued != nil }
        #expect(presentedWhenContinued == .some(nil))
    }

    /// 設定のように閉じない画面は残し、その上のビューアだけを閉じる。
    @Test func keepsOtherScreensAndClosesViewerAboveThem() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let settings = UIViewController()
        try await root.presentForTesting(settings)
        defer { settings.dismiss(animated: false) }
        try await settings.presentForTesting(makeViewer())

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        try await waitUntil { continued }
        #expect(root.presentedViewController === settings)
        #expect(settings.presentedViewController == nil)
    }

    /// 確認のアラートのように閉じない画面がいちばん手前にあれば、その奥のビューアも閉じない。
    @Test func keepsViewerBelowScreenThatStays() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let viewer = makeViewer()
        try await root.presentForTesting(viewer)
        defer { viewer.dismiss(animated: false) }
        let confirmation = UIViewController()
        try await viewer.presentForTesting(confirmation)
        defer { confirmation.dismiss(animated: false) }

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        #expect(continued)
        #expect(root.presentedViewController === viewer)
        #expect(viewer.presentedViewController === confirmation)
    }
}

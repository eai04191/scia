import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 共有で投稿欄に入れるときに、一覧の上に重ねた画面を閉じる。閉じると失うものがあると示した画面だけを残す。
@MainActor
@Suite(.scratch, .serialized)
struct ComposerRevealTests {
    private let notices = NoticeCenter()
    private let drag = DragToDismiss(distanceThreshold: 0.12, velocityThreshold: 0.8, smallestScale: 0.6, fadeDistance: 0.5, restoreDuration: 0.35)
    private let timing = MediaViewerController.Timing(openDuration: 0.1, closeDuration: 0.1, dragCloseBounce: 0, drawsUnderBars: true, openHandoffEnd: 0.3, openBarOverlapFadeStart: 0.7, handoffStart: 0.7, barOverlapFadeEnd: 0.3, savedChipDuration: 1.5, videoControlsHideDelay: 3, videoSkipEffectDuration: 0.3, doubleTapZoomDuration: 0.2)

    private func makeViewer() -> MediaViewerController {
        let attachment = MediaAttachment(id: "1", type: .image, url: URL(string: "https://x.example/1.png"), previewUrl: nil)
        return MediaViewerController(attachments: [attachment], startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, sourceTile: { _ in nil })
    }

    /// 書きかけがあり、下へのスワイプで閉じさせない画面。
    private func makeScreenWithUnsavedInput() -> UIViewController {
        let screen = UIViewController()
        screen.isModalInPresentation = true
        return screen
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

    /// 設定のように、残すと示していない画面は、種類を問わず閉じる。あとから足した画面でも、投稿欄が隠れたままにならないようにするため。
    @Test func closesScreensThatDoNotAskToStay() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let settings = UINavigationController(rootViewController: UIViewController())
        try await root.presentForTesting(settings)
        try await settings.presentForTesting(makeViewer())

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        try await waitUntil { continued }
        #expect(root.presentedViewController == nil)
    }

    /// ほかの画面の上に重ねたビューアも、ビューアの閉じ方で閉じる。下の画面からまとめて閉じると、閉じる動きを通らず、閉じ終えた知らせが届かない。
    /// 投稿欄は、メディアを選ぶシートの上に開いたビューアの閉じ終わりで、ビューアを出している扱いを解く。
    @Test func closesViewerAboveAnotherScreenItsOwnWay() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let sheet = UIViewController()
        try await root.presentForTesting(sheet)
        let viewer = makeViewer()
        var finishedClosing = false
        viewer.onCloseFinish = { finishedClosing = true }
        try await sheet.presentForTesting(viewer)

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        try await waitUntil { continued && finishedClosing }
        #expect(root.presentedViewController == nil)
    }

    /// ビューアの上に重ねた投稿欄のシートも、閉じたことを知らせてから閉じる。知らせないと、投稿欄はシートを出している扱いのまま残る。
    @Test func viewerNotifiesSheetAboveItWhenClosing() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let viewer = makeViewer()
        try await root.presentForTesting(viewer)
        var closed = 0
        let sheet = ScheduleDateSheet(title: "予約の日時", date: Date(timeIntervalSince1970: 1_800_000_000), minimumDate: Date(timeIntervalSince1970: 1_700_000_000), confirmTitle: "決定") { _ in } onClose: {
            closed += 1
        }
        try await viewer.presentForTesting(sheet)

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        try await waitUntil { continued }
        #expect(root.presentedViewController == nil)
        #expect(closed == 1)
    }

    /// 書きかけがあって閉じさせない画面は残し、その上のビューアだけを閉じる。
    @Test func keepsScreenWithUnsavedInputAndClosesViewerAboveIt() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let editor = makeScreenWithUnsavedInput()
        try await root.presentForTesting(editor)
        defer { editor.dismiss(animated: false) }
        try await editor.presentForTesting(makeViewer())

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        try await waitUntil { continued }
        #expect(root.presentedViewController === editor)
        #expect(editor.presentedViewController == nil)
    }

    /// プロフィールの編集のように、ナビゲーションに載せた中の画面が閉じさせないなら、ナビゲーションごと残す。
    @Test func keepsNavigationWhoseScreenHasUnsavedInput() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let navigation = UINavigationController(rootViewController: makeScreenWithUnsavedInput())
        try await root.presentForTesting(navigation)
        defer { navigation.dismiss(animated: false) }

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        #expect(continued)
        #expect(root.presentedViewController === navigation)
    }

    /// 通報のシートは、コメントを書くとSwiftUIで下へのスワイプを止め、その印で残る。
    @Test func keepsReportSheetWithComment() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let draft = ReportDraft(accountID: "2", acct: "bob", statusID: nil, api: ReportDraft.API(rules: { [] }, submit: { _ in }))
        draft.comment = "spam"
        let sheet = ReportView.sheet(draft: draft) {}
        try await root.presentForTesting(sheet)
        defer { sheet.dismiss(animated: false) }
        try await waitUntil { sheet.isModalInPresentation }

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        #expect(continued)
        #expect(root.presentedViewController === sheet)
    }

    /// 確認のアラートのように残す画面がいちばん手前にあれば、その奥のビューアも閉じない。
    @Test func keepsViewerBelowScreenThatStays() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let root = harness.viewController
        let viewer = makeViewer()
        try await root.presentForTesting(viewer)
        defer { viewer.dismiss(animated: false) }
        let confirmation = UIAlertController(title: "下書きを捨てますか？", message: nil, preferredStyle: .alert)
        confirmation.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        try await viewer.presentForTesting(confirmation)
        defer { confirmation.dismiss(animated: false) }

        var continued = false
        root.closeScreensForSharedContent { continued = true }

        #expect(continued)
        #expect(root.presentedViewController === viewer)
        #expect(viewer.presentedViewController === confirmation)
    }
}

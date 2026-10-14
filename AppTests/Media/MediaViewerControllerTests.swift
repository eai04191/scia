import SciaCore
import Testing
import UIKit
@testable import Scia

/// 閉じるボタンを置かないため、ほかの閉じ方とメニューが使えることを確かめる。
@MainActor
@Suite(.serialized)
struct MediaViewerControllerTests {
    private let drag = DragToDismiss(distanceThreshold: 0.12, velocityThreshold: 0.8, smallestScale: 0.6, fadeDistance: 0.5, restoreDuration: 0.35)

    private func image(_ id: String, url: URL?) -> MediaAttachment {
        MediaAttachment(id: id, type: .image, url: url, previewUrl: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("条件を満たさないまま時間切れになりました")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// VoiceOverの2本指のZで閉じる。
    @Test func accessibilityEscapeDismisses() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = MediaViewerController(attachments: [image("1", url: URL(string: "https://x.example/1.png"))], startIndex: 0, store: .offline, dragToDismiss: drag)
        harness.viewController.present(viewer, animated: false)
        #expect(harness.viewController.presentedViewController === viewer)

        #expect(viewer.accessibilityPerformEscape())

        try await waitUntil { harness.viewController.presentedViewController == nil }
    }

    /// キーボードのEscで閉じられる。
    @Test func escapeKeyCommandIsOffered() {
        let viewer = MediaViewerController(attachments: [image("1", url: nil)], startIndex: 0, store: .offline, dragToDismiss: drag)

        #expect(viewer.canBecomeFirstResponder)
        #expect(viewer.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape } == true)
    }

    /// メニューから共有できる。共有するものがなければ選べない。
    @Test func menuOffersShareOnlyWhenThereIsSomethingToShare() throws {
        let shareable = MediaViewerController(attachments: [image("1", url: URL(string: "https://x.example/1.png"))], startIndex: 0, store: .offline, dragToDismiss: drag)
        let processing = MediaViewerController(attachments: [image("2", url: nil)], startIndex: 0, store: .offline, dragToDismiss: drag)

        let share = try #require(shareable.menuElements().first as? UIAction)
        #expect(share.title == "共有")
        #expect(!share.attributes.contains(.disabled))
        let unavailable = try #require(processing.menuElements().first as? UIAction)
        #expect(unavailable.attributes.contains(.disabled))
    }

    /// ビューアは一覧を残したまま覆うため、開いている間は一覧の投稿を見たと報告せず、閉じ終わったら報告する。
    @Test func timelineReportsVisibleStatusesOnlyAfterViewerCloses() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 5, startingAt: 1_000)
        harness.setStatuses(statuses)
        var reported: [Status.ID] = []
        harness.viewController.onVisibleStatusesChange = { reported = $0 }
        MediaViewerController.present(
            attachments: [image("1", url: nil)],
            startIndex: 0,
            store: .offline,
            dragToDismiss: drag,
            from: harness.viewController,
            sourceView: { _ in nil },
            onDismiss: { harness.viewController.reportVisibleItems() }
        )
        let presented = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { !presented.isBeingPresented }

        harness.viewController.reportVisibleItems()
        #expect(reported.isEmpty, "ビューアで覆っている間に報告しました: \(reported.prefix(3))")

        presented.dismiss(animated: true)
        try await waitUntil { harness.viewController.presentedViewController == nil }
        #expect(reported.contains(statuses[0].id), "閉じたあとに報告しませんでした")
    }
}

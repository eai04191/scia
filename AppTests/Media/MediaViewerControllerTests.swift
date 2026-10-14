import SciaCore
import Testing
import UIKit
@testable import Scia

/// 閉じるボタンを置かないため、ほかの閉じ方とメニューが使えることを確かめる。
@MainActor
@Suite(.serialized)
struct MediaViewerControllerTests {
    private let drag = DragToDismiss(distanceThreshold: 0.12, velocityThreshold: 0.8, smallestScale: 0.6, fadeDistance: 0.5, restoreDuration: 0.35)

    private let timing = MediaViewerController.Timing(openDuration: 0.5, closeDuration: 0.5, bounce: 0, drawsUnderBars: true, openHandoffEnd: 0.3, openBarOverlapFadeStart: 0.7, handoffStart: 0.7, barOverlapFadeEnd: 0.3, savedChipDuration: 1.5)

    private func makeViewer(attachments: [MediaAttachment]) -> MediaViewerController {
        MediaViewerController(attachments: attachments, startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, sourceTile: { _ in nil })
    }

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

    /// 開いている間は、違和感レポートに表示中の画像の倍率と出どころが残る。画像が極端に小さく出る不具合の調べに使う。
    @Test func stateDumpIncludesZoomOfCurrentImage() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = makeViewer(attachments: [image("1", url: URL(string: "https://x.example/1.png"))])
        harness.viewController.present(viewer, animated: false)
        defer { viewer.dismiss(animated: false) }

        let dump = try #require(AppDependencies.stateDumps.dumpAll().first { $0.name == "mediaViewer" }?.text)
        #expect(dump.contains("imageSource: none"))
        #expect(dump.contains("zoomScale:"))
    }

    /// VoiceOverの2本指のZで閉じる。
    @Test func accessibilityEscapeDismisses() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = makeViewer(attachments: [image("1", url: URL(string: "https://x.example/1.png"))])
        harness.viewController.present(viewer, animated: false)
        #expect(harness.viewController.presentedViewController === viewer)

        #expect(viewer.accessibilityPerformEscape())

        try await waitUntil { harness.viewController.presentedViewController == nil }
    }

    /// キーボードのEscで閉じられる。
    @Test func escapeKeyCommandIsOffered() {
        let viewer = makeViewer(attachments: [image("1", url: nil)])

        #expect(viewer.canBecomeFirstResponder)
        #expect(viewer.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape } == true)
    }

    private func pngData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
    }

    /// 元の画像が少し遅れて届くビューアを、一覧の上に開く。
    private func presentLoadingViewer(
        on harness: TimelineHarness,
        data: Data,
        description: String? = nil,
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver { _ in }
    ) -> MediaViewerController {
        let store = MediaImageStore(originalsDirectory: .temporaryDirectory.appending(path: "MediaViewerControllerTests-\(UUID().uuidString)")) { _ in
            try await Task.sleep(for: .milliseconds(150))
            return data
        }
        let attachment = MediaAttachment(id: "1", type: .image, url: URL(string: "https://x.example/original/1"), previewUrl: nil, description: description)
        let viewer = MediaViewerController(attachments: [attachment], startIndex: 0, store: store, dragToDismiss: drag, timing: timing, photoSaver: photoSaver, sourceTile: { _ in nil })
        harness.viewController.present(viewer, animated: false)
        return viewer
    }

    private func menuAction(_ title: String, in viewer: MediaViewerController) -> UIAction? {
        viewer.menuElements().lazy.compactMap { $0 as? UIAction }.first { $0.title == title }
    }

    /// 画像は、元のファイルが届いてからメニューで共有と保存ができる。届く前にURLを共有しないよう、それまでは選べない。
    @Test func imageCanBeSharedAndSavedOnlyAfterOriginalArrives() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let data = try pngData()
        let viewer = presentLoadingViewer(on: harness, data: data)
        defer { viewer.dismiss(animated: false) }

        #expect(viewer.menuElements().compactMap { ($0 as? UIAction)?.title } == ["共有", "写真に保存"])
        #expect(try #require(menuAction("共有", in: viewer)).attributes.contains(.disabled))
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.contains(.disabled))

        try await waitUntil { menuAction("共有", in: viewer)?.attributes.contains(.disabled) == false }
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.isEmpty)
        let item = try #require(viewer.shareItem() as? MediaShareItem)
        #expect(item.file.lastPathComponent == "1.png")
        #expect(try Data(contentsOf: item.file) == data)
    }

    /// 写真には元のファイルをそのまま渡し、済んだらメニューボタンの下で知らせる。
    @Test func savingToPhotosPassesOriginalFileAndShowsChip() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let data = try pngData()
        let saved = SavedFiles()
        let viewer = presentLoadingViewer(on: harness, data: data, photoSaver: PhotoLibrarySaver { saved.files.append($0) })
        defer { viewer.dismiss(animated: false) }
        try await waitUntil { menuAction("写真に保存", in: viewer)?.attributes.isEmpty == true }

        viewer.saveToPhotos()

        try await waitUntil { viewer.statusChipText != nil }
        #expect(viewer.statusChipText == "写真に保存しました")
        let file = try #require(saved.files.first)
        #expect(try Data(contentsOf: file) == data)
    }

    /// 写真への追加が許可されていなければ、知らせる表示ではなくアラートで理由を出し、設定へ案内する。
    @Test func savingWithoutPermissionOffersSettings() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentLoadingViewer(on: harness, data: try pngData(), photoSaver: PhotoLibrarySaver { _ in throw PhotoLibrarySaver.NotAuthorized() })
        defer { viewer.dismiss(animated: false) }
        try await waitUntil { menuAction("写真に保存", in: viewer)?.attributes.isEmpty == true }

        viewer.saveToPhotos()

        try await waitUntil { viewer.presentedViewController is UIAlertController }
        let alert = try #require(viewer.presentedViewController as? UIAlertController)
        #expect(alert.actions.map(\.title) == ["設定を開く", "キャンセル"])
        #expect(viewer.statusChipText == nil)
        alert.dismiss(animated: false)
    }

    /// 画面下の説明は1行で見せ、全文はそこからシートで読む。VoiceOverでは払えないため、実行しても開く。
    @Test func captionOpensAltTextSheet() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentLoadingViewer(on: harness, data: try pngData(), description: "夕焼けの海辺")
        defer { viewer.dismiss(animated: false) }

        #expect(viewer.captionView.accessibilityLabel == "夕焼けの海辺")
        #expect(viewer.captionView.accessibilityActivate())

        try await waitUntil { viewer.presentedViewController is UINavigationController }
        let sheet = try #require(viewer.presentedViewController as? UINavigationController)
        #expect((sheet.viewControllers.first as? AltTextViewController)?.text == "夕焼けの海辺")
        sheet.dismiss(animated: false)
    }

    /// 代替テキストのシートの左上から、全文をシステムの翻訳シートで訳せる。
    @Test func altTextSheetOffersTranslation() throws {
        let sheet = AltTextViewController.sheet(text: "A sunset over the sea")
        let altText = try #require(sheet.viewControllers.first as? AltTextViewController)
        altText.loadViewIfNeeded()

        #expect(altText.navigationItem.leftBarButtonItem?.title == "翻訳")
        #expect(!altText.isTranslationPresented)
        altText.translate()
        #expect(altText.isTranslationPresented)
    }

    /// 保存を待つ間に代替テキストのシートを開いても、保存の失敗はそのシートの上にアラートで知らせる。
    @Test func saveFailureIsShownAboveSheetOpenedWhileSaving() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentLoadingViewer(on: harness, data: try pngData(), description: "夕焼けの海辺", photoSaver: PhotoLibrarySaver { _ in
            try await Task.sleep(for: .milliseconds(500))
            throw PhotoLibrarySaver.NotAuthorized()
        })
        defer { viewer.dismiss(animated: false) }
        try await waitUntil { menuAction("写真に保存", in: viewer)?.attributes.isEmpty == true }

        viewer.saveToPhotos()
        viewer.showAltText()
        try await waitUntil { viewer.presentedViewController is UINavigationController }

        let sheet = try #require(viewer.presentedViewController)
        try await waitUntil { sheet.presentedViewController is UIAlertController }
    }

    /// 代替テキストが付いていれば、メニューから全文をシートで出せる。
    @Test func altTextIsOfferedOnlyWhenPresent() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentLoadingViewer(on: harness, data: try pngData(), description: "夕焼けの海辺")
        defer { viewer.dismiss(animated: false) }
        let plain = makeViewer(attachments: [image("2", url: URL(string: "https://x.example/2.png"))])

        #expect(menuAction("代替テキスト", in: viewer) != nil)
        #expect(menuAction("代替テキスト", in: plain) == nil)

        viewer.showAltText()

        try await waitUntil { viewer.presentedViewController is UINavigationController }
        let sheet = try #require(viewer.presentedViewController as? UINavigationController)
        #expect((sheet.viewControllers.first as? AltTextViewController)?.text == "夕焼けの海辺")
        sheet.dismiss(animated: false)
    }

    /// 処理中でURLのない添付ファイルは、共有するものがないため選べない。
    @Test func menuDisablesShareWhenThereIsNothingToShare() throws {
        let processing = makeViewer(attachments: [image("2", url: nil)])

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
            timing: timing,
            from: harness.viewController,
            sourceTile: { _ in nil },
            onDismiss: { harness.viewController.reportVisibleItems() }
        )
        let presented = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { !presented.isBeingPresented }

        harness.viewController.reportVisibleItems()
        #expect(reported.isEmpty, "ビューアで覆っている間に報告しました: \(reported.prefix(3))")

        presented.close()
        try await waitUntil { harness.viewController.presentedViewController == nil }
        #expect(reported.contains(statuses[0].id), "閉じたあとに報告しませんでした")
    }

    /// 開閉の間はサムネイルとビューアの画像を隠して写しを動かし、開ききったら両方とも元どおり見せる。閉じる動きの間も一覧を操作でき、戻り終えたらサムネイルを見せる。
    @Test func transitionRestoresThumbnailAndContentAfterOpeningAndClosing() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 20, y: 200, width: 160, height: 90)
        harness.viewController.view.addSubview(tile)
        // 通信せずにビューアとサムネイルの両方へ画像を出すため、blurhashのぼかしを使う。
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: nil,
            previewUrl: nil,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_600, height: 900)),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
        tile.apply(attachment, hiddenCount: 0, isCovered: false, policy: .offline)
        MediaViewerController.present(
            attachments: [attachment],
            startIndex: 0,
            store: .offline,
            dragToDismiss: drag,
            timing: timing,
            from: harness.viewController,
            sourceTile: { _ in tile },
            onDismiss: {}
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        // 開く動きは画面に入るときに始まるため、写しが出るのを待つ。写しを出さなければ時間切れで失敗する。
        try await waitUntil { viewer.isContentHiddenForTransition }
        #expect(tile.isConcealedForViewer, "開いている間にサムネイルを隠していません")
        try await waitUntil { !viewer.isMoving }

        #expect(!tile.isConcealedForViewer)
        #expect(!viewer.isContentHiddenForTransition)

        viewer.close()

        // 閉じると決めた時点でビューアを閉じ、サムネイルへ戻る動きの途中でも一覧を操作できるようにする。
        // ビューアを残したまま動かすと、閉じた直後に別の画像を叩いても届かない。
        // ビューアを外すのは次の描画の機会になるため、それを待つ。写しが戻り終えるより先に外れていなければ失敗する。
        try await waitUntil { harness.viewController.presentedViewController == nil }
        let window = try #require(tile.window)
        let tapPoint = tile.convert(CGPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: window)
        let hit = window.hitTest(tapPoint, with: nil)
        #expect(hit === tile || hit?.isDescendant(of: tile) == true, "閉じる動きの間、サムネイルを叩いても届きません: \(String(describing: hit))")
        #expect(tile.isConcealedForViewer, "戻り終える前にサムネイルを見せています")

        try await waitUntil { !tile.isConcealedForViewer }
        #expect(viewer.view.superview == nil)
    }

    /// 開く途中は、バーの下のサムネイルと同じ見え方から始めるため、サムネイルを含む一覧の行の中にも写しを置く。開ききったら外し、最前面の写しのマスクも外す。
    @Test func openingDrawsUnderBarsUntilOpened() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        // 下端をバーに見立てた一覧。サムネイルの下半分がバーに隠れる。
        let list = UIScrollView(frame: harness.viewController.view.bounds)
        list.contentInsetAdjustmentBehavior = .never
        list.contentInset.bottom = 100
        harness.viewController.view.addSubview(list)
        let row = UIView(frame: CGRect(x: 0, y: list.bounds.height - 145, width: list.bounds.width, height: 90))
        list.addSubview(row)
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 20, y: 0, width: 160, height: 90)
        row.addSubview(tile)
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: nil,
            previewUrl: nil,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_600, height: 900)),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
        tile.apply(attachment, hiddenCount: 0, isCovered: false, policy: .offline)
        MediaViewerController.present(
            attachments: [attachment],
            startIndex: 0,
            store: .offline,
            dragToDismiss: drag,
            timing: timing,
            from: harness.viewController,
            sourceTile: { _ in tile },
            onDismiss: {}
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { viewer.isContentHiddenForTransition }
        #expect(row.subviews.contains { $0 !== tile }, "開く途中に一覧の行の中へ写しを置いていません")

        try await waitUntil { !viewer.isMoving }
        #expect(row.subviews.allSatisfy { $0 === tile }, "開ききったあとも一覧の行の中に写しが残っています")
        viewer.dismiss(animated: false)
    }

    /// 動画の回転情報から、再生中のコマを表示と同じ向きにする回し方を決める。端末を縦にして撮った動画は右へ90°回す。
    @Test func frameOrientationFollowsVideoRotation() {
        #expect(PlayerPageController.orientation(of: .identity) == .up)
        #expect(PlayerPageController.orientation(of: CGAffineTransform(rotationAngle: .pi / 2)) == .right)
        #expect(PlayerPageController.orientation(of: CGAffineTransform(rotationAngle: .pi)) == .down)
        #expect(PlayerPageController.orientation(of: CGAffineTransform(rotationAngle: -.pi / 2)) == .left)
        // 回転のほかに平行移動を含んでいても、向きだけで決める。
        #expect(PlayerPageController.orientation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1_080, ty: 0)) == .right)
    }

    /// 手元にプレビューもぼかしもない画像でも、開く途中に元の画像が届いたら、写しをその画像に差し替える。
    @Test func morphFollowsImageThatArrivesWhileOpening() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let arriving = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36), format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        let data = try #require(arriving.pngData())
        let store = MediaImageStore { _ in
            try await Task.sleep(for: .milliseconds(150))
            return data
        }
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 20, y: 200, width: 160, height: 90)
        harness.viewController.view.addSubview(tile)
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: nil,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 64, height: 36))
        )
        MediaViewerController.present(
            attachments: [attachment],
            startIndex: 0,
            store: store,
            dragToDismiss: drag,
            timing: MediaViewerController.Timing(openDuration: 1, closeDuration: 1, bounce: 0, drawsUnderBars: true, openHandoffEnd: 0.3, openBarOverlapFadeStart: 0.7, handoffStart: 0.7, barOverlapFadeEnd: 0.3, savedChipDuration: 1.5),
            from: harness.viewController,
            sourceTile: { _ in tile },
            onDismiss: {}
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { viewer.isContentHiddenForTransition }

        try await waitUntil { viewer.morphImage?.size == arriving.size }
        #expect(viewer.isMoving, "写しを差し替える前に開き終わりました")
    }

    /// ビューアは一覧を残したまま上に重ねるため、開いている間も閉じたあとも、一覧の読んでいる位置を動かさない。
    @Test func timelineKeepsPositionWhileViewerOpensAndCloses() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0.5)
        let offset = harness.collectionView.contentOffset
        let anchor = try #require(harness.viewController.displayedItemIDs.first { harness.windowMinY(of: $0) != nil })
        let anchorY = try #require(harness.windowMinY(of: anchor))
        let tile = MediaTileView(store: .offline)
        tile.frame = CGRect(x: 20, y: 300, width: 160, height: 90)
        harness.viewController.view.addSubview(tile)
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: nil,
            previewUrl: nil,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 900, height: 1_600)),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
        tile.apply(attachment, hiddenCount: 0, isCovered: false, policy: .offline)
        MediaViewerController.present(
            attachments: [attachment],
            startIndex: 0,
            store: .offline,
            dragToDismiss: drag,
            timing: timing,
            from: harness.viewController,
            sourceTile: { _ in tile },
            onDismiss: { harness.viewController.reportVisibleItems() }
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { viewer.isContentHiddenForTransition }
        try await waitUntil { !viewer.isMoving }
        harness.viewController.view.window?.layoutIfNeeded()

        #expect(harness.collectionView.contentOffset == offset, "開いている間に一覧が動きました")
        #expect(harness.windowMinY(of: anchor) == anchorY)

        viewer.close()
        try await waitUntil { harness.viewController.presentedViewController == nil && !tile.isConcealedForViewer }
        harness.viewController.view.window?.layoutIfNeeded()

        #expect(harness.collectionView.contentOffset == offset, "閉じたあとに一覧が動きました")
        #expect(harness.windowMinY(of: anchor) == anchorY)
    }
}

/// テストの写真の保存先が受け取ったファイル。
@MainActor
private final class SavedFiles {
    var files: [URL] = []
}

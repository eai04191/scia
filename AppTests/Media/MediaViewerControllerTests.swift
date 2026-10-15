import SciaCore
import Synchronization
import Testing
import UIKit
import VisionKit
@testable import Scia

/// 閉じるボタンを置かないため、ほかの閉じ方とメニューが使えることを確かめる。
@MainActor
@Suite(.serialized)
struct MediaViewerControllerTests {
    private let drag = DragToDismiss(distanceThreshold: 0.12, velocityThreshold: 0.8, smallestScale: 0.6, fadeDistance: 0.5, restoreDuration: 0.35)

    private let timing = MediaViewerController.Timing(openDuration: 0.5, closeDuration: 0.5, bounce: 0, drawsUnderBars: true, openHandoffEnd: 0.3, openBarOverlapFadeStart: 0.7, handoffStart: 0.7, barOverlapFadeEnd: 0.3, savedChipDuration: 1.5, savedChipAtBottom: false)

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

    /// 元の画像が少し遅れて届くビューアを、一覧の上に開く。共有や保存で元のファイルが整理で消えていたときは、`download`で落とし直す。
    private func presentLoadingViewer(
        on harness: TimelineHarness,
        data: Data,
        description: String? = nil,
        files: MediaFileCache = .temporary(),
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver { _ in },
        download: @escaping MediaDownloads.Download = { _, _, _ in throw URLError(.notConnectedToInternet) }
    ) -> MediaViewerController {
        let store = MediaImageStore(files: files) { _ in
            try await Task.sleep(for: .milliseconds(150))
            return data
        }
        let downloads = makeDownloads(files: files, download: download)
        let attachment = MediaAttachment(id: "1", type: .image, url: URL(string: "https://x.example/original/1"), previewUrl: nil, description: description)
        let viewer = MediaViewerController(attachments: [attachment], startIndex: 0, store: store, dragToDismiss: drag, timing: timing, photoSaver: photoSaver, downloads: downloads, sourceTile: { _ in nil })
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
    }

    /// 前に開いて元のファイルがキャッシュに残っていれば、表示のための読み込みを待たずに共有と保存を選べる。
    @Test func cachedOriginalEnablesSharingBeforeImageLoads() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://x.example/original/1"))
        _ = try await files.store(try pngData(), named: "1.png", for: url)
        let store = MediaImageStore(files: files) { _ in
            try await Task.sleep(for: .seconds(10))
            throw URLError(.timedOut)
        }
        let attachment = MediaAttachment(id: "1", type: .image, url: url, previewUrl: nil)
        let viewer = MediaViewerController(attachments: [attachment], startIndex: 0, store: store, dragToDismiss: drag, timing: timing, downloads: makeDownloads(files: files) { _, _, _ in throw URLError(.notConnectedToInternet) }, sourceTile: { _ in nil })
        harness.viewController.present(viewer, animated: false)
        defer { viewer.dismiss(animated: false) }

        try await waitUntil { menuAction("共有", in: viewer)?.attributes.contains(.disabled) == false }
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.isEmpty)
    }

    /// 写真には元のファイルの写しを、形式と名前を変えずに渡し、済んだらメニューボタンの下で知らせる。
    @Test func savingToPhotosPassesOriginalFileAndShowsChip() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let data = try pngData()
        let saved = SavedFiles()
        let files = MediaFileCache.temporary()
        let viewer = presentLoadingViewer(on: harness, data: data, files: files, photoSaver: PhotoLibrarySaver { saved.files.append($0) })
        defer { viewer.dismiss(animated: false) }
        try await waitUntil { menuAction("写真に保存", in: viewer)?.attributes.isEmpty == true }

        viewer.saveToPhotos()

        try await waitUntil { viewer.statusChipText != nil }
        #expect(viewer.statusChipText == "写真に保存しました")
        let file = try #require(saved.files.first)
        #expect(file.lastPathComponent == "1.png")
        #expect(file.path.hasPrefix(files.sharingDirectory.path))
        #expect(try Data(contentsOf: file) == data)
    }

    /// 開いている間に元のファイルが整理で消えていても、保存を選べば落とし直して保存する。選べるのに失敗しないようにするため。
    @Test func savingRefetchesOriginalRemovedFromCache() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let data = try pngData()
        let saved = SavedFiles()
        let files = MediaFileCache.temporary()
        let viewer = presentLoadingViewer(on: harness, data: data, files: files, photoSaver: PhotoLibrarySaver { saved.files.append($0) }) { url, folder, onProgress in
            onProgress(0.5)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "\(url.lastPathComponent).png")
            try data.write(to: file)
            return file
        }
        defer { viewer.dismiss(animated: false) }
        try await waitUntil { menuAction("写真に保存", in: viewer)?.attributes.isEmpty == true }
        try FileManager.default.removeItem(at: files.directory)

        viewer.saveToPhotos()

        try await waitUntil { viewer.statusChipText != nil }
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

    /// 投稿欄から開いたときの操作を受け取る。
    @MainActor
    private final class DraftActions {
        var commits: [(id: String, text: String)] = []
        var failures: [String] = []

        var editing: MediaViewerController.Editing {
            MediaViewerController.Editing(
                descriptionLimit: 20,
                descriptionRemainingThreshold: 5,
                descriptionMaxLines: 3,
                menuElements: { _ in [UIAction(title: "削除", attributes: .destructive) { _ in }] },
                commitDescription: { [self] id, text in commits.append((id, text)) },
                showFailure: { [self] id, _ in failures.append(id) }
            )
        }
    }

    private func draftItem(_ id: String, description: String = "", status: ComposeAttachmentStatus = .ready) -> MediaViewerItem {
        MediaViewerItem(id: id, kind: .image, description: description, file: nil, thumbnail: nil, status: status)
    }

    private func presentDraftViewer(on harness: TimelineHarness, items: [MediaViewerItem], actions: DraftActions) -> MediaViewerController {
        let viewer = MediaViewerController(items: items, startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, editing: actions.editing, sourceTile: { _ in nil })
        harness.viewController.present(viewer, animated: false)
        viewer.view.layoutIfNeeded()
        return viewer
    }

    /// 投稿欄から開いたとき、代替テキストが空でも帯に「代替テキストを追加」と出し、押すとキーボードの上の入力欄で書き始める。
    /// 書き終えた値は投稿欄に渡し、届く前から帯に出す。
    @Test func draftCaptionStartsEditingDescription() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a")], actions: actions)
        defer { viewer.dismiss(animated: false) }

        #expect(!viewer.captionView.isHidden)
        #expect(viewer.captionView.accessibilityLabel == "代替テキストを追加")
        #expect(viewer.captionView.accessibilityActivate())
        #expect(viewer.isEditingDescription)
        #expect(!viewer.descriptionEditor.isHidden)
        #expect(viewer.captionView.isHidden)

        viewer.descriptionEditor.text = "黒猫"
        viewer.endEditingDescription()

        #expect(!viewer.isEditingDescription)
        #expect(actions.commits.map(\.text) == ["黒猫"])
        #expect(actions.commits.map(\.id) == ["a"])
        #expect(viewer.captionView.accessibilityLabel == "黒猫")
    }

    /// 残りの文字数を出し始める数と入力欄の最大の行数は、投稿欄から渡した値を使う。
    @Test func draftEditingUsesGivenEditorTuning() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a")], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }

        #expect(viewer.descriptionEditor.remainingThreshold == 5)
        #expect(viewer.descriptionEditor.maxLines == 3)
    }

    /// 投稿欄から開いたときのメニューは、代替テキストの編集に、投稿欄から渡した項目を続ける。共有や保存は出さない。
    @Test func draftMenuOffersEditingAndGivenItems() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a")], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }

        #expect(viewer.menuElements().compactMap { ($0 as? UIAction)?.title } == ["代替テキストを編集", "削除"])
    }

    /// 書いている途中に左右へ切り替え始めたら、その時点の内容で、切り替える前の添付の代替テキストを確定する。
    @Test func switchingPageWhileEditingCommitsDescription() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a"), draftItem("b")], actions: actions)
        defer { viewer.dismiss(animated: false) }
        viewer.beginEditingDescription()
        viewer.descriptionEditor.text = "猫"

        viewer.pageViewController(UIPageViewController(), willTransitionTo: [])

        #expect(!viewer.isEditingDescription)
        #expect(actions.commits.map(\.id) == ["a"])
        #expect(actions.commits.map(\.text) == ["猫"])
    }

    /// 入力欄の右端のボタンを押したら、その時点の内容で書き終える。
    @Test func doneButtonCommitsDescription() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a")], actions: actions)
        defer { viewer.dismiss(animated: false) }
        viewer.beginEditingDescription()
        viewer.descriptionEditor.text = "猫"

        viewer.descriptionEditor.doneButton.sendActions(for: .primaryActionTriggered)

        #expect(!viewer.isEditingDescription)
        #expect(actions.commits.map(\.text) == ["猫"])
    }

    /// 書いている間に閉じる操作をしたら、書き終えてから閉じる。
    @Test func closingWhileEditingCommitsDescription() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a", description: "猫")], actions: actions)
        viewer.beginEditingDescription()
        viewer.descriptionEditor.text = "三毛猫"

        #expect(viewer.accessibilityPerformEscape())

        #expect(actions.commits.map(\.text) == ["三毛猫"])
        try await waitUntil { harness.viewController.presentedViewController == nil }
    }

    /// アップロードの状態は上の中央に出し、開いている間に変わったら描き直す。失敗したときだけ押せて、理由を出す操作を投稿欄に頼む。
    @Test func draftStatusFollowsUpdates() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a", status: .uploading)], actions: actions)
        defer { viewer.dismiss(animated: false) }

        #expect(!viewer.draftStatusButton.isHidden)
        #expect(viewer.draftStatusButton.configuration?.title == "アップロード中")
        #expect(!viewer.draftStatusButton.isUserInteractionEnabled)

        viewer.update(items: [draftItem("a", status: .failed)])
        #expect(viewer.draftStatusButton.configuration?.title == "アップロードできませんでした")
        viewer.draftStatusButton.sendActions(for: .primaryActionTriggered)
        #expect(actions.failures == ["a"])

        viewer.update(items: [draftItem("a", description: "猫", status: .ready)])
        #expect(viewer.draftStatusButton.isHidden)
        #expect(viewer.captionView.accessibilityLabel == "猫")
    }

    /// 書いている間は、画像を入力欄より上の範囲に収まるまで縮め、その範囲の中央に置く。上はボタンと重ねてよいので画面の上端から数える。
    @Test(arguments: [
        CGRect(x: 0, y: 200, width: 400, height: 225),  // 横長
        CGRect(x: 0, y: 112, width: 400, height: 400),  // 正方形
        CGRect(x: 50, y: 0, width: 300, height: 800),  // 縦長
        CGRect(x: 100, y: 300, width: 200, height: 100),  // 小さい
    ])
    func editingTransformFitsContentAboveEditor(content: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let available = CGRect(x: 0, y: 0, width: 400, height: 450)
        let transform = MediaViewerController.fittingTransform(content: content, into: available, in: bounds)

        // 変形は`bounds`の中央を軸にかかる。
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let moved = content.offsetBy(dx: -center.x, dy: -center.y).applying(transform).offsetBy(dx: center.x, dy: center.y)
        #expect(moved.minX >= available.minX - 0.5 && moved.maxX <= available.maxX + 0.5)
        #expect(moved.minY >= available.minY - 0.5 && moved.maxY <= available.maxY + 0.5)
        #expect(abs(moved.midX - available.midX) < 0.5 && abs(moved.midY - available.midY) < 0.5)
        #expect(moved.width <= content.width + 0.5)
        // 縮めるなら、どちらかの辺が範囲いっぱいになるまでにとどめる。
        if moved.width < content.width - 0.5 {
            #expect(abs(moved.width - available.width) < 0.5 || abs(moved.height - available.height) < 0.5)
        }
    }

    /// 拡大して画面からはみ出していれば、見えている部分（画面いっぱい）を収める。はみ出した画像全体に合わせて縮めすぎない。
    @Test func editingTransformFitsVisiblePartOfZoomedContent() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let available = CGRect(x: 0, y: 0, width: 400, height: 400)
        let zoomed = CGRect(x: -800, y: -1600, width: 2000, height: 4000)

        let transform = MediaViewerController.fittingTransform(content: zoomed, into: available, in: bounds)

        #expect(transform == MediaViewerController.fittingTransform(content: bounds, into: available, in: bounds))
        #expect(abs(transform.a - 0.5) < 0.001)
    }

    /// 読み込む前は種類が分からず画像として開くため、読み込んで動画と分かったら、表示中のページを動画のページに作り直す。
    @Test func pageIsRebuiltWhenLoadedMediaTurnsOutToBeVideo() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a", status: .uploading)], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }
        #expect(viewer.currentImagePage != nil)

        let file = LocalMediaFile(url: URL(filePath: "/tmp/a.mov"), mimeType: "video/quicktime", kind: .video)
        viewer.update(items: [MediaViewerItem(id: "a", kind: .video, description: "", file: file, thumbnail: nil, status: .uploading)])

        #expect(viewer.currentImagePage == nil)
        #expect(viewer.currentItem.kind == .video)
    }

    /// 横に払っている途中で切り替え先が動画と分かったら、切り替えを終えた時点で、残っていた画像のページを動画のページに差し替える。
    @Test func pendingPageIsRebuiltAfterTransitionWhenLoadedMediaTurnsOutToBeVideo() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentDraftViewer(on: harness, items: [draftItem("a"), draftItem("b", status: .uploading)], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }
        let swiping = UIPageViewController()
        let current = try #require(viewer.displayedPage)
        let pending = try #require(viewer.pageViewController(swiping, viewControllerAfter: current))
        #expect(pending is ImagePageController)

        let file = LocalMediaFile(url: URL(filePath: "/tmp/b.mov"), mimeType: "video/quicktime", kind: .video)
        viewer.update(items: [draftItem("a"), MediaViewerItem(id: "b", kind: .video, description: "", file: file, thumbnail: nil, status: .uploading)])
        swiping.setViewControllers([pending], direction: .forward, animated: false)
        viewer.pageViewController(swiping, didFinishAnimating: true, previousViewControllers: [current], transitionCompleted: true)

        #expect(viewer.currentIndex == 1)
        #expect(viewer.displayedPage is PlayerPageController)
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

    /// 画像から文字を読み取れたら、メニューからその全文を翻訳できる。文字のない画像では出さない。
    @Test(.enabled(if: ImageAnalyzer.isSupported, "Live Textに対応していない環境では解析しない"))
    func menuOffersTranslationOfRecognizedText() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let textImage = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            ("Hello World" as NSString).draw(at: CGPoint(x: 40, y: 140), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.black])
        }
        let viewer = presentLoadingViewer(on: harness, data: try #require(textImage.pngData()))
        try await waitUntil { menuAction("画像の文字を翻訳", in: viewer) != nil }
        viewer.dismiss(animated: false)

        let plain = presentLoadingViewer(on: harness, data: try pngData())
        defer { plain.dismiss(animated: false) }
        try await waitUntil { plain.currentImagePage?.hasFinishedAnalysis == true }
        #expect(menuAction("画像の文字を翻訳", in: plain) == nil)
    }

    /// 画像の文字のない場所を長押しすると、メニューボタンと同じメニューを出す。出すものがなければ出さない。
    @Test func longPressOnImageWithoutTextOffersMenu() throws {
        let page = ImagePageController(item: MediaViewerItem(image("1", url: nil)), store: .offline, preview: nil)
        page.loadViewIfNeeded()
        page.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        page.view.layoutIfNeeded()
        let interaction = try #require(contextMenuInteraction(in: page.view))
        let center = CGPoint(x: 195, y: 422)

        #expect(page.contextMenuInteraction(interaction, configurationForMenuAtLocation: center) == nil)
        page.menuElements = { [UIAction(title: "共有") { _ in }] }
        #expect(page.contextMenuInteraction(interaction, configurationForMenuAtLocation: center) != nil)
    }

    private func contextMenuInteraction(in view: UIView) -> UIContextMenuInteraction? {
        if let interaction = view.interactions.lazy.compactMap({ $0 as? UIContextMenuInteraction }).first {
            return interaction
        }
        return view.subviews.lazy.compactMap { contextMenuInteraction(in: $0) }.first
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

    private func makeDownloads(files: MediaFileCache = .temporary(), download: @escaping MediaDownloads.Download) -> MediaDownloads {
        MediaDownloads(files: files, stagingDirectory: .temporaryDirectory.appending(path: "MediaViewerControllerTests-\(UUID().uuidString)"), download: download)
    }

    /// 動画のビューアを、落とし方を差し替えて一覧の上に開く。
    private func presentVideoViewer(
        on harness: TimelineHarness,
        type: MediaAttachment.Kind = .video,
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver { _ in },
        download: @escaping MediaDownloads.Download
    ) -> MediaViewerController {
        let downloads = makeDownloads(download: download)
        let attachment = MediaAttachment(id: "1", type: type, url: URL(string: "https://x.example/original/1.mp4"), previewUrl: nil)
        let viewer = MediaViewerController(attachments: [attachment], startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, photoSaver: photoSaver, downloads: downloads, sourceTile: { _ in nil })
        harness.viewController.present(viewer, animated: false)
        return viewer
    }

    /// 少し時間をかけて落とし、途中で進み具合を半分まで伝える。
    private static func slowDownload(_ data: Data, duration: Duration = .milliseconds(300)) -> MediaDownloads.Download {
        { url, folder, onProgress in
            onProgress(0.5)
            try await Task.sleep(for: duration)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try data.write(to: file)
            return file
        }
    }

    /// 動画は、保存を選んでから落とし、落としている間は進み具合を出す。落とし終えたら写真に渡して知らせる。
    @Test func savingVideoDownloadsItFirstAndShowsProgress() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let data = Data("movie".utf8)
        let saved = SavedFiles()
        let viewer = presentVideoViewer(on: harness, photoSaver: PhotoLibrarySaver { saved.files.append($0) }, download: Self.slowDownload(data))
        defer { viewer.dismiss(animated: false) }
        #expect(viewer.menuElements().compactMap { ($0 as? UIAction)?.title } == ["共有", "写真に保存"])
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.isEmpty)

        viewer.saveToPhotos()

        try await waitUntil { viewer.downloadProgressText == "ダウンロード中 50%" }
        try await waitUntil { viewer.statusChipText != nil }
        #expect(viewer.statusChipText == "写真に保存しました")
        #expect(viewer.downloadProgressText == nil)
        let file = try #require(saved.files.first)
        #expect(file.lastPathComponent == "1.mp4")
        #expect(try Data(contentsOf: file) == data)
    }

    /// 落としている途中で取り消したら、通信を止め、保存しない。
    @Test func cancelingDownloadStopsItWithoutSaving() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let saved = SavedFiles()
        let stopped = Mutex(false)
        let viewer = presentVideoViewer(on: harness, photoSaver: PhotoLibrarySaver { saved.files.append($0) }) { _, _, _ in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                stopped.withLock { $0 = true }
                throw error
            }
            throw URLError(.timedOut)
        }
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()
        try await waitUntil { viewer.downloadProgressText != nil }
        viewer.cancelDownload()

        #expect(viewer.downloadProgressText == nil)
        try await waitUntil { stopped.withLock { $0 } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(saved.files.isEmpty)
        #expect(viewer.presentedViewController == nil)
    }

    /// ページを`index`の添付ファイルへ切り替える。スワイプで切り替え終えたときと同じ知らせをビューアに送る。
    private func showPage(_ index: Int, in viewer: MediaViewerController) throws {
        let pageViewController = try #require(viewer.children.lazy.compactMap { $0 as? UIPageViewController }.first)
        let current = try #require(pageViewController.viewControllers?.first)
        let next = index > viewer.currentIndex
            ? viewer.pageViewController(pageViewController, viewControllerAfter: current)
            : viewer.pageViewController(pageViewController, viewControllerBefore: current)
        pageViewController.setViewControllers([try #require(next)], direction: .forward, animated: false)
        viewer.pageViewController(pageViewController, didFinishAnimating: true, previousViewControllers: [current], transitionCompleted: true)
        #expect(viewer.currentIndex == index)
    }

    /// 動画を落としている途中に、落とし終えた別の動画へ移って保存したら、落としている途中のものは取り消す。
    /// 残すと進み具合が出たままになり、落とし終えたときに前に選んだ保存まで行われる。
    @Test func savingAnotherDownloadedVideoCancelsPendingDownload() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let saved = SavedFiles()
        let stopped = Mutex(false)
        let downloads = makeDownloads { url, folder, _ in
            if url.lastPathComponent == "slow.mp4" {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    stopped.withLock { $0 = true }
                    throw error
                }
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try Data("movie".utf8).write(to: file)
            return file
        }
        let attachments = ["slow", "fast"].map { MediaAttachment(id: $0, type: .video, url: URL(string: "https://x.example/original/\($0).mp4"), previewUrl: nil) }
        let viewer = MediaViewerController(attachments: attachments, startIndex: 1, store: .offline, dragToDismiss: drag, timing: timing, photoSaver: PhotoLibrarySaver { saved.files.append($0) }, downloads: downloads, sourceTile: { _ in nil })
        harness.viewController.present(viewer, animated: false)
        defer { viewer.dismiss(animated: false) }
        viewer.saveToPhotos()
        try await waitUntil { saved.files.count == 1 }

        try showPage(0, in: viewer)
        viewer.saveToPhotos()
        try await waitUntil { viewer.downloadProgressText != nil }
        try showPage(1, in: viewer)
        viewer.saveToPhotos()

        #expect(viewer.downloadProgressText == nil)
        try await waitUntil { stopped.withLock { $0 } }
        try await waitUntil { saved.files.count == 2 }
        #expect(saved.files.map(\.lastPathComponent) == ["fast.mp4", "fast.mp4"])
    }

    /// 落とせなかったら、理由をアラートで出す。
    @Test func downloadFailureIsShown() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentVideoViewer(on: harness) { _, _, _ in throw URLError(.notConnectedToInternet) }
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()

        try await waitUntil { viewer.presentedViewController is UIAlertController }
        #expect((viewer.presentedViewController as? UIAlertController)?.title == "ダウンロードできませんでした")
        #expect(viewer.downloadProgressText == nil)
        viewer.presentedViewController?.dismiss(animated: false)
    }

    /// 音声は写真に入らないため、共有だけを出す。
    @Test func audioOffersOnlySharing() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let viewer = presentVideoViewer(on: harness, type: .audio, download: Self.slowDownload(Data()))
        defer { viewer.dismiss(animated: false) }

        #expect(viewer.menuElements().compactMap { ($0 as? UIAction)?.title } == ["共有"])
        #expect(try #require(menuAction("共有", in: viewer)).attributes.isEmpty)
    }

    /// 動画やGIFのページでも、長押しでメニューボタンと同じメニューを出す。
    @Test func longPressOnPlayerOffersMenu() throws {
        let page = PlayerPageController(item: MediaViewerItem(MediaAttachment(id: "1", type: .gifv, url: nil, previewUrl: nil)))
        page.loadViewIfNeeded()
        page.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        page.view.layoutIfNeeded()
        let interaction = try #require(contextMenuInteraction(in: page.view))
        let center = CGPoint(x: 195, y: 422)

        #expect(page.contextMenuInteraction(interaction, configurationForMenuAtLocation: center) == nil)
        page.menuElements = { [UIAction(title: "共有") { _ in }] }
        #expect(page.contextMenuInteraction(interaction, configurationForMenuAtLocation: center) != nil)
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
        let store = MediaImageStore(files: .temporary()) { _ in
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
            timing: MediaViewerController.Timing(openDuration: 1, closeDuration: 1, bounce: 0, drawsUnderBars: true, openHandoffEnd: 0.3, openBarOverlapFadeStart: 0.7, handoffStart: 0.7, barOverlapFadeEnd: 0.3, savedChipDuration: 1.5, savedChipAtBottom: false),
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

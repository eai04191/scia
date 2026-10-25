import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
import VisionKit
@testable import Scia

/// 閉じるボタンを置かないため、ほかの閉じ方とメニューが使えることを確かめる。
@MainActor
@Suite(.serialized)
struct MediaViewerControllerTests {
    /// アプリ全体のアプリ内通知。ハーネスのウインドウに重ねた列と、落とす処理の両方に渡す。
    private let notices = NoticeCenter()
    /// メニューの並びなどを、テストを走らせる端末のアプリの設定に左右させないよう、テストごとの保存先を使う。
    private let settings: AppSettings
    private let drag = DragToDismiss(distanceThreshold: 0.12, velocityThreshold: 0.8, smallestScale: 0.6, fadeDistance: 0.5, restoreDuration: 0.35)

    private let timing = MediaViewerController.Timing(openDuration: 0.5, closeDuration: 0.5, dragCloseBounce: 0, drawsUnderBars: true, openHandoffEnd: 0.3, openBarOverlapFadeStart: 0.7, handoffStart: 0.7, barOverlapFadeEnd: 0.3, savedChipDuration: 1.5, videoControlsHideDelay: 3, videoSkipEffectDuration: 0.3, doubleTapZoomDuration: 0.2)

    init() throws {
        let suite = "MediaViewerControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
    }

    private func makeViewer(attachments: [MediaAttachment]) -> MediaViewerController {
        MediaViewerController(attachments: attachments, startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, settings: settings, sourceTile: { _ in nil })
    }

    private func image(_ id: String, url: URL?) -> MediaAttachment {
        MediaAttachment(id: id, type: .image, url: url, previewUrl: nil)
    }

    /// 開いている間は、違和感レポートに表示中の画像の倍率と取得元が残る。画像が極端に小さく出る不具合の調べに使う。
    @Test func stateDumpIncludesZoomOfCurrentImage() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = makeViewer(attachments: [image("1", url: URL(string: "https://x.example/1.png"))])
        try await harness.viewController.presentForTesting(viewer)
        defer { viewer.dismiss(animated: false) }

        // 登録簿はアプリ全体で1つで、並べて走るほかのテストのビューアも載っているため、このビューアのものを探す。
        let dump = viewer.stateDump()
        #expect(AppDependencies.stateDumps.dumpAll().contains { $0.name == "mediaViewer" && $0.text == dump })
        #expect(dump.contains("imageSource: none"))
        #expect(dump.contains("zoomScale:"))
    }

    /// VoiceOverの2本指のZで閉じる。
    @Test func accessibilityEscapeDismisses() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = makeViewer(attachments: [image("1", url: URL(string: "https://x.example/1.png"))])
        try await harness.viewController.presentForTesting(viewer)
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

    /// 元の画像を読み込むビューアを、一覧の上に開いて出し終えるまで待つ。共有や保存で元のファイルが整理で消えていたときは、`download`で落とし直す。
    /// - Parameter arrival: 開くまで元の画像を届けない。届く前の状態を確かめるテストは、閉じた門を渡して自分で開く。
    private func presentLoadingViewer(
        on harness: TimelineHarness,
        data: Data,
        arrival: Gate = Gate(isOpen: true),
        description: String? = nil,
        files: MediaFileCache = .temporary(),
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver { _ in },
        download: @escaping MediaDownloads.Download = { _, _, _ in throw URLError(.notConnectedToInternet) }
    ) async throws -> MediaViewerController {
        let store = MediaImageStore(files: files) { _, _ in
            try await arrival.wait()
            return data
        }
        let transfers = makeTransfers(downloads: makeDownloads(files: files, download: download), photoSaver: photoSaver)
        let attachment = MediaAttachment(id: "1", type: .image, url: URL(string: "https://x.example/original/1"), previewUrl: nil, description: description)
        let viewer = MediaViewerController(attachments: [attachment], startIndex: 0, store: store, dragToDismiss: drag, timing: timing, transfers: transfers, settings: settings, sourceTile: { _ in nil })
        try await harness.viewController.presentForTesting(viewer)
        return viewer
    }

    private func menuAction(_ title: String, in viewer: MediaViewerController) -> UIAction? {
        topLevelActions(of: viewer).first { $0.title == title }
    }

    /// メニューの最初の階層に並ぶ項目。区切り線で分けたまとまりの中も含め、「その他」などのサブメニューの中は含めない。
    private func topLevelActions(of viewer: MediaViewerController) -> [UIAction] {
        viewer.menuElements().flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            guard let group = element as? UIMenu, group.options.contains(.displayInline) else { return [] }
            return group.children.compactMap { $0 as? UIAction }
        }
    }

    private func topLevelTitles(of viewer: MediaViewerController) -> [String] {
        topLevelActions(of: viewer).map(\.title)
    }

    /// 画像は、元のファイルが届いてからメニューで共有と保存ができる。届く前にURLを共有しないよう、それまでは選べない。
    @Test func imageCanBeSharedAndSavedOnlyAfterOriginalArrives() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let data = try pngData()
        let arrival = Gate()
        let viewer = try await presentLoadingViewer(on: harness, data: data, arrival: arrival)
        defer { viewer.dismiss(animated: false) }

        #expect(topLevelTitles(of: viewer) == ["共有", "写真に保存", "リンクをコピー"])
        #expect(try #require(menuAction("共有", in: viewer)).attributes.contains(.disabled))
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.contains(.disabled))

        arrival.open()
        try await waitUntil { menuAction("共有", in: viewer)?.attributes.contains(.disabled) == false }
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.isEmpty)
    }

    /// 前に開いて元のファイルがキャッシュに残っていれば、表示のための読み込みを待たずに共有と保存を選べる。
    @Test func cachedOriginalEnablesSharingBeforeImageLoads() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://x.example/original/1"))
        _ = try await files.store(try pngData(), named: "1.png", for: url, generation: 0)
        // 表示のための読み込みは、取り消されるまで届かない。
        let store = MediaImageStore(files: files) { _, _ in
            try await Gate().wait()
            throw URLError(.timedOut)
        }
        let attachment = MediaAttachment(id: "1", type: .image, url: url, previewUrl: nil)
        let transfers = makeTransfers(downloads: makeDownloads(files: files) { _, _, _ in throw URLError(.notConnectedToInternet) })
        let viewer = MediaViewerController(attachments: [attachment], startIndex: 0, store: store, dragToDismiss: drag, timing: timing, transfers: transfers, settings: settings, sourceTile: { _ in nil })
        try await harness.viewController.presentForTesting(viewer)
        defer { viewer.dismiss(animated: false) }

        try await waitUntil { menuAction("共有", in: viewer)?.attributes.contains(.disabled) == false }
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.isEmpty)
    }

    /// 写真には元のファイルのコピーを、形式と名前を変えずに渡し、済んだらメニューボタンの下で知らせる。
    @Test func savingToPhotosPassesOriginalFileAndShowsChip() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let data = try pngData()
        let saved = SavedFiles()
        let files = MediaFileCache.temporary()
        let viewer = try await presentLoadingViewer(on: harness, data: data, files: files, photoSaver: PhotoLibrarySaver { saved.files.append($0) })
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
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let data = try pngData()
        let saved = SavedFiles()
        let files = MediaFileCache.temporary()
        let viewer = try await presentLoadingViewer(on: harness, data: data, files: files, photoSaver: PhotoLibrarySaver { saved.files.append($0) }) { url, folder, onProgress in
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

    /// アプリ全体のチップは、ビューアを開くとメニューボタンの行の下へ動き、閉じると一覧の位置へ戻る。消えずに同じチップのまま残る。
    @Test func appWideChipMovesBetweenListAndViewer() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        notices.showTransient(.linkCopied, duration: 60)
        let column = harness.overlay.column
        harness.window.layoutIfNeeded()
        let onList = column.frame.minY
        let chip = try #require(column.stack.chips.first)

        let viewer = makeViewer(attachments: [image("1", url: nil)])
        viewer.frameSource = harness.frames
        try await harness.viewController.presentForTesting(viewer)
        harness.frames.runUntilStopped()
        #expect(!viewer.isMoving)
        #expect(abs(column.frame.minY - viewer.noticePlacement(below: onList).top) < 1)
        #expect(harness.window.subviews.last === harness.overlay)
        #expect(column.stack.chips.first === chip)

        #expect(viewer.accessibilityPerformEscape())
        try await waitUntil { harness.viewController.presentedViewController == nil }
        #expect(column.frame.minY == onList)
        #expect(column.stack.chips.first === chip)
        harness.frames.runUntilStopped()
    }

    /// シートの上でビューアを開いて閉じたら、チップの列を根の画面のすぐ上に戻し、残ったシートが列を覆うようにする。
    @Test func closingViewerOverSheetReturnsOverlayBelowSheet() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let sheet = UIViewController()
        try await harness.viewController.presentForTesting(sheet)
        defer { sheet.dismiss(animated: false) }
        let viewer = makeViewer(attachments: [image("1", url: nil)])
        viewer.frameSource = harness.frames
        try await sheet.presentForTesting(viewer)
        harness.frames.runUntilStopped()
        #expect(!viewer.isMoving)
        #expect(harness.window.subviews.last === harness.overlay)

        #expect(viewer.accessibilityPerformEscape())
        try await waitUntil { sheet.presentedViewController == nil }
        let sheetContainer = try #require(harness.window.subviews.first { sheet.view.isDescendant(of: $0) })
        harness.frames.runUntilStopped()
        let order = harness.window.subviews
        #expect((order.firstIndex(of: harness.overlay) ?? 0) < (order.firstIndex(of: sheetContainer) ?? 0))
    }

    /// 写真への追加が許可されていなければ、知らせる表示ではなくアラートで理由を出し、設定へ案内する。
    @Test func savingWithoutPermissionOffersSettings() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentLoadingViewer(on: harness, data: try pngData(), photoSaver: PhotoLibrarySaver { _ in throw PhotoLibrarySaver.NotAuthorized() })
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

    private func presentDraftViewer(on harness: TimelineHarness, items: [MediaViewerItem], actions: DraftActions) async throws -> MediaViewerController {
        let viewer = MediaViewerController(items: items, startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, editing: actions.editing, settings: settings, sourceTile: { _ in nil })
        try await harness.viewController.presentForTesting(viewer)
        viewer.view.layoutIfNeeded()
        return viewer
    }

    /// 投稿欄から開いたとき、代替テキストが空でも帯に「代替テキストを追加」と出し、押すとキーボードの上の入力欄で書き始める。
    /// 書き終えた値は投稿欄に渡し、届く前から帯に出す。
    @Test func draftCaptionStartsEditingDescription() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a")], actions: actions)
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
    @Test func draftEditingUsesGivenEditorTuning() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a")], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }

        #expect(viewer.descriptionEditor.remainingThreshold == 5)
        #expect(viewer.descriptionEditor.maxLines == 3)
    }

    /// 投稿欄から開いたときのメニューは、代替テキストの編集に、投稿欄から渡した項目を続ける。共有や保存は出さない。
    @Test func draftMenuOffersEditingAndGivenItems() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a")], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }

        #expect(viewer.menuElements().compactMap { ($0 as? UIAction)?.title } == ["代替テキストを編集", "削除"])
    }

    /// 書いている途中に左右へ切り替え始めたら、その時点の内容で、切り替える前の添付の代替テキストを確定する。
    @Test func switchingPageWhileEditingCommitsDescription() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a"), draftItem("b")], actions: actions)
        defer { viewer.dismiss(animated: false) }
        viewer.beginEditingDescription()
        viewer.descriptionEditor.text = "猫"

        viewer.pageViewController(UIPageViewController(), willTransitionTo: [])

        #expect(!viewer.isEditingDescription)
        #expect(actions.commits.map(\.id) == ["a"])
        #expect(actions.commits.map(\.text) == ["猫"])
    }

    /// 入力欄の右端のボタンを押したら、その時点の内容で書き終える。
    @Test func doneButtonCommitsDescription() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a")], actions: actions)
        defer { viewer.dismiss(animated: false) }
        viewer.beginEditingDescription()
        viewer.descriptionEditor.text = "猫"

        viewer.descriptionEditor.doneButton.sendActions(for: .primaryActionTriggered)

        #expect(!viewer.isEditingDescription)
        #expect(actions.commits.map(\.text) == ["猫"])
    }

    /// 書いている間に閉じる操作をしたら、書き終えてから閉じる。
    @Test func closingWhileEditingCommitsDescription() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a", description: "猫")], actions: actions)
        viewer.beginEditingDescription()
        viewer.descriptionEditor.text = "三毛猫"

        #expect(viewer.accessibilityPerformEscape())

        #expect(actions.commits.map(\.text) == ["三毛猫"])
        try await waitUntil { harness.viewController.presentedViewController == nil }
    }

    /// アップロードの状態は上の中央に出たままのチップで出し、開いている間に変わったら描き直す。失敗したときだけ押せて、理由を出す操作を投稿欄に頼む。
    @Test func draftStatusFollowsUpdates() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let actions = DraftActions()
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a", status: .uploading)], actions: actions)
        defer { viewer.dismiss(animated: false) }

        // この画面だけのチップは、ビューアが画面に載ってからチップの列に差し出す。
        try await waitUntil { viewer.noticeStack?.chips.first != nil }
        let uploading = try #require(viewer.noticeStack?.chips.first)
        #expect(viewer.noticeStack?.persistentNotice?.text == "アップロード中")
        #expect(!uploading.accessibilityTraits.contains(.button))

        viewer.update(items: [draftItem("a", status: .failed)])
        let failed = try #require(viewer.noticeStack?.chips.first)
        #expect(failed === uploading)
        #expect(viewer.noticeStack?.persistentNotice?.text == "アップロードできませんでした")
        #expect(failed.accessibilityTraits.contains(.button))
        failed.sendActions(for: .primaryActionTriggered)
        #expect(actions.failures == ["a"])

        viewer.update(items: [draftItem("a", description: "猫", status: .ready)])
        #expect(viewer.noticeStack?.persistentNotice == nil)
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
    @Test func pageIsRebuiltWhenLoadedMediaTurnsOutToBeVideo() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a", status: .uploading)], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }
        #expect(viewer.currentImagePage != nil)

        let file = LocalMediaFile(url: URL(filePath: "/tmp/a.mov"), mimeType: "video/quicktime", kind: .video)
        viewer.update(items: [MediaViewerItem(id: "a", kind: .video, description: "", file: file, thumbnail: nil, status: .uploading)])

        #expect(viewer.currentImagePage == nil)
        #expect(viewer.currentItem.kind == .video)
    }

    /// 投稿欄で動画をGIFとして送るよう切り替えたら、同じ再生のページでも作り直し、GIFのくり返す再生にする。戻したら動画のページに戻す。
    @Test func pageIsRebuiltWhenVideoIsSwitchedToGIF() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let file = LocalMediaFile(url: URL(filePath: "/tmp/a.mov"), mimeType: "video/quicktime", kind: .video)
        let video = MediaViewerItem(id: "a", kind: .video, description: "", file: file, thumbnail: nil, status: .ready)
        let viewer = try await presentDraftViewer(on: harness, items: [video], actions: DraftActions())
        defer { viewer.dismiss(animated: false) }
        let videoPage = try #require(viewer.displayedPage as? PlayerPageController)
        #expect(videoPage.loopMenuAction() != nil)

        viewer.update(items: [MediaViewerItem(id: "a", kind: .gifv, description: "", file: file, thumbnail: nil, status: .uploading)])

        let gifPage = try #require(viewer.displayedPage as? PlayerPageController)
        #expect(gifPage !== videoPage)
        // GIFはもとからくり返すので、ループ再生の項目を出さない。
        #expect(gifPage.loopMenuAction() == nil)

        viewer.update(items: [video])

        #expect((viewer.displayedPage as? PlayerPageController)?.loopMenuAction() != nil)
    }

    /// 横にスワイプしている途中で切り替え先が動画と分かったら、切り替えを終えた時点で、残っていた画像のページを動画のページに差し替える。
    @Test func pendingPageIsRebuiltAfterTransitionWhenLoadedMediaTurnsOutToBeVideo() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentDraftViewer(on: harness, items: [draftItem("a"), draftItem("b", status: .uploading)], actions: DraftActions())
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

    /// 画面下の説明は1行で見せ、全文はそこからシートで読む。VoiceOverではスワイプできないため、実行しても開く。
    @Test func captionOpensAltTextSheet() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentLoadingViewer(on: harness, data: try pngData(), description: "夕焼けの海辺")
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
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let textImage = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            ("Hello World" as NSString).draw(at: CGPoint(x: 40, y: 140), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.black])
        }
        let viewer = try await presentLoadingViewer(on: harness, data: try #require(textImage.pngData()))
        try await waitUntil { menuAction("画像の文字を翻訳", in: viewer) != nil }
        viewer.dismiss(animated: false)

        let plain = try await presentLoadingViewer(on: harness, data: try pngData())
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

    /// ボタンと説明を隠したまま、まだ作っていない動画のページへ移ったら、作った時点で再生の操作の部品も隠す。
    /// 隠している間は部品の上でもタッチを受けず、下の動画のタップに渡す。
    @Test func videoControlsStartHiddenWhenChromeIsHidden() throws {
        let file = LocalMediaFile(url: URL(filePath: "/tmp/v.mov"), mimeType: "video/quicktime", kind: .video)
        let page = PlayerPageController(item: MediaViewerItem(id: "v", kind: .video, description: "", file: file, thumbnail: nil, status: .ready))
        page.setChromeHidden(true, animated: false)
        page.loadViewIfNeeded()
        page.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        page.view.layoutIfNeeded()
        let controls = try #require(page.view.subviews.lazy.compactMap { $0 as? VideoControlsView }.first)
        let playButton = CGPoint(x: 195, y: 422)

        #expect(!controls.point(inside: playButton, with: nil))
        page.setChromeHidden(false, animated: false)
        #expect(controls.point(inside: playButton, with: nil))
    }

    /// 投稿欄で動画を書き出し終えたら、開いているページも書き出したファイルに替え、投稿される中身を確かめられるようにする。
    /// プレイヤーは作り直さず、再生する項目だけを替える。表示中に`AVPlayerViewController`のプレイヤーを作り直すと、映像を描かなくなるため。
    /// GIFとして送る動画も、音声を除き終えたら同じく替える。
    @Test(arguments: [MediaAttachment.Kind.video, .gifv])
    func playerSwitchesToTheExportedFile(kind: MediaAttachment.Kind) throws {
        let original = LocalMediaFile(url: URL(filePath: "/tmp/original.mov"), mimeType: "video/quicktime", kind: .video)
        let exported = LocalMediaFile(url: URL(filePath: "/tmp/prepared-original.mp4"), mimeType: "video/mp4", kind: .video)
        let page = PlayerPageController(item: MediaViewerItem(id: "v", kind: kind, description: "", file: original, thumbnail: nil, status: .exporting, progress: 0.3))
        page.loadViewIfNeeded()
        #expect(page.playingURL == original.url)
        let player = try #require(page.player)

        page.update(MediaViewerItem(id: "v", kind: kind, description: "", file: exported, thumbnail: nil, status: .uploading, progress: 0.6))
        #expect(page.playingURL == exported.url)
        #expect(page.player === player)
    }

    /// 動画の長押しは2倍速に使うため、メニューを出さない。メニューは右上のボタンから開く。
    @Test func longPressOnVideoDoesNotOfferMenu() {
        let file = LocalMediaFile(url: URL(filePath: "/tmp/v.mov"), mimeType: "video/quicktime", kind: .video)
        let page = PlayerPageController(item: MediaViewerItem(id: "v", kind: .video, description: "", file: file, thumbnail: nil, status: .ready))
        page.loadViewIfNeeded()

        // 標準の再生画面は内部に自前のメニューの仕組みを持つことがあるため、ページが付けたものだけを見る。
        #expect(!allContextMenuInteractions(in: page.view).contains { $0.delegate === page })
        #expect(page.view.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer } == true)
    }

    /// 再生していて部品を出しているときだけ自動で隠す。止めている間、シークバーを動かしたりメニューを開いたりしている間、VoiceOverが動いている間は隠さない。
    @Test func videoControlsHideAutomaticallyOnlyWhilePlayingWithoutVoiceOver() {
        #expect(PlayerPageController.hidesAutomatically(isPlaying: true, isShown: true, isInteracting: false, isVoiceOverRunning: false))
        #expect(!PlayerPageController.hidesAutomatically(isPlaying: true, isShown: true, isInteracting: false, isVoiceOverRunning: true))
        #expect(!PlayerPageController.hidesAutomatically(isPlaying: false, isShown: true, isInteracting: false, isVoiceOverRunning: false))
        #expect(!PlayerPageController.hidesAutomatically(isPlaying: true, isShown: true, isInteracting: true, isVoiceOverRunning: false))
        #expect(!PlayerPageController.hidesAutomatically(isPlaying: true, isShown: false, isInteracting: false, isVoiceOverRunning: false))
    }

    /// 動画の左の3分の1をダブルタップすると10秒戻り、右の3分の1で10秒進む。真ん中では動かさない。
    @Test(arguments: [(CGFloat(10), -10.0 as Double?), (130, -10), (135, nil), (200, nil), (265, nil), (270, 10), (390, 10)])
    func doubleTapSkipsByRegion(x: CGFloat, expected: Double?) {
        #expect(PlayerPageController.skipSeconds(forDoubleTapAt: x, width: 402) == expected)
    }

    /// 10秒の矢印は、回っている途中で続けて回しても、元の向き（1回転の倍数）で止まる。少なくとも半回転は回して、回ったと分かるようにする。
    @Test(arguments: [0, 0.5, 1.2, 2 * Double.pi, 2 * Double.pi + 0.3])
    func skipArrowAlwaysStopsUpright(current: Double) {
        let turn = 2 * Double.pi
        let forward = SkipArrowSpin.target(from: current, forward: true)
        let backward = SkipArrowSpin.target(from: current, forward: false)
        #expect(abs(forward.remainder(dividingBy: turn)) < 1e-9)
        #expect(abs(backward.remainder(dividingBy: turn)) < 1e-9)
        #expect(forward - current >= Double.pi)
        #expect(current - backward >= Double.pi)
    }

    /// ループ再生は、その動画を見ている間だけ切り替える。最初は切っていて、入れたらメニューにチェックマークを付け、最後まで再生したら先頭から続ける。
    @Test func loopPlaybackTogglesPerVideo() throws {
        let file = LocalMediaFile(url: URL(filePath: "/tmp/v.mov"), mimeType: "video/quicktime", kind: .video)
        let page = PlayerPageController(item: MediaViewerItem(id: "v", kind: .video, description: "", file: file, thumbnail: nil, status: .ready))
        page.loadViewIfNeeded()
        #expect(page.loopMenuAction()?.title == "ループ再生")
        #expect(page.loopMenuAction()?.state == .off)

        page.setLooping(true)
        #expect(page.loopMenuAction()?.state == .on)
        #expect(page.isLooping)

        let another = PlayerPageController(item: MediaViewerItem(id: "w", kind: .video, description: "", file: file, thumbnail: nil, status: .ready))
        another.loadViewIfNeeded()
        #expect(another.loopMenuAction()?.state == .off)
    }

    /// GIFはもとからくり返すため、ループ再生の項目を出さない。
    @Test func gifDoesNotOfferLoopPlayback() {
        let file = LocalMediaFile(url: URL(filePath: "/tmp/g.mp4"), mimeType: "video/mp4", kind: .gifv)
        let page = PlayerPageController(item: MediaViewerItem(id: "g", kind: .gifv, description: "", file: file, thumbnail: nil, status: .ready))
        page.loadViewIfNeeded()
        #expect(page.loopMenuAction() == nil)
    }

    private func allContextMenuInteractions(in view: UIView) -> [UIContextMenuInteraction] {
        view.interactions.compactMap { $0 as? UIContextMenuInteraction } + view.subviews.flatMap { allContextMenuInteractions(in: $0) }
    }

    private func contextMenuInteraction(in view: UIView) -> UIContextMenuInteraction? {
        if let interaction = view.interactions.lazy.compactMap({ $0 as? UIContextMenuInteraction }).first {
            return interaction
        }
        return view.subviews.lazy.compactMap { contextMenuInteraction(in: $0) }.first
    }

    /// 保存を待つ間に代替テキストのシートを開いても、保存の失敗はそのシートの上にアラートで知らせる。
    @Test func saveFailureIsShownAboveSheetOpenedWhileSaving() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let saving = Gate()
        let viewer = try await presentLoadingViewer(on: harness, data: try pngData(), description: "夕焼けの海辺", photoSaver: PhotoLibrarySaver { _ in
            try await saving.wait()
            throw PhotoLibrarySaver.NotAuthorized()
        })
        defer { viewer.dismiss(animated: false) }
        try await waitUntil { menuAction("写真に保存", in: viewer)?.attributes.isEmpty == true }

        viewer.saveToPhotos()
        viewer.showAltText()
        try await waitUntil { (viewer.presentedViewController as? UINavigationController)?.isBeingPresented == false }

        let sheet = try #require(viewer.presentedViewController)
        saving.open()
        try await waitUntil { sheet.presentedViewController is UIAlertController }
    }

    /// 代替テキストが付いていれば、メニューから全文をシートで出せる。
    @Test func altTextIsOfferedOnlyWhenPresent() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentLoadingViewer(on: harness, data: try pngData(), description: "夕焼けの海辺")
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

    private func makeTransfers(
        downloads: MediaDownloads,
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver { _ in },
        operationStatus: OperationStatus = OperationStatus()
    ) -> MediaTransferCenter {
        MediaTransferCenter(operationStatus: operationStatus, notices: notices, downloads: downloads, photoSaver: photoSaver)
    }

    /// 動画のビューアを、落とし方を差し替えて一覧の上に開く。
    private func presentVideoViewer(
        on harness: TimelineHarness,
        type: MediaAttachment.Kind = .video,
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver { _ in },
        transfers: MediaTransferCenter? = nil,
        download: @escaping MediaDownloads.Download
    ) async throws -> MediaViewerController {
        let transfers = transfers ?? makeTransfers(downloads: makeDownloads(download: download), photoSaver: photoSaver)
        let attachment = MediaAttachment(id: "1", type: type, url: URL(string: "https://x.example/original/1.mp4"), previewUrl: nil)
        let viewer = MediaViewerController(attachments: [attachment], startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, transfers: transfers, settings: settings, sourceTile: { _ in nil })
        try await harness.viewController.presentForTesting(viewer)
        return viewer
    }

    /// 進み具合を半分まで伝え、`release`が開くまで落とし終えない。
    private static func gatedDownload(_ data: Data, release: Gate) -> MediaDownloads.Download {
        { url, folder, onProgress in
            onProgress(0.5)
            try await release.wait()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try data.write(to: file)
            return file
        }
    }

    /// 取り消されるまで落とし続ける。取り消されたら`stopped`を立てる。
    private static func endlessDownload(stopped: Flag) -> MediaDownloads.Download {
        { _, _, onProgress in
            onProgress(0.5)
            do {
                try await Gate().wait()
            } catch {
                stopped.set()
                throw error
            }
            throw URLError(.timedOut)
        }
    }

    /// 動画は、保存を選んでから落とし、落としている間は進み具合を出す。落とし終えたら写真に渡して知らせる。
    @Test func savingVideoDownloadsItFirstAndShowsProgress() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let data = Data("movie".utf8)
        let saved = SavedFiles()
        let release = Gate()
        let viewer = try await presentVideoViewer(on: harness, photoSaver: PhotoLibrarySaver { saved.files.append($0) }, download: Self.gatedDownload(data, release: release))
        defer { viewer.dismiss(animated: false) }
        #expect(topLevelTitles(of: viewer) == ["共有", "写真に保存", "リンクをコピー", "ループ再生"])
        #expect(try #require(menuAction("写真に保存", in: viewer)).attributes.isEmpty)

        viewer.saveToPhotos()

        try await waitUntil { viewer.downloadProgressText == "ダウンロード中 50%" }
        release.open()
        try await waitUntil { viewer.statusChipText != nil }
        #expect(viewer.statusChipText == "写真に保存しました")
        #expect(viewer.downloadProgressText == nil)
        let file = try #require(saved.files.first)
        #expect(file.lastPathComponent == "1.mp4")
        #expect(try Data(contentsOf: file) == data)
    }

    /// 落としている途中のチップは押すと止めるかを確かめ、確かめている間に落とし終えたら、確認を閉じて保存する。
    @Test func tappingDownloadChipConfirmsStopAndClosesWhenDone() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let saved = SavedFiles()
        let release = Gate()
        let viewer = try await presentVideoViewer(on: harness, photoSaver: PhotoLibrarySaver { saved.files.append($0) }, download: Self.gatedDownload(Data("movie".utf8), release: release))
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()
        try await waitUntil { viewer.downloadProgressText == "ダウンロード中 50%" }
        let chip = try #require(viewer.noticeStack?.chips.first)
        #expect(chip.isUserInteractionEnabled)
        #expect(chip.accessibilityHint == "ダウンロードを止めるか選べます。")
        chip.sendActions(for: .primaryActionTriggered)

        let alert = try #require(viewer.presentedViewController as? UIAlertController)
        #expect(alert.title == "ダウンロードを止めますか？")
        #expect(alert.actions.map(\.title) == ["止める", "続ける"])
        try await waitUntil { !alert.isBeingPresented }
        #expect(saved.files.isEmpty)

        release.open()
        try await waitUntil { saved.files.count == 1 }
        try await waitUntil { viewer.presentedViewController == nil }
        try await waitUntil { viewer.statusChipText == "写真に保存しました" }
        // ダウンロード中のチップがあった場所で、保存したことに入れ替える。
        #expect(viewer.noticeStack?.chips.first === chip)
        #expect(viewer.downloadProgressText == nil)
    }

    /// 止めるかの確認が出る途中に落とせなかったら、確認を閉じて、失敗を数秒で消えるチップで知らせ、「最近の失敗」に残す。
    @Test func downloadFailureWhileConfirmationAppearsClosesItAndShowsChip() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let recent = OperationStatus()
        let failure = Gate()
        let transfers = makeTransfers(downloads: makeDownloads { _, _, onProgress in
            onProgress(0.5)
            try await failure.wait()
            throw URLError(.networkConnectionLost)
        }, operationStatus: recent)
        let viewer = try await presentVideoViewer(on: harness, transfers: transfers) { _, _, _ in throw URLError(.unknown) }
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()
        try await waitUntil { viewer.downloadProgressText != nil }
        try #require(viewer.noticeStack?.chips.first).sendActions(for: .primaryActionTriggered)
        let confirmation = try #require(viewer.presentedViewController as? UIAlertController)
        #expect(confirmation.isBeingPresented)
        failure.open()

        try await waitUntil { viewer.statusChipText == "ダウンロードできませんでした" }
        try await waitUntil { viewer.presentedViewController == nil }
        #expect(recent.failures.map(\.title) == ["動画を保存できませんでした"])
        #expect(recent.activities.isEmpty)
    }

    /// 落としている途中のものは「操作の状況」の「進行中」に並び、行から止めたら通信を止め、保存しない。
    @Test func stoppingFromOperationStatusStopsDownloadWithoutSaving() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let saved = SavedFiles()
        let stopped = Flag()
        let recent = OperationStatus()
        let transfers = makeTransfers(downloads: makeDownloads(download: Self.endlessDownload(stopped: stopped)), photoSaver: PhotoLibrarySaver { saved.files.append($0) }, operationStatus: recent)
        let viewer = try await presentVideoViewer(on: harness, transfers: transfers) { _, _, _ in throw URLError(.unknown) }
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()
        try await waitUntil { recent.activities.first?.value == "50%" }
        let activity = try #require(recent.activities.first)
        #expect(activity.title == "ダウンロード中")
        #expect(activity.fraction == 0.5)
        #expect(activity.isStoppable)
        recent.stop(activity.id)

        #expect(viewer.downloadProgressText == nil)
        #expect(recent.activities.isEmpty)
        try await waitUntil { stopped.isSet }
        // 取り消しを受けて戻り切るまで待つ。戻ったあとは、保存も知らせもしない。
        try await waitUntil { transfers.transfers.runningCount == 0 }
        #expect(saved.files.isEmpty)
        #expect(viewer.statusChipText == nil)
        #expect(recent.failures.isEmpty)
    }

    /// 全体の大きさが分からず進み具合が0のままのものは、「操作の状況」の「進行中」で、0%に止まった輪ではなく分からない進み具合として並ぶ。
    @Test func downloadWithUnknownSizeIsListedWithoutFraction() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let stopped = Flag()
        let recent = OperationStatus()
        let download: MediaDownloads.Download = { _, _, _ in
            do {
                try await Gate().wait()
            } catch {
                stopped.set()
                throw error
            }
            throw URLError(.timedOut)
        }
        let transfers = makeTransfers(downloads: makeDownloads(download: download), photoSaver: PhotoLibrarySaver { _ in }, operationStatus: recent)
        let viewer = try await presentVideoViewer(on: harness, transfers: transfers) { _, _, _ in throw URLError(.unknown) }
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()
        try await waitUntil { !recent.activities.isEmpty }
        let activity = try #require(recent.activities.first)
        #expect(activity.fraction == nil)
        #expect(activity.isStoppable)
        recent.stop(activity.id)
        try await waitUntil { stopped.isSet }
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

    /// 2つの動画を落とす。`gated`の名前のファイルは、`release`が開くまで落とし終えない。
    private func makeTwoVideoViewer(
        on harness: TimelineHarness,
        gated: Set<String> = ["slow.mp4"],
        transfers: (MediaDownloads) -> MediaTransferCenter,
        release: Gate
    ) async throws -> MediaViewerController {
        let downloads = makeDownloads { url, folder, onProgress in
            onProgress(0.25)
            if gated.contains(url.lastPathComponent) {
                try await release.wait()
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try Data("movie".utf8).write(to: file)
            return file
        }
        let attachments = ["slow", "fast"].map { MediaAttachment(id: $0, type: .video, url: URL(string: "https://x.example/original/\($0).mp4"), previewUrl: nil) }
        let viewer = MediaViewerController(attachments: attachments, startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, transfers: transfers(downloads), settings: settings, sourceTile: { _ in nil })
        try await harness.viewController.presentForTesting(viewer)
        return viewer
    }

    /// 保存は並べて落とし、済んだ順に知らせる。チップには見ている添付ファイルのものを出し、ほかは件数で添える。
    @Test func savesDownloadInParallelAndChipFollowsCurrentPage() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let saved = SavedFiles()
        let release = Gate()
        let viewer = try await makeTwoVideoViewer(on: harness, transfers: { makeTransfers(downloads: $0, photoSaver: PhotoLibrarySaver { saved.files.append($0) }) }, release: release)
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()
        try await waitUntil { viewer.downloadProgressText == "ダウンロード中 25%" }
        try showPage(1, in: viewer)
        // いま見ている添付ファイルにはないため、件数だけを出す。
        #expect(viewer.downloadProgressText == "ダウンロード中 1件")
        viewer.saveToPhotos()

        try await waitUntil { saved.files.map(\.lastPathComponent) == ["fast.mp4"] }
        try await waitUntil { viewer.statusChipText == "写真に保存しました" }
        #expect(viewer.downloadProgressText == "ダウンロード中 1件")
        try showPage(0, in: viewer)
        #expect(viewer.downloadProgressText == "ダウンロード中 25%")

        release.open()
        try await waitUntil { saved.files.count == 2 }
        #expect(saved.files.map(\.lastPathComponent) == ["fast.mp4", "slow.mp4"])
        try await waitUntil { viewer.downloadProgressText == nil }
    }

    /// 見ている添付ファイルのものを落としている途中に、ほかのものも落としていれば、件数を添え、押すと「操作の状況」の一覧を開く。
    @Test func chipWithOtherDownloadsOpensOperationStatus() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let release = Gate()
        defer { release.open() }
        let opened = OpenedLists()
        let viewer = try await makeTwoVideoViewer(on: harness, gated: ["slow.mp4", "fast.mp4"], transfers: { downloads in
            let center = makeTransfers(downloads: downloads)
            center.notices.showOperationStatus = { opened.presenters.append($0) }
            return center
        }, release: release)
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()
        try showPage(1, in: viewer)
        viewer.saveToPhotos()
        try await waitUntil { viewer.noticeStack?.persistentNotice?.value == "25%" }

        let notice = try #require(viewer.noticeStack?.persistentNotice)
        #expect(notice.additionalCount == 1)
        let chip = try #require(viewer.noticeStack?.chips.first)
        #expect(chip.accessibilityHint == "操作の状況を開きます。")
        chip.sendActions(for: .primaryActionTriggered)
        #expect(opened.presenters.first === viewer)
    }

    /// ビューアを閉じても保存のためのダウンロードは続け、済んだら一覧の知らせの場所で、落としている途中のチップと入れ替えて知らせる。
    @Test func closingViewerKeepsSavingAndReportsOnTimeline() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let saved = SavedFiles()
        let stack = harness.overlay.column.stack
        let release = Gate()
        let transfers = makeTransfers(downloads: makeDownloads(download: Self.gatedDownload(Data("movie".utf8), release: release)), photoSaver: PhotoLibrarySaver { saved.files.append($0) })
        let viewer = try await presentVideoViewer(on: harness, transfers: transfers) { _, _, _ in throw URLError(.unknown) }

        viewer.saveToPhotos()
        try await waitUntil { stack.persistentNotice?.text == "ダウンロード中 50%" }
        let chip = try #require(stack.chips.first)
        viewer.dismiss(animated: false)
        // 閉じたあとも、同じチップがそのまま一覧の位置に残る。
        #expect(stack.chips.first === chip)
        #expect(stack.persistentNotice?.text == "ダウンロード中 50%")

        release.open()
        try await waitUntil { saved.files.count == 1 }
        try await waitUntil { stack.transientNotice?.text == "写真に保存しました" }
        #expect(stack.chips.first === chip)
        #expect(stack.persistentNotice == nil)
    }

    /// 共有のために落としている途中でビューアを閉じたら止め、止めたことを一覧に数秒出す。保存のためのものは続ける。
    @Test func closingViewerStopsSharingAndReportsOnTimeline() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let stopped = Flag()
        let stack = harness.overlay.column.stack
        let transfers = makeTransfers(downloads: makeDownloads(download: Self.endlessDownload(stopped: stopped)))
        let viewer = try await presentVideoViewer(on: harness, transfers: transfers) { _, _, _ in throw URLError(.unknown) }

        try #require(menuAction("共有", in: viewer)).performWithSender(nil, target: nil)
        try await waitUntil { viewer.downloadProgressText != nil }
        viewer.dismiss(animated: false)

        try await waitUntil { stopped.isSet }
        #expect(stack.transientNotice?.text == "共有を止めました")
        #expect(stack.persistentNotice == nil)
        #expect(transfers.transfers.transfers.isEmpty)
    }

    /// Macではビューアを別々のウィンドウで開くため、ほかのビューアを開いたり閉じたりしても、共有は始めたビューアに届け、そのビューアを閉じたときだけ止める。
    @Test func sharingBelongsToViewerThatStartedIt() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let release = Gate()
        let stack = harness.overlay.column.stack
        let transfers = makeTransfers(downloads: makeDownloads { url, folder, onProgress in
            onProgress(0.5)
            try await release.wait()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try Data("movie".utf8).write(to: file)
            return file
        })
        let first = try await presentVideoViewer(on: harness, transfers: transfers) { _, _, _ in throw URLError(.unknown) }
        try #require(menuAction("共有", in: first)).performWithSender(nil, target: nil)
        try await waitUntil { first.downloadProgressText != nil }

        let second = MediaViewerController(attachments: [MediaAttachment(id: "2", type: .video, url: URL(string: "https://x.example/original/2.mp4"), previewUrl: nil)], startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, transfers: transfers, settings: settings, sourceTile: { _ in nil })
        try await first.presentForTesting(second)
        // ほかのビューアでは、見ている添付ファイルのものではないため件数だけを出す。
        try await waitUntil { second.downloadProgressText == "ダウンロード中 1件" }
        // 閉じ終えるまで待つ。閉じる途中に落とし終えると、閉じる途中の画面を出している最初のビューアの上には共有のシートを出せず、UIKitが捨てる。
        try await second.dismissForTesting()
        // 閉じたビューアで始めたものではないため、止めずに続ける。止めるなら、閉じる処理の中で落としている途中のものから外れている。
        #expect(first.downloadProgressText != nil)
        #expect(stack.transientNotice == nil)

        release.open()
        try await waitUntil { first.presentedViewController is UIActivityViewController }
        first.presentedViewController?.dismiss(animated: false)
        first.dismiss(animated: false)
    }

    /// 見ていない添付ファイルの失敗は、どれの失敗か分かるよう種類で示す。
    @Test func failureOfOtherAttachmentNamesItsKind() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let fail = Gate()
        let downloads = makeDownloads { url, _, onProgress in
            onProgress(0.25)
            try await fail.wait()
            throw URLError(.networkConnectionLost)
        }
        let attachments = [
            MediaAttachment(id: "gif", type: .gifv, url: URL(string: "https://x.example/original/a.mp4"), previewUrl: nil),
            MediaAttachment(id: "video", type: .video, url: URL(string: "https://x.example/original/b.mp4"), previewUrl: nil),
        ]
        let viewer = MediaViewerController(attachments: attachments, startIndex: 0, store: .offline, dragToDismiss: drag, timing: timing, transfers: makeTransfers(downloads: downloads), settings: settings, sourceTile: { _ in nil })
        try await harness.viewController.presentForTesting(viewer)
        defer { viewer.dismiss(animated: false) }

        try #require(menuAction("共有", in: viewer)).performWithSender(nil, target: nil)
        try await waitUntil { viewer.downloadProgressText != nil }
        try showPage(1, in: viewer)
        fail.open()

        try await waitUntil { viewer.statusChipText == "GIFを共有できませんでした" }
        let chip = try #require(viewer.noticeStack?.chips.first)
        #expect(chip.accessibilityHint == "理由を見られます。")
    }

    /// 見ている添付ファイルを落とせなかったら、何ができなかったかだけを数秒で消えるチップで出し、押すと理由を出す。
    @Test func downloadFailureIsShown() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentVideoViewer(on: harness) { _, _, _ in throw URLError(.notConnectedToInternet) }
        defer { viewer.dismiss(animated: false) }

        viewer.saveToPhotos()

        try await waitUntil { viewer.statusChipText == "ダウンロードできませんでした" }
        #expect(viewer.downloadProgressText == nil)
        try #require(viewer.noticeStack?.chips.first).sendActions(for: .primaryActionTriggered)
        try await waitUntil { viewer.presentedViewController is UIAlertController }
        #expect((viewer.presentedViewController as? UIAlertController)?.title == "ダウンロードできませんでした")
        viewer.presentedViewController?.dismiss(animated: false)
    }

    /// 音声は写真に入らないため、保存は出さない。
    @Test func audioOffersOnlySharing() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let viewer = try await presentVideoViewer(on: harness, type: .audio, download: Self.gatedDownload(Data(), release: Gate()))
        defer { viewer.dismiss(animated: false) }

        #expect(topLevelTitles(of: viewer) == ["共有", "リンクをコピー", "ループ再生"])
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

        let unavailable = try #require(topLevelActions(of: processing).first)
        #expect(unavailable.attributes.contains(.disabled))
    }

    /// ビューアは一覧を残したまま覆うため、開いている間は一覧の投稿を見たと報告せず、閉じ終わったら報告する。
    @Test func timelineReportsVisibleStatusesOnlyAfterViewerCloses() async throws {
        let harness = try TimelineHarness(notices: notices)
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

    /// 開閉の間はサムネイルとビューアの画像を隠して複製を動かし、開ききったら両方とも元どおり見せる。閉じる動きの間も一覧を操作でき、戻り終えたらサムネイルを見せる。
    @Test func transitionRestoresThumbnailAndContentAfterOpeningAndClosing() async throws {
        let harness = try TimelineHarness(notices: notices)
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
            onDismiss: {},
            frameSource: harness.frames
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        // 開く動きは画面に入るときに始まるため、複製が出るのを待つ。複製を出さなければ時間切れで失敗する。
        try await waitUntil { viewer.isContentHiddenForTransition }
        #expect(tile.isConcealedForViewer, "開いている間にサムネイルを隠していません")
        harness.frames.runUntilStopped()
        #expect(!viewer.isMoving)

        #expect(!tile.isConcealedForViewer)
        #expect(!viewer.isContentHiddenForTransition)

        viewer.close()

        // 閉じると決めた時点でビューアを閉じ、サムネイルへ戻る動きの途中でも一覧を操作できるようにする。
        // ビューアを残したまま動かすと、閉じた直後に別の画像をタップしても届かない。
        // ビューアを外すのは次の描画の機会になるため、それを待つ。複製が戻り終えるより先に外れていなければ失敗する。
        try await waitUntil { harness.viewController.presentedViewController == nil }
        let window = try #require(tile.window)
        let tapPoint = tile.convert(CGPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: window)
        let hit = window.hitTest(tapPoint, with: nil)
        #expect(hit === tile || hit?.isDescendant(of: tile) == true, "閉じる動きの間、サムネイルをタップしても届きません: \(String(describing: hit))")
        #expect(tile.isConcealedForViewer, "戻り終える前にサムネイルを見せています")

        harness.frames.runUntilStopped()
        #expect(!tile.isConcealedForViewer)
        #expect(viewer.view.superview == nil)
    }

    /// 開く途中は、バーの下のサムネイルと同じ見え方から始めるため、サムネイルを含む一覧の行の中にも複製を置く。開ききったら外し、最前面の複製のマスクも外す。
    @Test func openingDrawsUnderBarsUntilOpened() async throws {
        let harness = try TimelineHarness(notices: notices)
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
            onDismiss: {},
            frameSource: harness.frames
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { viewer.isContentHiddenForTransition }
        #expect(row.subviews.contains { $0 !== tile }, "開く途中に一覧の行の中へ複製を置いていません")

        harness.frames.runUntilStopped()
        #expect(!viewer.isMoving)
        #expect(row.subviews.allSatisfy { $0 === tile }, "開ききったあとも一覧の行の中に複製が残っています")
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

    /// 手元にプレビューもぼかしもない画像でも、開く途中に元の画像が届いたら、複製をその画像に差し替える。
    @Test func morphFollowsImageThatArrivesWhileOpening() async throws {
        let harness = try TimelineHarness(notices: notices)
        defer { harness.tearDown() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let arriving = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36), format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        let data = try #require(arriving.pngData())
        let arrival = Gate()
        let store = MediaImageStore(files: .temporary()) { _, _ in
            try await arrival.wait()
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
            timing: timing,
            from: harness.viewController,
            sourceTile: { _ in tile },
            onDismiss: {},
            // 開く途中に届いたことを確かめるため、コマを送らずに開く途中のまま止めておく。
            frameSource: harness.frames
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { viewer.isContentHiddenForTransition }
        arrival.open()

        try await waitUntil { viewer.morphImage?.size == arriving.size }
        #expect(viewer.isMoving, "複製を差し替える前に開き終わりました")
        // 動かさずに閉じると、止めておいた開く動きが残るので、開く動きを止める閉じ方で閉じる。
        viewer.close()
        try await waitUntil { harness.viewController.presentedViewController == nil }
        harness.frames.runUntilStopped()
    }

    /// ビューアは一覧を残したまま上に重ねるため、開いている間も閉じたあとも、一覧の読んでいる位置を動かさない。
    @Test func timelineKeepsPositionWhileViewerOpensAndCloses() async throws {
        let harness = try TimelineHarness(notices: notices)
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
            onDismiss: { harness.viewController.reportVisibleItems() },
            frameSource: harness.frames
        )
        let viewer = try #require(harness.viewController.presentedViewController as? MediaViewerController)
        try await waitUntil { viewer.isContentHiddenForTransition }
        harness.frames.runUntilStopped()
        #expect(!viewer.isMoving)
        harness.viewController.view.window?.layoutIfNeeded()

        #expect(harness.collectionView.contentOffset == offset, "開いている間に一覧が動きました")
        #expect(harness.windowMinY(of: anchor) == anchorY)

        viewer.close()
        try await waitUntil { harness.viewController.presentedViewController == nil }
        harness.frames.runUntilStopped()
        #expect(!tile.isConcealedForViewer)
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

/// 落とす処理とテストの間で受け渡すフラグ。
private final class Flag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() {
        value.withLock { $0 = true }
    }
}

@MainActor
private final class OpenedLists {
    var presenters: [UIViewController] = []
}

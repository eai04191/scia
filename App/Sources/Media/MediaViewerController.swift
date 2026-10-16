import AVKit
import CoreImage
import os
import SciaCore
import UIKit
import VisionKit

/// 投稿の添付ファイルを全画面で見る。左右のスワイプで切り替え、画像はピンチとダブルタップで拡大する。
///
/// 開くとき、閉じるとき、下へのスワイプで閉じる操作の間は、画像の写しを一覧のサムネイルとのあいだで動かす。
///
/// UIKitの遷移（標準のズームや、遷移を自前で描く仕組み）は使わない。標準のズームは画面全体に角丸と影を付けて変形するため画面の形の枠が見え、
/// 遷移を自前で描く仕組みは動いている間の操作を受け付けないため、開く途中で下へ払っても閉じられない。
/// ビューアはアニメーションなしで出し入れし、動きはビューアの中で描く。開く途中で指が触れたら、動きをその場で止めて指に追従させる。
/// 画像を隠さないよう閉じるボタンは置かず、VoiceOverのエスケープとキーボードのEscでも閉じられるようにする。
final class MediaViewerController: UIViewController {
    private var items: [MediaViewerItem]
    /// 投稿欄で選んだメディアを開いたときの操作。投稿の添付ファイルを見るときはnil。
    private let draftEditing: Editing?
    private let store: MediaImageStore
    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private var pages: [Int: MediaPageController] = [:]
    private(set) var currentIndex: Int
    /// 添付ファイルへの操作をまとめたメニューを出す。
    private let menuButton = UIButton(configuration: .glass())
    private let counterLabel = UILabel()
    let captionView = CaptionView()
    /// 投稿欄から開いたとき、代替テキストを書く入力欄。書いている間だけ出す。
    let descriptionEditor = AltTextEditorView()
    /// 代替テキストを書いている。
    private(set) var isEditingDescription = false
    /// 投稿欄から開いたとき、アップロードや代替テキストの送信の状態を、上の中央に出す。失敗していれば押して理由を見られる。
    let draftStatusButton = DraftStatusButton()
    /// 写真に保存したことを、メニューボタンの下で知らせる。
    private let statusChip = StatusChip()
    private let photoSaver: PhotoLibrarySaver
    /// 動画、GIF、音声を、共有や保存のために落とす。
    private let downloads: MediaDownloads
    /// 落としている間、進み具合を出す。押すと取り消す。
    private let downloadButton = UIButton(configuration: .glass())
    /// 落としている途中のもの。
    private var download: Download?
    /// 画像から読み取った文字を、システムの翻訳シートで訳す。
    private let translation = SystemTranslation()
    private var isChromeHidden = false
    private let dragToDismiss: DragToDismiss
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    /// 閉じる操作を始めたときに押していた位置。`view`の座標。画像をこの点を中心に縮め、指の下に同じ場所が来るようにする。
    private var dismissPanAnchor: CGPoint = .zero
    /// 閉じ終わったときに呼ぶ。写しがサムネイルへ戻る動きは、このあとも続く。
    var onDismiss: (() -> Void)?
    /// 写しがサムネイルへ戻る動きを終えたときに呼ぶ。投稿欄は、ここで入力欄にキーボードを戻す。
    var onCloseFinish: (() -> Void)?
    /// 黒い下地。画像だけを動かし、下地はその場で濃くしたり薄くしたりする。
    private let backdrop = UIView()
    /// 開閉とドラッグで動かす画像の写し。縦横比を保って枠を埋めるように切り抜くため、枠の形をサムネイルとビューアの画像のあいだで変えるだけで、
    /// サムネイルと同じ切り抜き方へ移る。
    private let morph = UIImageView()
    /// 写しに載せる、サムネイルの印（ALT、GIF、残りの枚数）の写し。サムネイルに近いほど濃くし、ビューアの画像の大きさでは見せない。
    private var morphDecoration: UIView?
    /// 写しに敷く、サムネイルの背景の色。印と同じ濃さで出し入れし、透明な部分のある画像でサムネイルとの見え方をそろえる。
    private var morphPlaceholderColor: UIColor?
    /// 写しの画像を、ページが描いている画像に合わせ続けるか。元の画像が届いたら、動いている途中でも差し替える。
    private var morphFollowsPage = false
    private var motion = Motion.idle
    private let timing: Timing
    private let sourceTile: @MainActor (String) -> MediaTileView?
    /// 写しを動かしている間、隠している一覧のサムネイル。画像がそこへ戻っていく途中で消えて見えないよう、動かし始めから隠す。
    private var hiddenTile: MediaTileView?
    /// 開く途中と、開く途中でつかんでから写しを手前へ寄せ終えるまで、写しを一覧のバーの手前と奥に描き分ける。
    private var barLayering: MediaBarLayering?
    /// `barLayering`で、写しをバーの手前と奥のどちらに見せているか。
    private var barSwap = MediaBarSwap.front
    /// 開く途中でつかんだあと、写しをすべてバーの手前へ寄せる動き。
    private var barConvergence: SpringDriver?

    private struct Download {
        let url: URL
        let task: Task<Void, Never>
        /// 落とし終えたら行うこと。落としている途中に別の操作を選んだら、後から選んだものにする。
        var completion: @MainActor (URL) -> Void
    }

    struct Timing {
        /// サムネイルから広げて、ビューアで表示し終えるまでの時間。
        let openDuration: TimeInterval
        /// サムネイルへ縮めて戻すまでの時間。
        let closeDuration: TimeInterval
        /// 下へ払って閉じるときの弾み。0で弾まずに止まり、大きいほど行き過ぎてから戻る。
        /// 指で力を加えたときだけ弾ませ、タップで開くときや、ボタンで閉じるときは弾ませない。
        let dragCloseBounce: CGFloat
        /// 開閉するとき、画像のうちバーにかかる部分を、一覧の中に置いた写しでバーの奥に描く。
        let drawsUnderBars: Bool
        /// バーの奥にも描くとき、一覧の中の写しから最前面の写しへ受け渡し終える、開く動きの進み具合。0から1。
        let openHandoffEnd: Double
        /// バーの奥にも描くとき、バーと重なる部分を最前面の写しへ入れ替え始める、開く動きの進み具合。0から1。
        let openBarOverlapFadeStart: Double
        /// バーの奥にも描くとき、最前面の写しを一覧の中の写しへ受け渡し始める進み具合。0から1。
        let handoffStart: Double
        /// バーの奥にも描くとき、閉じ始めにバーと重なっていた部分を一覧の中の写しへ入れ替え終える進み具合。0から1。
        let barOverlapFadeEnd: Double
        /// 写真に保存したことを知らせる表示を出しておく時間。
        let savedChipDuration: TimeInterval
        /// 写真に保存したことを知らせる表示を、メニューボタンの下ではなく、画面下の説明のすぐ上に出す。
        let savedChipAtBottom: Bool
    }

    /// 投稿欄で選んだメディアを開いたときの操作。ビューアは投稿欄を知らず、メニューと代替テキストの書き終わりをここから渡す。
    struct Editing {
        /// 代替テキストの文字数の上限。
        let descriptionLimit: Int
        /// 代替テキストの残りの文字数がこれ以下になったら、残りを出す。
        let descriptionRemainingThreshold: Int
        /// 代替テキストの入力欄を伸ばす最大の行数。
        let descriptionMaxLines: Int
        /// メニューに「代替テキストを編集」に続けて出す項目。`MediaViewerItem.id`を受け取る。
        let menuElements: @MainActor (String) -> [UIMenuElement]
        /// 代替テキストを書き終えた。書き直していなくても呼ぶ。
        let commitDescription: @MainActor (String, String) -> Void
        /// 失敗の表示を押した。理由と、送り直すか外すかを、渡したビューアの上に出す。
        let showFailure: @MainActor (String, UIViewController) -> Void
    }

    /// - Parameter sourceTile: `MediaViewerItem.id`のサムネイルを返す。開閉のたびに呼ぶため、閉じるまでに一覧の行が再利用されても今の位置を返せる。
    ///   見つからなければnilを返し、画像を動かさずに薄くして開閉する。
    init(
        items: [MediaViewerItem],
        startIndex: Int,
        store: MediaImageStore,
        dragToDismiss: DragToDismiss,
        timing: Timing,
        editing: Editing? = nil,
        photoSaver: PhotoLibrarySaver = .photoLibrary,
        downloads: MediaDownloads = AppDependencies.mediaDownloads,
        sourceTile: @escaping @MainActor (String) -> MediaTileView?
    ) {
        precondition(items.indices.contains(startIndex), "開く添付ファイルの位置が範囲外です")
        self.items = items
        self.draftEditing = editing
        self.store = store
        self.photoSaver = photoSaver
        self.downloads = downloads
        self.dragToDismiss = dragToDismiss
        self.timing = timing
        self.sourceTile = sourceTile
        currentIndex = startIndex
        super.init(nibName: nil, bundle: nil)
        // 閉じる操作の間に背景を薄くして一覧を透かすため、開いている間も一覧を残す。
        modalPresentationStyle = .overFullScreen
        // 開閉はビューアの中で描き、出し入れはアニメーションなしで行う。ほかの経路でアニメーションつきで閉じられたときは、下から滑らせずに薄くする。
        modalTransitionStyle = .crossDissolve
        // 全画面でない表示では、状態バーの表示を自分で決めると宣言しないと、画像だけにしたときに隠せない。
        modalPresentationCapturesStatusBarAppearance = true
    }

    convenience init(
        attachments: [MediaAttachment],
        startIndex: Int,
        store: MediaImageStore,
        dragToDismiss: DragToDismiss,
        timing: Timing,
        photoSaver: PhotoLibrarySaver = .photoLibrary,
        downloads: MediaDownloads = AppDependencies.mediaDownloads,
        sourceTile: @escaping @MainActor (MediaAttachment.ID) -> MediaTileView?
    ) {
        self.init(
            items: attachments.map(MediaViewerItem.init),
            startIndex: startIndex,
            store: store,
            dragToDismiss: dragToDismiss,
            timing: timing,
            photoSaver: photoSaver,
            downloads: downloads,
            sourceTile: sourceTile
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentItem: MediaViewerItem { items[currentIndex] }

    /// 拡大して見ている間は、下へのスワイプを画像の移動に使い、閉じる操作にしない。
    var allowsInteractiveDismiss: Bool {
        pages[currentIndex]?.allowsInteractiveDismiss ?? true
    }

    /// 開閉の動きの終点にする、表示中の添付ファイルの枠。`view`の座標で返す。
    func contentFrame(in view: UIView) -> CGRect {
        guard let page = pages[currentIndex] else { return view.bounds }
        return page.view.convert(page.contentFrame, to: view)
    }

    /// 写しを動かしているか。開き終わり、閉じる操作もしていなければfalse。
    var isMoving: Bool {
        if case .idle = motion { return false }
        return true
    }

    override var prefersStatusBarHidden: Bool { isChromeHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { isChromeHidden }

    /// キーボードのEscを受けるため、表示されたら最初の応答者になる。
    override var canBecomeFirstResponder: Bool { true }

    /// 画面に入った最初のフレームから、サムネイルの位置に写しを置いて開き始める。
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if isBeingPresented {
            beginOpening()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isEditingDescription {
            becomeFirstResponder()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            cancelDownload()
            showHiddenTile()
            onDismiss?()
        }
    }

    /// 画像の写しが見えているか。見えている間はページの画像を隠す。
    var isContentHiddenForTransition: Bool {
        !morph.isHidden
    }

    /// 写しに描いている画像。
    var morphImage: UIImage? {
        morph.image
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "閉じる", action: #selector(close), input: UIKeyCommand.inputEscape)]
    }

    /// VoiceOverの2本指のZで閉じる。
    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    /// 写しをサムネイルへ縮めてから閉じる。代替テキストを書いていれば、書き終えてから閉じる。
    @objc func close() {
        UserAction.closeViewer(.button).record()
        beginClosing()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.backgroundColor = .black
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        overrideUserInterfaceStyle = .dark
        // 下に一覧を残しているため、VoiceOverがそちらを読まないようにする。
        view.accessibilityViewIsModal = true
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
        pageController.dataSource = self
        pageController.delegate = self
        pageController.setViewControllers([page(at: currentIndex)], direction: .forward, animated: false)
        morph.contentMode = .scaleAspectFill
        morph.clipsToBounds = true
        morph.isHidden = true
        view.addSubview(morph)
        setUpChrome()
        updateChrome()
        translation.install(in: self)
        dismissPan.delegate = self
        // ピンチの2本指を閉じる操作と取り違えないようにする。
        dismissPan.maximumNumberOfTouches = 1
        // トラックパッドの2本指スクロールでも、指で払うのと同じように閉じられるようにする（Macやトラックパッド付きのiPad）。
        dismissPan.allowedScrollTypesMask = .continuous
        view.addGestureRecognizer(dismissPan)
        AppDependencies.stateDumps.register("mediaViewer", owner: self) { $0.stateDump() }
    }

    func stateDump() -> String {
        let page = pages[currentIndex]
        return """
        motion: \(motion.label)
        index: \(currentIndex) / \(items.count) type=\(currentItem.kind) local=\(currentItem.serverAttachment == nil) status=\(currentItem.draftStatus.map { "\($0)" } ?? "nil")
        aspectRatio: \(currentItem.aspectRatio.map { "\($0)" } ?? "nil")
        editingDescription: \(isEditingDescription)
        view.bounds: \(view.bounds.size)
        morph: hidden=\(morph.isHidden) frame=\(morph.frame) image=\(morph.image.map { "\($0.size)" } ?? "nil")
        contentFrame: \(contentFrame(in: view))
        page: \(page.map { "\($0.view.bounds.size)" } ?? "nil")
        \(page?.stateDump() ?? "")
        """
    }

    private func setUpChrome() {
        menuButton.configuration?.image = UIImage(systemName: "ellipsis")
        menuButton.accessibilityLabel = "その他の操作"
        // 開くたびに、表示中の添付ファイルに合わせて項目を作り直す。
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuElements() ?? [])
        }])
        menuButton.showsMenuAsPrimaryAction = true
        captionView.onOpen = { [weak self] in
            guard let self else { return }
            if self.draftEditing != nil {
                self.beginEditingDescription()
            } else {
                self.showAltText()
            }
        }
        captionView.isEditable = draftEditing != nil
        counterLabel.font = .preferredFont(forTextStyle: .subheadline)
        counterLabel.textColor = .white
        counterLabel.isHidden = items.count == 1
        setUpDownloadButton()
        setUpDescriptionEditing()
        for view in [menuButton, counterLabel, captionView, statusChip, downloadButton, draftStatusButton, descriptionEditor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            counterLabel.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            counterLabel.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            captionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            captionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            captionView.contentBottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            statusChip.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            timing.savedChipAtBottom
                ? statusChip.bottomAnchor.constraint(equalTo: captionView.topAnchor, constant: -12)
                : statusChip.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 12),
            // 落とし終えると同じ場所に保存したことを知らせるため、知らせる表示と同じ場所に出す。
            downloadButton.centerXAnchor.constraint(equalTo: statusChip.centerXAnchor),
            downloadButton.centerYAnchor.constraint(equalTo: statusChip.centerYAnchor),
            draftStatusButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            draftStatusButton.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 8),
            draftStatusButton.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -32),
            descriptionEditor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            descriptionEditor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            descriptionEditor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func setUpDescriptionEditing() {
        descriptionEditor.isHidden = true
        descriptionEditor.limit = draftEditing?.descriptionLimit ?? 0
        if let draftEditing {
            descriptionEditor.remainingThreshold = draftEditing.descriptionRemainingThreshold
            descriptionEditor.maxLines = draftEditing.descriptionMaxLines
        }
        descriptionEditor.onEnd = { [weak self] text in self?.descriptionEditingDidEnd(text) }
        descriptionEditor.onDone = { [weak self] in self?.endEditingDescription() }
        draftStatusButton.addAction(UIAction { [weak self] _ in
            guard let self, let editing = self.draftEditing else { return }
            editing.showFailure(self.currentItem.id, self)
        }, for: .primaryActionTriggered)
    }

    private func setUpDownloadButton() {
        downloadButton.isHidden = true
        downloadButton.configuration?.image = UIImage(systemName: "xmark")
        downloadButton.configuration?.imagePlacement = .trailing
        downloadButton.configuration?.imagePadding = 8
        downloadButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        // 進み具合の数字が変わるたびに幅が揺れないよう、数字の幅をそろえる。
        downloadButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular))
            return attributes
        }
        downloadButton.accessibilityLabel = "ダウンロードを取り消す"
        downloadButton.addAction(UIAction { [weak self] _ in self?.cancelDownload() }, for: .primaryActionTriggered)
    }

    private var chromeViews: [UIView] { [menuButton, counterLabel, captionView, draftStatusButton] }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layOutPages()
        updateBottomCoveredHeight()
    }

    /// 代替テキストを書いている間は、画像をキーボードと入力欄に隠れない範囲に縮めて収め、書きながら見られるようにする。
    /// 枠の大きさを変えると拡大表示が倍率を決め直して画像が飛ぶため、枠は画面いっぱいのまま、縮めて動かす変形をかける。
    /// 入力欄はキーボードに付いて動き、この並べ直しはキーボードの動きの中で呼ばれるため、変形もキーボードと一緒に動く。
    private func layOutPages() {
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        if pageController.view.bounds != bounds {
            pageController.view.bounds = bounds
        }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if pageController.view.center != center {
            pageController.view.center = center
        }
        let transform = editingPageTransform()
        if pageController.view.transform != transform {
            pageController.view.transform = transform
        }
    }

    /// キーボードが出ている間だけ縮める。書き始める前の並べ直しや、書き終えた後は、キーボードの動きの外で呼ばれるため縮めない。
    private func editingPageTransform() -> CGAffineTransform {
        guard isEditingDescription, descriptionEditor.isEditing, let page = pages[currentIndex] else { return .identity }
        // 枠は画面と同じ大きさで原点も同じなので、枠の座標がそのまま画面の座標になる。
        let content = page.view.convert(page.contentFrame, to: pageController.view)
        // 上は書いていないときと同じく、ボタンや状態の表示と重ねてよい。ボタンは右上にしかなく、タップで隠せるため。
        let available = CGRect(x: 0, y: 0, width: view.bounds.width, height: descriptionEditor.frame.minY)
        return Self.fittingTransform(content: content, into: available, in: view.bounds)
    }

    /// `bounds`の中央を軸にした変形で、`content`を`available`に収まるまで縮め、`available`の中央に置く。収まっていれば縮めない。
    /// 拡大して画面からはみ出していれば、見えている部分だけを収める。はみ出した画像全体を収めると、見えている範囲ごと小さくなりすぎるため。
    static func fittingTransform(content: CGRect, into available: CGRect, in bounds: CGRect) -> CGAffineTransform {
        let content = content.intersection(bounds)
        guard !content.isNull, content.width > 0, content.height > 0, available.width > 0, available.height > 0 else { return .identity }
        let scale = min(1, available.width / content.width, available.height / content.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let x = available.midX - center.x - scale * (content.midX - center.x)
        let y = available.midY - center.y - scale * (content.midY - center.y)
        return CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
    }

    /// 画面の下で、説明に隠れている高さ。説明を出していなければ0。
    private var captionCoveredHeight: CGFloat {
        captionView.isHidden ? 0 : view.bounds.maxY - captionView.frame.minY
    }

    /// 説明に隠れている高さをページへ伝え、ページの中のボタンをそれより上に出させる。
    private func updateBottomCoveredHeight() {
        for page in pages.values {
            page.bottomCoveredHeight = captionCoveredHeight
        }
    }

    private func updateChrome() {
        counterLabel.text = "\(currentIndex + 1) / \(items.count)"
        let description = currentItem.description ?? ""
        captionView.text = description
        // 投稿欄から開いたときは、空でも代替テキストを書き始められるよう出しておく。
        captionView.isHidden = isChromeHidden || isEditingDescription || (description.isEmpty && draftEditing == nil)
        updateDraftStatus()
        view.setNeedsLayout()
    }

    /// 画像を1回タップしたら、ボタンと説明を隠して画像だけにする。もう1回で戻す。
    fileprivate func toggleChrome() {
        isChromeHidden.toggle()
        UIView.animate(withDuration: 0.2) {
            // 説明は表示を`isHidden`で切り替えるが、閉じる操作を取り消すと透明のまま残るため、不透明度も戻す。
            for view in self.chromeViews {
                view.alpha = self.isChromeHidden ? 0 : 1
            }
            self.updateChrome()
            self.setNeedsStatusBarAppearanceUpdate()
        }
        for page in pages.values {
            page.setChromeHidden(isChromeHidden, animated: true)
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func page(at index: Int) -> MediaPageController {
        if let page = pages[index] { return page }
        let item = items[index]
        let page: MediaPageController = switch Self.pageKind(of: item) {
        case .image: ImagePageController(item: item, store: store, preview: sourceTile(item.id)?.loadedThumbnail ?? item.localThumbnail)
        case .player: PlayerPageController(item: item)
        case .unsupported: UnsupportedPageController(item: item)
        }
        page.index = index
        page.onSingleTap = { [weak self] in self?.toggleChrome() }
        page.menuElements = { [weak self] in self?.menuElements() ?? [] }
        page.setChromeHidden(isChromeHidden, animated: false)
        page.bottomCoveredHeight = captionCoveredHeight
        page.onImageChange = { [weak self, weak page] in
            guard let self, let page, self.morphFollowsPage, page.index == self.currentIndex, let image = page.transitionImage else { return }
            self.morph.image = image
        }
        pages[index] = page
        return page
    }

    /// 中身を描くページの種類。
    private enum PageKind {
        case image, player, unsupported
    }

    private static func pageKind(of item: MediaViewerItem) -> PageKind {
        switch item.kind {
        case .image: .image
        // 投稿欄で選んだGIFは動画ではなく画像のファイルで、AVPlayerでは再生できないため、最初のコマを画像として見せる。
        case .gifv where item.serverAttachment == nil: .image
        case .video, .gifv, .audio: .player
        case .unknown: .unsupported
        }
    }

    private static func pageKind(of page: MediaPageController) -> PageKind {
        switch page {
        case is ImagePageController: .image
        case is PlayerPageController: .player
        default: .unsupported
        }
    }

    /// 共有や保存で渡すファイルのURL。画像は元のファイルを読み込み終えるまでnilにし、届く前に共有できないようにする。
    /// 動画、GIF、音声は選んでから落とすため、URLがあれば返す。アプリで開けない種類のファイルと、URLのない添付ファイルではnil。
    private var currentFileURL: URL? {
        guard let attachment = currentItem.serverAttachment else { return nil }
        switch attachment.type {
        case .image: return (pages[currentIndex] as? ImagePageController)?.originalURL
        case .video, .gifv, .audio: return attachment.url ?? attachment.remoteUrl
        case .unknown: return nil
        }
    }

    /// アプリで開けない種類のファイルで、ファイルの代わりに共有するURL。
    private var currentUnsupportedURL: URL? {
        guard let attachment = currentItem.serverAttachment, case .unknown = attachment.type else { return nil }
        return attachment.url ?? attachment.remoteUrl
    }

    /// 共有シートに渡すもの。見出しのプレビューに、`index`の添付ファイルの描いている画像（動画は再生しているコマ）か一覧のサムネイルを添える。
    /// 落としている間にページを替えられるため、表示中のページではなく、共有を選んだときのページから取る。
    private func shareSheetItem(for file: URL, at index: Int) -> Any {
        guard let preview = pages[index]?.transitionImage ?? sourceTile(items[index].id)?.loadedThumbnail else { return file }
        return MediaShareSheetItem(file: file, preview: preview)
    }

    /// 表示中のページが画像なら、そのページ。
    var currentImagePage: ImagePageController? {
        pages[currentIndex] as? ImagePageController
    }

    /// 左右の切り替えで今見せているページ。
    var displayedPage: MediaPageController? {
        pageController.viewControllers?.first as? MediaPageController
    }

    /// メニューの項目。画像の共有や保存は、元のファイルが届くまで選べなくする。動画などは選んでから落とす。
    /// 保存は写真に入る画像、動画、GIFだけ、翻訳は画像から文字を読み取れたときだけ、代替テキストは付いているときだけ出す。
    func menuElements() -> [UIMenuElement] {
        if let editing = draftEditing {
            return editingMenuElements(editing)
        }
        var elements: [UIMenuElement] = [
            UIAction(
                title: "共有",
                image: UIImage(systemName: "square.and.arrow.up"),
                attributes: currentFileURL == nil && currentUnsupportedURL == nil ? .disabled : []
            ) { [weak self] _ in
                self?.share()
            },
        ]
        if [.image, .video, .gifv].contains(currentItem.kind) {
            elements.append(UIAction(
                title: "写真に保存",
                image: UIImage(systemName: "square.and.arrow.down"),
                attributes: currentFileURL == nil ? .disabled : []
            ) { [weak self] _ in
                self?.saveToPhotos()
            })
        }
        if let text = (pages[currentIndex] as? ImagePageController)?.recognizedText, !text.isEmpty {
            elements.append(UIAction(title: "画像の文字を翻訳", image: UIImage(systemName: "translate")) { [weak self] _ in
                self?.translation.present(text)
            })
        }
        if let description = currentItem.description, !description.isEmpty {
            elements.append(UIAction(title: "代替テキスト", image: UIImage(systemName: "text.below.photo")) { [weak self] _ in
                self?.showAltText()
            })
        }
        return elements
    }

    /// 代替テキストの全文をシートで出す。
    func showAltText() {
        guard let description = currentItem.description, !description.isEmpty else { return }
        present(AltTextViewController.sheet(text: description), animated: true)
    }

    // MARK: 投稿欄から開いたとき

    /// 開いている間に、投稿欄の添付の状態や代替テキストが変わった。並びは変わらない前提で、同じIDのものだけ差し替える。
    /// 外された添付は、外した側がビューアを閉じるため、ここでは並びから除かない。
    func update(items newItems: [MediaViewerItem]) {
        let updated = Dictionary(newItems.map { ($0.id, $0) }) { first, _ in first }
        for index in items.indices {
            guard let item = updated[items[index].id] else { continue }
            items[index] = item
            guard let page = pages[index] else { continue }
            if Self.pageKind(of: page) == Self.pageKind(of: item) {
                page.update(item)
            } else {
                // 投稿欄で選んだメディアは、読み込むまで種類が分からず画像として開くため、動画と分かったらページを作り直す。
                pages[index] = nil
                if index == currentIndex {
                    pageController.setViewControllers([self.page(at: index)], direction: .forward, animated: false)
                }
            }
        }
        updateChrome()
    }

    /// メニューの「代替テキストを編集」と、投稿欄から渡された項目。
    private func editingMenuElements(_ editing: Editing) -> [UIMenuElement] {
        let edit = UIAction(title: "代替テキストを編集", image: UIImage(systemName: "text.below.photo")) { [weak self] _ in
            self?.beginEditingDescription()
        }
        return [edit] + editing.menuElements(currentItem.id)
    }

    /// 代替テキストの入力欄をキーボードのすぐ上に出して書き始める。
    func beginEditingDescription() {
        guard let editing = draftEditing, !isEditingDescription else { return }
        // 開いている途中や戻している途中なら、動きを終えてから書き始める。
        completeMotionImmediately()
        guard case .idle = motion else { return }
        SciaLog.logger(category: "media").info("begin editing description")
        isEditingDescription = true
        descriptionEditor.limit = editing.descriptionLimit
        descriptionEditor.text = currentItem.description ?? ""
        descriptionEditor.isHidden = false
        updateChrome()
        view.layoutIfNeeded()
        descriptionEditor.beginEditing()
    }

    /// キーボードを下げて書き終える。書き終えた値は`descriptionEditingDidEnd`で受け取る。
    func endEditingDescription() {
        guard isEditingDescription else { return }
        if descriptionEditor.isEditing {
            descriptionEditor.endEditing()
        } else {
            // キーボードを出せていなければ書き終えた知らせが来ないため、ここで書き終える。
            descriptionEditingDidEnd(descriptionEditor.text)
        }
    }

    /// 書き終えた値を投稿欄に渡し、投稿欄から届く前にビューアで先に見せる。
    private func descriptionEditingDidEnd(_ text: String) {
        guard isEditingDescription else { return }
        SciaLog.logger(category: "media").info("end editing description length=\(text.count, privacy: .public)")
        isEditingDescription = false
        descriptionEditor.isHidden = true
        let id = currentItem.id
        items[currentIndex].description = text.isEmpty ? nil : text
        draftEditing?.commitDescription(id, text)
        updateChrome()
        // キーボードのEscで閉じられるよう、最初の応答者に戻る。
        if case .idle = motion {
            becomeFirstResponder()
        }
    }

    /// 投稿欄から開いたとき、上の中央にアップロードや代替テキストの送信の状態を出す。
    private func updateDraftStatus() {
        draftStatusButton.apply(currentItem.draftStatus)
    }

    /// 表示中の添付ファイルを写真に保存し、済んだらメニューボタンの下で知らせる。キャッシュになければ落としてから保存する。
    /// 失敗したときは理由をアラートで出す。
    func saveToPhotos() {
        guard let url = currentFileURL else { return }
        withDownloadedFile(of: url) { [weak self] file in self?.save(file) }
    }

    private func save(_ file: URL) {
        Task { [weak self, photoSaver] in
            do {
                try await photoSaver.save(file)
                self?.didSaveToPhotos()
            } catch {
                SciaLog.logger(category: "media").error("save to photos failed: \(error.localizedDescription, privacy: .public)")
                self?.presentSaveFailure(error)
            }
        }
    }

    /// 写真に保存したことを知らせている文言。知らせていなければnil。
    var statusChipText: String? {
        statusChip.shownText
    }

    private func didSaveToPhotos() {
        UINotificationFeedbackGenerator(view: view).notificationOccurred(.success)
        statusChip.show("写真に保存しました", systemImage: "checkmark.circle.fill", duration: timing.savedChipDuration)
    }

    private func presentSaveFailure(_ error: any Error) {
        UINotificationFeedbackGenerator(view: view).notificationOccurred(.error)
        let alert: UIAlertController
        if error is PhotoLibrarySaver.NotAuthorized {
            alert = UIAlertController(title: "写真に保存できません", message: "写真への追加が許可されていません。設定でSciaに写真の追加を許可してください。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "設定を開く", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        } else {
            alert = UIAlertController(title: "写真に保存できませんでした", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        }
        presentOnTop(alert)
    }

    /// 保存やダウンロードを待つ間に、代替テキストや共有のシートを開いていることがある。ビューアから出すと拒否されるため、いちばん手前の画面から出す。
    private func presentOnTop(_ viewController: UIViewController) {
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(viewController, animated: true)
    }

    private func share() {
        if let url = currentFileURL {
            let index = currentIndex
            withDownloadedFile(of: url) { [weak self] file in
                guard let self else { return }
                self.presentShareSheet(self.shareSheetItem(for: file, at: index))
            }
        } else if let url = currentUnsupportedURL {
            presentShareSheet(url)
        }
    }

    private func presentShareSheet(_ item: Any) {
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        // 添付ファイルの画像を連絡先の写真にすることはまずないため、出さない。
        activity.excludedActivityTypes = [.assignToContact]
        activity.popoverPresentationController?.sourceItem = menuButton
        presentOnTop(activity)
    }

    /// 落としている途中の進み具合の文言。落としていなければnil。
    var downloadProgressText: String? {
        downloadButton.isHidden ? nil : downloadButton.configuration?.title
    }

    /// `url`のファイルの写しを用意してから`completion`に渡す。キャッシュになければ落とし、落としている間は進み具合を出して、押せば取り消せるようにする。
    /// 同じURLを用意している途中なら、用意し直さずに行うことだけを替える。別のURLなら、前のものを取り消す。
    private func withDownloadedFile(of url: URL, then completion: @escaping @MainActor (URL) -> Void) {
        if download?.url == url {
            download?.completion = completion
            return
        }
        cancelDownload()
        let task = Task { [weak self, downloads] in
            do {
                let file = try await downloads.fileForSharing(for: url) { fraction in
                    guard let self, self.download?.url == url else { return }
                    self.updateDownloadButton(fraction: fraction)
                    self.downloadButton.isHidden = false
                }
                guard let self, !Task.isCancelled else { return }
                let completion = self.download?.completion
                self.endDownload()
                completion?(file)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.endDownload()
                self.presentDownloadFailure(error)
            }
        }
        download = Download(url: url, task: task, completion: completion)
    }

    /// 落としている途中のものを取り消す。
    func cancelDownload() {
        download?.task.cancel()
        endDownload()
    }

    private func endDownload() {
        download = nil
        downloadButton.isHidden = true
    }

    /// 全体の大きさが分かるまでは`fraction`が0のため、割合を出さない。
    private func updateDownloadButton(fraction: Double) {
        let percent = Int((fraction * 100).rounded(.down))
        downloadButton.configuration?.title = percent > 0 ? "ダウンロード中 \(percent)%" : "ダウンロード中"
        downloadButton.accessibilityValue = percent > 0 ? "\(percent)%" : nil
    }

    private func presentDownloadFailure(_ error: any Error) {
        UINotificationFeedbackGenerator(view: view).notificationOccurred(.error)
        let alert = UIAlertController(title: "ダウンロードできませんでした", message: ErrorPresentation(error).text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presentOnTop(alert)
    }
}

extension MediaViewerController: UIGestureRecognizerDelegate {
    /// 拡大していない画像を、下へ向けて動かし始めたときだけ閉じる操作にする。横は左右の切り替えに、上は何もしないまま残す。
    /// 開いている途中や、閉じずに戻している途中でも受け付け、その場からつかみ直せるようにする。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        if case .closing = motion { return false }
        let velocity = dismissPan.velocity(in: view)
        let isDownward = velocity.y > 0 && velocity.y > abs(velocity.x)
        if isEditingDescription {
            // 書いている間に払ったら、閉じずにキーボードを下げて書き終える。もう一度払えば閉じる。
            if isDownward {
                endEditingDescription()
            }
            return false
        }
        return allowsInteractiveDismiss && isDownward
    }

    /// 代替テキストの入力欄の中のドラッグ（スクロールや、長押しからのカーソル移動）は、閉じる操作にせず入力欄に任せる。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dismissPan, let touched = touch.view else { return true }
        return !touched.isDescendant(of: descriptionEditor)
    }

    @objc fileprivate func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        let height = view.bounds.height
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .began:
            beginDragging(at: recognizer.location(in: view))
        case .changed:
            guard case .dragging(let start, let visibility) = motion else { return }
            let scale = dragToDismiss.scale(translation: translation.y, height: height)
            morph.frame = Self.scaled(start, by: scale, around: dismissPanAnchor).offsetBy(dx: translation.x, dy: translation.y)
            applyBarLayering()
            let backgroundAlpha = visibility * dragToDismiss.backgroundAlpha(translation: translation.y, height: height)
            backdrop.alpha = backgroundAlpha
            // ボタンと説明は、背景が半分透けたところで消えきるようにする。
            for chrome in chromeViews {
                chrome.alpha = isChromeHidden ? 0 : max(backgroundAlpha * 2 - 1, 0)
            }
        case .ended:
            pageController.view.isUserInteractionEnabled = true
            let velocity = recognizer.velocity(in: view).y
            if dragToDismiss.shouldDismiss(translation: translation.y, velocity: velocity, height: height) {
                SciaLog.logger(category: "media").info("dismiss by drag translation=\(translation.y, privacy: .public) velocity=\(velocity, privacy: .public)")
                UserAction.closeViewer(.drag).record()
                beginClosing(releaseVelocity: recognizer.velocity(in: view))
            } else {
                settle()
            }
        case .cancelled, .failed:
            pageController.view.isUserInteractionEnabled = true
            settle()
        default:
            break
        }
    }

    /// `rect`を`anchor`を中心に`scale`倍する。押した位置の下に、画像の同じ場所が来るようにするため。
    private static func scaled(_ rect: CGRect, by scale: CGFloat, around anchor: CGPoint) -> CGRect {
        CGRect(
            x: anchor.x + (rect.minX - anchor.x) * scale,
            y: anchor.y + (rect.minY - anchor.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

// MARK: - 写しの動き

extension MediaViewerController {
    /// 写しの動き。開く、指に追従する、元へ戻す、閉じるの順に移る。開く途中と戻す途中は、指が触れたら止めて追従に移る。
    fileprivate enum Motion {
        /// 写しを隠し、ページの画像を見せている。
        case idle
        case opening(SpringDriver)
        /// 指に追従している。`start`はつかんだときの写しの枠、`visibility`はそのときの開いている度合い。
        case dragging(start: CGRect, visibility: CGFloat)
        /// 閉じずに離したあと、ビューアの画像の枠へ戻している。
        case settling(UIViewPropertyAnimator)
        case closing

        var label: String {
            switch self {
            case .idle: "idle"
            case .opening: "opening"
            case .dragging: "dragging"
            case .settling: "settling"
            case .closing: "closing"
            }
        }
    }

    /// 開いている度合い。0で下地とボタンが透明、1で不透明。
    private func setVisibility(_ visibility: CGFloat) {
        backdrop.alpha = visibility
        downloadButton.alpha = visibility
        for chrome in chromeViews {
            chrome.alpha = isChromeHidden ? 0 : visibility
        }
    }

    private var currentTile: MediaTileView? {
        sourceTile(currentItem.id)
    }

    private func tileFrame(of tile: MediaTileView) -> CGRect {
        tile.convert(tile.bounds, to: view)
    }

    /// 写しを見せ、ページの画像と一覧のサムネイルを隠す。写しの画像は、ページが描いている画像か、まだ描いていなければサムネイルの画像。
    /// どちらもなければ（アプリで表示できないファイルなど）、ページを描き写した画像を使う。
    /// 画像を描くページなら、最初に画像がなくても、届いた時点で写しを差し替える。
    /// - Parameter decorationAlpha: サムネイルの印の濃さ。サムネイルの位置から始めるなら1、ビューアの画像の位置から始めるなら0。
    private func showMorph(frame: CGRect, cornerRadius: CGFloat, tile: MediaTileView?, decorationAlpha: CGFloat) {
        let page = pages[currentIndex]
        morph.image = page?.transitionImage ?? tile?.thumbnailImage ?? page.map(Self.snapshot)
        attachDecoration(from: tile, alpha: decorationAlpha)
        morphFollowsPage = page?.drawsImage ?? false
        morph.frame = frame
        morph.layer.cornerRadius = cornerRadius
        morph.layer.cornerCurve = tile?.layer.cornerCurve ?? .continuous
        morph.alpha = 1
        morph.isHidden = false
        setPageHidden(true)
        hide(tile)
    }

    /// サムネイルの印の写しを、写しに載せ直す。サムネイルを隠す前に描き写す必要がある。
    /// 写しの大きさが変わっても角からの位置を保つよう、写しいっぱいに広げて自動で位置を合わせる。
    private func attachDecoration(from tile: MediaTileView?, alpha: CGFloat) {
        morphDecoration?.removeFromSuperview()
        morphPlaceholderColor = tile?.placeholderColor
        morphDecoration = tile.map { tile in
            let decoration = tile.makeDecorationCopy()
            decoration.frame = morph.bounds
            decoration.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            morph.addSubview(decoration)
            return decoration
        }
        setDecorationAlpha(alpha)
    }

    /// サムネイルの印と背景の濃さ。サムネイルの大きさで1、ビューアの画像の大きさで0。
    private func setDecorationAlpha(_ alpha: CGFloat) {
        morphDecoration?.alpha = alpha
        morph.backgroundColor = Self.placeholderColor(morphPlaceholderColor, alpha: alpha)
    }

    static func placeholderColor(_ color: UIColor?, alpha: CGFloat) -> UIColor? {
        color.map { $0.withAlphaComponent($0.cgColor.alpha * alpha) }
    }

    private func hideMorph() {
        morph.isHidden = true
        morphFollowsPage = false
        setPageHidden(false)
    }

    /// ページを見えなくする。透明にすると触れても反応しなくなるため、空のマスクで隠し、写しを動かしている間も左右の切り替えやタップを受け付ける。
    private func setPageHidden(_ hidden: Bool) {
        pageController.view.layer.mask = hidden ? CALayer() : nil
    }

    /// 開いている途中や戻している途中なら、動きを終えて開ききった状態にする。左右の切り替えなど、ほかの操作を優先するため。
    fileprivate func completeMotionImmediately() {
        switch motion {
        case .opening(let driver):
            driver.stop()
        case .settling(let animator):
            animator.stopAnimation(true)
        case .idle, .dragging, .closing:
            return
        }
        setVisibility(1)
        finishOpen()
    }

    /// ページが描いている枠を画像にする。
    private static func snapshot(of page: MediaPageController) -> UIImage {
        let frame = page.contentFrame
        return UIGraphicsImageRenderer(bounds: frame).image { _ in
            page.view.drawHierarchy(in: page.view.bounds, afterScreenUpdates: false)
        }
    }

    /// 隠すサムネイルを入れ替える。左右の切り替えで、隠していたものと別の添付ファイルに移っていることがあるため。
    private func hide(_ tile: MediaTileView?) {
        guard tile !== hiddenTile else { return }
        showHiddenTile()
        tile?.isConcealedForViewer = true
        hiddenTile = tile
    }

    private func showHiddenTile() {
        hiddenTile?.isConcealedForViewer = false
        hiddenTile = nil
    }

    /// 視差効果を減らす設定では、画像を動かさずに薄くして開閉する。
    private var movesImage: Bool {
        !UIAccessibility.isReduceMotionEnabled
    }

    private func makeAnimator(duration: TimeInterval, bounce: CGFloat) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: duration, timingParameters: UISpringTimingParameters(duration: duration, bounce: bounce))
    }

    /// 写しをサムネイルの位置からビューアの画像の位置へ広げる。バーの奥と手前の描き分けを写しの位置と同じフレームで描くため、
    /// UIKitのアニメーションではなく、ばねを毎フレーム進めて動かす。
    private func beginOpening() {
        view.layoutIfNeeded()
        let update: @MainActor (CGFloat) -> Void
        if movesImage, let tile = currentTile {
            let start = tileFrame(of: tile)
            let startRadius = tile.layer.cornerRadius
            showMorph(frame: start, cornerRadius: startRadius, tile: tile, decorationAlpha: 1)
            barLayering = makeBarLayering(tile: tile)
            let target = contentFrame(in: view)
            update = { [weak self] progress in
                self?.updateOpening(progress: progress, from: start, radius: startRadius, to: target)
            }
        } else {
            update = { [weak self] progress in
                let clamped = min(max(progress, 0), 1)
                self?.pageController.view.alpha = clamped
                self?.setVisibility(clamped)
            }
        }
        let driver = SpringDriver(spring: SpringCurve(duration: timing.openDuration, bounce: 0), update: update) { [weak self] in
            self?.finishOpen()
        }
        motion = .opening(driver)
        driver.start()
    }

    private func updateOpening(progress: CGFloat, from start: CGRect, radius startRadius: CGFloat, to target: CGRect) {
        let clamped = min(max(progress, 0), 1)
        morph.frame = CGRect(
            x: start.minX + (target.minX - start.minX) * progress,
            y: start.minY + (target.minY - start.minY) * progress,
            width: start.width + (target.width - start.width) * progress,
            height: start.height + (target.height - start.height) * progress
        )
        morph.layer.cornerRadius = startRadius * (1 - clamped)
        setDecorationAlpha(1 - clamped)
        setVisibility(clamped)
        if barLayering != nil {
            barSwap = MediaBarSwap.opening(progress: clamped, handoffEnd: timing.openHandoffEnd, overlapFadeStart: timing.openBarOverlapFadeStart)
            applyBarLayering()
        }
    }

    /// 写しをバーの手前と奥に描き分ける準備をする。バーの奥に描かない設定や、サムネイルを含む一覧の行が見つからなければnil。
    private func makeBarLayering(tile: MediaTileView) -> MediaBarLayering? {
        guard timing.drawsUnderBars, let window = view.window else { return nil }
        let layering = MediaBarLayering(
            morph: morph,
            decoration: morphDecoration,
            backdrop: backdrop,
            underlay: makeUnderlay(decoratedLike: tile),
            window: window
        )
        layering.track(tile)
        guard layering.drawsUnderBars else {
            layering.tearDown()
            return nil
        }
        return layering
    }

    /// 写しの今の位置で、バーの手前と奥の描き分けを描き直す。描き分けていなければ何もしない。
    private func applyBarLayering() {
        guard let layering = barLayering, let window = view.window else { return }
        morph.alpha = 1 - barSwap.handoff
        layering.apply(clipRect: layering.visibleRect, overlapRect: window.bounds, swap: barSwap, visibility: 1)
    }

    /// 開く途中でつかんだら、指で動かす写しをすべてバーの手前へ短い時間で寄せる。閉じる操作の間は、写しをバーの手前に描くため。
    private func convergeBarLayeringToFront() {
        guard barLayering != nil else { return }
        let from = barSwap
        let driver = SpringDriver(spring: SpringCurve(duration: Self.barConvergenceDuration, bounce: 0)) { [weak self] progress in
            self?.barSwap = from.converging(toFront: progress)
            self?.applyBarLayering()
        } completion: { [weak self] in
            self?.endBarLayering()
        }
        barConvergence = driver
        driver.start()
    }

    /// 描き分けをやめ、写しをすべてバーの手前に見せる。
    private func endBarLayering() {
        barConvergence?.stop()
        barConvergence = nil
        guard let layering = barLayering else { return }
        layering.tearDown()
        barLayering = nil
        barSwap = .front
        morph.alpha = 1
    }

    /// 開く途中でつかんだあと、写しをバーの手前へ寄せ終えるまでの時間。
    private static let barConvergenceDuration: TimeInterval = 0.15

    /// 開ききったら、写しを隠してページの画像に戻す。隠していたサムネイルも、黒い下地で覆われているので戻す。
    private func finishOpen() {
        endBarLayering()
        hideMorph()
        showHiddenTile()
        pageController.view.alpha = 1
        motion = .idle
    }

    /// 開いている途中や戻している途中なら、その場で止めてつかむ。開ききっていれば、ビューアの画像の位置に写しを出してつかむ。
    private func beginDragging(at location: CGPoint) {
        switch motion {
        case .opening(let driver):
            // 止めた時点の見た目のまま残す。
            driver.stop()
            grabMovingMorph()
            convergeBarLayeringToFront()
        case .settling(let animator):
            animator.stopAnimation(true)
            grabMovingMorph()
        case .idle:
            showMorph(frame: contentFrame(in: view), cornerRadius: 0, tile: currentTile, decorationAlpha: 0)
        case .dragging, .closing:
            return
        }
        dismissPanAnchor = location
        pageController.view.isUserInteractionEnabled = false
        motion = .dragging(start: morph.frame, visibility: backdrop.alpha)
    }

    /// 開いている途中や戻している途中に止めた写しをつかむ。
    private func grabMovingMorph() {
        if morph.isHidden {
            // 薄くして開いていた途中なら、ここから写しを出す。
            showMorph(frame: contentFrame(in: view), cornerRadius: 0, tile: currentTile, decorationAlpha: 0)
        } else {
            hide(currentTile)
        }
    }

    /// 閉じずに離したら、写しをビューアの画像の枠へ戻し、開ききった状態にする。
    private func settle() {
        guard case .dragging = motion else { return }
        // つかんでから写しを手前へ寄せ終える前に離していたら、残りを寄せずに手前に見せる。寄せる時間（0.15秒）より短い操作に限られるため受け入れる。
        // 戻す動きはUIKitのアニメーションで描くため、描き分けのマスクを写しの位置に合わせ続けられない。
        endBarLayering()
        let animator = makeAnimator(duration: dragToDismiss.restoreDuration, bounce: 0)
        let target = contentFrame(in: view)
        animator.addAnimations {
            self.morph.frame = target
            self.morph.layer.cornerRadius = 0
            self.setDecorationAlpha(0)
            self.setVisibility(1)
        }
        animator.addCompletion { [weak self] position in
            guard position == .end else { return }
            // 下地で覆い直してから、サムネイルを戻す。途中で戻すと、薄い下地越しにサムネイルが現れる。
            self?.finishOpen()
        }
        motion = .settling(animator)
        animator.startAnimation()
    }

    /// 閉じると決めたら、すぐにビューアを閉じ、写しと下地とボタンの写しを、操作を素通しする最前面の層へ移してサムネイルへ縮める。
    /// ビューアを残したまま動かすと、残った画面が触れたものを吸い、閉じた直後に別の画像を叩いても開けない。
    /// サムネイルが見つからなければ、その場で薄くする。
    /// - Parameter releaseVelocity: 下へ払って閉じたときの、指を離したときの速さ。払って閉じるときだけ、この速さを引き継いで弾ませる。
    private func beginClosing(releaseVelocity: CGPoint? = nil) {
        if isEditingDescription {
            endEditingDescription()
        }
        switch motion {
        case .closing:
            return
        case .opening(let driver):
            driver.stop()
        case .settling(let animator):
            animator.stopAnimation(true)
        case .idle, .dragging:
            break
        }
        // 開く途中から閉じるときは、バーと重なる部分をそのときの濃さから奥へ入れ替える。
        // 一覧のバーに隠れない範囲での受け渡しは、閉じる動きでは手前から始めるため、開き始めのごく短い間に閉じると、新着ボタンなどに重なる部分が手前に切り替わる。
        // Escやメニューから閉じたときに限られ、下へ払って閉じるときはつかんだ時点で手前へ寄せ始めているため受け入れる。
        let startOverlapOpacity = barLayering == nil ? 1 : barSwap.overlapOpacity
        endBarLayering()
        motion = .closing
        let tile = currentTile
        if morph.isHidden {
            showMorph(frame: contentFrame(in: view), cornerRadius: 0, tile: tile, decorationAlpha: 0)
        } else {
            if tile !== hiddenTile {
                // 左右の切り替えで戻り先が変わっていたら、印をその戻り先のものに載せ直す。
                attachDecoration(from: tile, alpha: morphDecoration?.alpha ?? 0)
            }
            hide(tile)
        }
        guard let window = view.window else {
            dismiss(animated: false)
            onCloseFinish?()
            return
        }
        let overlay = UIView(frame: window.bounds)
        overlay.isUserInteractionEnabled = false
        backdrop.frame = overlay.bounds
        overlay.addSubview(backdrop)
        let chromeSnapshots = chromeViews.compactMap { chrome -> UIView? in
            guard !chrome.isHidden, chrome.alpha > 0, let snapshot = chrome.snapshotView(afterScreenUpdates: false) else { return nil }
            snapshot.frame = chrome.convert(chrome.bounds, to: window)
            snapshot.alpha = chrome.alpha
            overlay.addSubview(snapshot)
            return snapshot
        }
        morph.frame = view.convert(morph.frame, to: window)
        overlay.addSubview(morph)
        window.addSubview(overlay)
        let moves = movesImage && tile != nil
        // 写しをサムネイルへ戻すときは、戻り終えてから見せるため、ビューアを閉じたときには戻さない。
        // 写しを動かさないときは、閉じる前に見せる。閉じると画面が描き直されるため、閉じてから見せると、その間サムネイルが消えて見える。
        if !moves {
            showHiddenTile()
        }
        let closingTile = hiddenTile
        hiddenTile = nil
        dismiss(animated: false)

        let attachmentID = currentItem.id
        let sourceTile = sourceTile
        // 払った速さで縮み始めるよう、サムネイルへ向かう向きの速さを引き継ぐ。止まった状態から縮み始めると、離した瞬間に一度止まって見える。
        let initialVelocity: Double = if moves, let releaseVelocity, let target = sourceTile(attachmentID).map({ $0.convert($0.bounds, to: window) }) {
            SpringCurve.initialVelocity(
                releaseVelocity: (releaseVelocity.x, releaseVelocity.y),
                from: (morph.frame.midX, morph.frame.midY),
                to: (target.midX, target.midY),
                duration: timing.closeDuration
            )
        } else {
            0
        }
        let flight = MediaClosingFlight(
            parts: MediaClosingFlight.Parts(
                overlay: overlay,
                morph: morph,
                decoration: morphDecoration,
                placeholderColor: morphPlaceholderColor,
                backdrop: backdrop,
                fadingViews: [backdrop] + chromeSnapshots,
                layering: MediaBarLayering(
                    morph: morph,
                    decoration: morphDecoration,
                    backdrop: backdrop,
                    underlay: moves && timing.drawsUnderBars ? makeUnderlay(decoratedLike: tile) : nil,
                    window: window
                )
            ),
            window: window,
            spring: SpringCurve(duration: timing.closeDuration, bounce: releaseVelocity == nil ? 0 : timing.dragCloseBounce, initialVelocity: initialVelocity),
            handoffStart: CGFloat(timing.handoffStart),
            barOverlapFadeEnd: CGFloat(timing.barOverlapFadeEnd),
            startOverlapOpacity: startOverlapOpacity,
            // 戻り先が最初から見つからなければ、その場で薄くする。
            movesImage: moves,
            concealedTile: closingTile,
            findTile: { sourceTile(attachmentID) }
        )
        flight.onFinish = onCloseFinish
        flight.start()
    }

    /// バーの奥に描く写し。写しと同じ画像と切り抜き方で、サムネイルの印も載せる。
    private func makeUnderlay(decoratedLike tile: MediaTileView?) -> MediaBarLayering.Underlay {
        let image = UIImageView(image: morph.image)
        image.contentMode = morph.contentMode
        image.clipsToBounds = true
        image.layer.cornerCurve = morph.layer.cornerCurve
        image.isUserInteractionEnabled = false
        let decoration = tile?.makeDecorationCopy()
        if let decoration {
            decoration.frame = image.bounds
            decoration.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            image.addSubview(decoration)
        }
        return MediaBarLayering.Underlay(image: image, decoration: decoration)
    }
}

extension MediaViewerController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? MediaPageController)?.index, index > 0 else { return nil }
        return page(at: index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? MediaPageController)?.index, index < items.count - 1 else { return nil }
        return page(at: index + 1)
    }

    /// 開いている途中に左右へ切り替え始めたら、開く動きを終えて切り替えを優先する。
    /// 代替テキストを書いている途中なら、切り替え始めた時点の内容で、切り替える前の添付の代替テキストを確定する。
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        completeMotionImmediately()
        endEditingDescription()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = pageViewController.viewControllers?.first as? MediaPageController else { return }
        currentIndex = page.index
        // 切り替えの途中で種類が分かって作り直したページは、切り替えを終えてから差し替える。途中では古いページを見せている。
        if pages[page.index] !== page {
            self.pageController.setViewControllers([self.page(at: page.index)], direction: .forward, animated: false)
        }
        updateChrome()
    }
}

extension MediaViewerController {
    /// 一覧のサムネイルからビューアを開く。`sourceTile`は、添付ファイルのサムネイルを返す。
    /// 閉じる前に一覧のセルが再利用されるなどして見つからなければnilを返し、画像を動かさずに薄くして閉じる。
    static func present(
        attachments: [MediaAttachment],
        startIndex: Int,
        store: MediaImageStore,
        dragToDismiss: DragToDismiss,
        timing: Timing,
        from presenter: UIViewController,
        sourceTile: @escaping @MainActor (MediaAttachment.ID) -> MediaTileView?,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        let viewer = MediaViewerController(
            attachments: attachments,
            startIndex: startIndex,
            store: store,
            dragToDismiss: dragToDismiss,
            timing: timing,
            sourceTile: sourceTile
        )
        viewer.onDismiss = onDismiss
        // 開く動きはビューアの中で描く。
        presenter.present(viewer, animated: false)
    }
}

/// ビューアの1ページ。
class MediaPageController: UIViewController {
    private(set) var item: MediaViewerItem
    var index = 0
    var onSingleTap: (() -> Void)?
    /// 描いている画像が変わった。開閉の写しを、元の画像が届いた時点で差し替えるために使う。
    var onImageChange: (() -> Void)?
    /// 長押しで出すメニューの項目。右上のメニューボタンと同じものを返す。
    var menuElements: (() -> [UIMenuElement])?

    init(item: MediaViewerItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    /// 開いている間に中身が変わった。手元のファイルを読み込み終えたときや、代替テキストを書き直したとき。
    func update(_ item: MediaViewerItem) {
        self.item = item
        if isViewLoaded {
            itemDidChange()
        }
    }

    /// `item`が変わったあとに呼ぶ。
    func itemDidChange() {}

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var allowsInteractiveDismiss: Bool { true }

    /// 添付ファイルを描いている枠。`view`の座標。
    var contentFrame: CGRect { view.bounds }

    /// 開閉で動かす、描いている画像。
    var transitionImage: UIImage? { nil }

    /// 画像を描くページ。開閉の写しを、このページの画像の更新に合わせて差し替える。
    var drawsImage: Bool { false }

    /// 違和感レポートに残す、ページの状態。
    func stateDump() -> String { "" }

    /// ボタンと説明を隠して画像だけにしたとき、ページの中に出しているボタンも合わせて隠す。
    func setChromeHidden(_ hidden: Bool, animated: Bool) {}

    /// 画面の下で、ビューアの説明に隠れている高さ。ページの中のボタンをこれより上に出す。
    var bottomCoveredHeight: CGFloat = 0

    /// 長押しのメニューを指の位置に出すための、見えない小さな目印。
    private let menuAnchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    /// `target`の長押しで、`menuElements`のメニューを指の位置に出す。
    func addLongPressMenu(to target: UIView) {
        target.addInteraction(UIContextMenuInteraction(delegate: self))
        menuAnchor.isUserInteractionEnabled = false
        view.addSubview(menuAnchor)
    }

    /// 長押しした位置でメニューを出すか。`location`は`source`の座標。ほかの操作に長押しを譲る場所ではfalseを返す。
    func offersMenu(at location: CGPoint, in source: UIView) -> Bool { true }
}

extension MediaPageController: UIContextMenuInteractionDelegate {
    /// メニューボタンと同じメニューを出す。出すものがなければ出さない。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let source = interaction.view, offersMenu(at: location, in: source),
              let elements = menuElements?(), !elements.isEmpty
        else { return nil }
        menuAnchor.center = source.convert(location, to: view)
        return UIContextMenuConfiguration(actionProvider: { _ in UIMenu(children: elements) })
    }

    /// 全画面の画像が持ち上がって見えないよう、指の位置の見えない目印をプレビューにして、メニューだけを指の位置に出す。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        anchorPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        anchorPreview()
    }

    private func anchorPreview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: menuAnchor, parameters: parameters)
    }
}

/// 画像のページ。一覧のサムネイルをすぐに出し、元の大きさの画像が届いたら差し替える。
final class ImagePageController: MediaPageController {
    private let store: MediaImageStore
    private let zoomView = ZoomingImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    /// 前に開いたときの元のファイルがキャッシュに残っているかを確かめる。
    private var originalCheckTask: Task<Void, Never>?
    /// 画像の中の文字を選んだり、リンクや電話番号を開いたりする（Live Text）。元の画像が届いてから解析する。
    private let liveText = ImageAnalysisInteraction()
    private var analysisTask: Task<Void, Never>?
    /// 元の画像の解析を終えた。文字が見つからなかったときや、解析に失敗したときも含む。対応していない端末では変わらない。
    private(set) var hasFinishedAnalysis = false
    /// Live Textのボタンの、システムが決めた既定の余白。`supplementaryInterfaceContentInsets`を上書きすると既定の余白が消えるため、説明に重なる分はこれに足す。
    /// 余白は画面上のポイントで指定する。画像を拡大していても、拡大率で割り戻さない。
    private lazy var baseLiveTextInsets = liveText.supplementaryInterfaceContentInsets
    /// 元のファイルをキャッシュに置き終えていれば、そのURL。共有や保存はこのURLでキャッシュから写しを取る。
    private(set) var originalURL: URL?
    /// 一覧で読み込んだサムネイル。
    private let preview: UIImage?
    /// 出している画像の出どころ。違和感レポートに残す。
    private var imageSource = "none"

    /// 元の画像を読み始めた。手元のメディアでは、ファイルを読み込み終えるまで読み始められない。
    private var hasStartedLoading = false

    /// - Parameter preview: 一覧で読み込んだサムネイル。元の画像が届くまでの下地にする。
    init(item: MediaViewerItem, store: MediaImageStore, preview: UIImage?) {
        self.store = store
        self.preview = preview
        super.init(item: item)
    }

    deinit {
        loadTask?.cancel()
        originalCheckTask?.cancel()
        analysisTask?.cancel()
    }

    override var allowsInteractiveDismiss: Bool { !zoomView.isZoomedIn }

    /// 画像から読み取った文字の全文。解析し終えるまでと、文字のない画像ではnil。
    var recognizedText: String? {
        guard let transcript = liveText.analysis?.transcript, !transcript.isEmpty else { return nil }
        return transcript
    }

    /// 画像だけにしたときは、Live Textのボタンも隠す。
    override func setChromeHidden(_ hidden: Bool, animated: Bool) {
        liveText.setSupplementaryInterfaceHidden(hidden, animated: animated)
    }

    override var bottomCoveredHeight: CGFloat {
        didSet { updateLiveTextInsets() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLiveTextInsets()
    }

    /// 画面の下端まで届く画像では、Live Textのボタンが画像の右下に出て説明に重なるため、重なる分だけ上へずらす。
    /// ボタンは安全領域をもとから避けているため、説明のうち安全領域に入っている分は数えない。
    private func updateLiveTextInsets() {
        guard let imageView = liveText.view, imageView.bounds.height > 0 else { return }
        let imageFrame = imageView.convert(imageView.bounds, to: view)
        let overlap = max(imageFrame.maxY - (view.bounds.maxY - bottomCoveredHeight), 0)
        let extra = max(min(overlap, bottomCoveredHeight - view.safeAreaInsets.bottom), 0)
        var insets = baseLiveTextInsets
        insets.bottom += extra
        liveText.supplementaryInterfaceContentInsets = insets
    }

    /// 長押しした位置に文字やリンクがあれば、メニューを出さずにLive Textの選択に任せる。
    override func offersMenu(at location: CGPoint, in source: UIView) -> Bool {
        guard let imageView = liveText.view else { return true }
        let point = source.convert(location, to: imageView)
        return !liveText.hasInteractiveItem(at: point) && !liveText.hasText(at: point)
    }

    override var contentFrame: CGRect {
        zoomView.imageFrame.map { zoomView.convert($0, to: view) } ?? view.bounds
    }

    override var transitionImage: UIImage? { zoomView.image }

    override var drawsImage: Bool { true }

    override func stateDump() -> String {
        """
        imageSource: \(imageSource)
        \(zoomView.stateDump())
        """
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        zoomView.frame = view.bounds
        zoomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomView.onSingleTap = { [weak self] in self?.onSingleTap?() }
        zoomView.imageAccessibilityLabel = item.description
        view.addSubview(zoomView)
        liveText.preferredInteractionTypes = [.textSelection, .dataDetectors]
        zoomView.addImageInteraction(liveText)
        addLongPressMenu(to: zoomView)
        spinner.color = .white
        failureLabel.text = "画像を読み込めませんでした"
        failureLabel.textColor = .secondaryLabel
        failureLabel.isHidden = true
        for subview in [spinner, failureLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                subview.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        // 一覧のサムネイルが手元にあればそれを、なければblurhashのぼかしを、元の画像が届くまでの下地にする。
        let attachment = item.serverAttachment
        let placeholder = preview == nil ? attachment?.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: attachment?.aspectRatio) } : nil
        imageSource = preview != nil ? "thumbnail" : placeholder != nil ? "blurhash" : "none"
        zoomView.image = preview ?? placeholder
        onImageChange?()
        load(hasPreview: preview != nil)
    }

    override func itemDidChange() {
        zoomView.imageAccessibilityLabel = item.description
        if !hasStartedLoading {
            load(hasPreview: preview != nil)
        }
    }

    /// - Parameter hasPreview: 中身の分かるサムネイルを出せている。blurhashのぼかしだけなら、読み込み中と失敗を知らせる。
    private func load(hasPreview: Bool) {
        switch item.source {
        case .server(let attachment):
            hasStartedLoading = true
            load(attachment, hasPreview: hasPreview)
        case .local(let file, _):
            guard let file else {
                // 読み込み終えたら`itemDidChange`で読み始める。
                if !hasPreview {
                    spinner.startAnimating()
                }
                return
            }
            hasStartedLoading = true
            load(file, hasPreview: hasPreview)
        }
    }

    /// 投稿欄で選んだメディアを、手元のファイルから読む。キャッシュには写さない。
    private func load(_ file: LocalMediaFile, hasPreview: Bool) {
        if !hasPreview {
            spinner.startAnimating()
        }
        loadTask = Task { [weak self] in
            let image = await LocalMediaThumbnail.make(for: file, maxPixelSize: CGFloat(MediaImageStore.fullPixelSize))
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image {
                self.imageSource = "local"
                self.zoomView.image = image
                self.onImageChange?()
                self.analyze(image)
            } else {
                self.failureLabel.isHidden = hasPreview
            }
        }
    }

    private func load(_ attachment: MediaAttachment, hasPreview: Bool) {
        guard let url = attachment.url ?? attachment.remoteUrl ?? attachment.previewUrl else {
            failureLabel.isHidden = hasPreview
            return
        }
        if !hasPreview {
            spinner.startAnimating()
        }
        // 前に開いたときの元のファイルが残っていれば、表示のための読み込みを待たずに共有と保存を選べるようにする。
        originalCheckTask = Task { [weak self, store] in
            guard await store.hasOriginal(for: url), let self, !Task.isCancelled else { return }
            self.originalURL = url
        }
        loadTask = Task { [weak self, store] in
            let image = try? await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize, keepsOriginal: true)
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image {
                self.originalURL = await store.hasOriginal(for: url) ? url : nil
                self.imageSource = "full"
                self.zoomView.image = image
                self.onImageChange?()
                self.analyze(image)
            } else {
                // サムネイルを出せていれば、そのまま見せる。
                self.failureLabel.isHidden = hasPreview
            }
        }
    }
}

extension ImagePageController {
    private static let analyzer = ImageAnalyzer()

    /// 元の画像の文字とQRコードなどを解析し、Live Textで選べるようにする。対応していない端末では何もしない。
    /// 解析には、表示用に最大4096pxへ縮めた画像を渡す。極端に縦長の画像では文字が潰れて読めないが、元のファイルを渡しても良くならない。
    /// シミュレーターで幅1000pxの画像に32ptの文字を並べて測ると、高さ5000pxまではどちらでも全行読め、6000pxを超えるとどちらでもほぼ読めず、
    /// 5500pxでは元のファイルのほうが悪かった。高さ16000px以上の元のファイルは「Max supported dimension is 8192」のエラーになった（2026-10-14）。
    /// 縦に区切って解析すれば読める見込みだが、Live Textは1枚の画像に解析の結果を1つしか持てず、区切った結果を文字の選択に使えないため、そこまではしない。
    private func analyze(_ image: UIImage) {
        guard ImageAnalyzer.isSupported else {
            SciaLog.logger(category: "media").info("live text unsupported on this device")
            return
        }
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            do {
                let analysis = try await Self.analyzer.analyze(image, configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode]))
                guard let self, !Task.isCancelled else { return }
                self.liveText.analysis = analysis
                self.hasFinishedAnalysis = true
            } catch {
                SciaLog.logger(category: "media").error("live text analysis failed: \(error.localizedDescription, privacy: .public)")
                guard let self, !Task.isCancelled else { return }
                self.hasFinishedAnalysis = true
            }
        }
    }
}

/// 動画、GIF、音声のページ。GIFはループして音を出さず、操作の部品も出さない。
final class PlayerPageController: MediaPageController {
    private let playerController = AVPlayerViewController()
    /// GIFを最後まで再生したら先頭へ戻す、通知の受け口。
    private var loopObserver: (any NSObjectProtocol)?
    /// 動画の画素を表示の向きにする回し方。端末を縦にして撮った動画は、横向きの画素に回転情報を付けて保存されている。
    private var frameOrientation = UIImage.Orientation.up

    /// 動画の表示の準備が整うまでは、添付ファイルの縦横比で画面に収めた枠を返す。開く遷移はその準備より先に始まるため。
    override var contentFrame: CGRect {
        let videoBounds = playerController.videoBounds
        if !videoBounds.isEmpty {
            return playerController.view.convert(videoBounds, to: view)
        }
        guard let aspectRatio = item.aspectRatio, aspectRatio > 0 else { return view.bounds }
        return AVMakeRect(aspectRatio: CGSize(width: aspectRatio, height: 1), insideRect: view.bounds)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(playerController)
        playerController.view.frame = view.bounds
        playerController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 閉じる操作で動かしたときに画面大の黒い枠が動かないよう、黒はビューアの背景に任せる。
        playerController.view.backgroundColor = .clear
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)
        addLongPressMenu(to: playerController.view)
        setUpPlayer()
    }

    /// 投稿の添付ファイルはURLから、投稿欄で選んだメディアは手元のファイルから再生する。手元のファイルを読み込み終える前なら、読み込み終えたときに作る。
    override func itemDidChange() {
        if playerController.player == nil {
            setUpPlayer()
            if viewIfLoaded?.window != nil {
                playerController.player?.play()
            }
        }
    }

    private var mediaURL: URL? {
        switch item.source {
        case .server(let attachment): attachment.url ?? attachment.remoteUrl
        case .local(let file, _): file?.url
        }
    }

    private func setUpPlayer() {
        guard let url = mediaURL else { return }
        let playerItem = AVPlayerItem(url: url)
        // 再生しているコマを取り出せるようにする。AVPlayerLayerの絵は描き写せないため、映像の出口を別に付ける。
        playerItem.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]))
        let player = AVPlayer(playerItem: playerItem)
        playerController.player = player
        if item.kind == .gifv {
            // `AVPlayerLooper`は使わず、同じ項目を最後で先頭へ戻してくり返す。
            // `AVPlayerLooper`は周ごとに再生する項目を替えるが、実機（iPhone 16 Pro、iOS 27.0.1）の`AVPlayerViewController`では、
            // 再生は周を重ねて進むのに、画面の絵が1周目の終わりで止まった。シミュレーターでは起きない。
            player.isMuted = true
            player.actionAtItemEnd = .none
            loopObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak player] _ in
                MainActor.assumeIsolated {
                    player?.seek(to: .zero)
                }
            }
            playerController.showsPlaybackControls = false
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            playerController.view.addGestureRecognizer(tap)
        }
        Task { [weak self] in
            guard let track = try? await playerItem.asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform)
            else { return }
            self?.frameOrientation = Self.orientation(of: transform)
        }
    }

    isolated deinit {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }

    /// 再生しているコマ。つかんだり閉じたりしたときに、写しを最初のコマ（サムネイル）へ戻さず、その場の絵から動かすために使う。
    /// まだコマを描いていなければnilで、サムネイルを使う。
    override var transitionImage: UIImage? {
        guard let item = playerController.player?.currentItem,
              let output = item.outputs.lazy.compactMap({ $0 as? AVPlayerItemVideoOutput }).first,
              let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil)
        else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        // 取り出した画素は回転情報を反映していないため、再生の表示と同じ向きにする。
        return UIImage(cgImage: cgImage, scale: 1, orientation: frameOrientation)
    }

    /// 動画の回転情報を、画像の向きにする。回転情報は90°刻みなので、最も近い向きに丸める。
    static func orientation(of transform: CGAffineTransform) -> UIImage.Orientation {
        let quarterTurns = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    @objc private func tapped() {
        onSingleTap?()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playerController.player?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playerController.player?.pause()
    }
}

/// アプリで開けない種類のファイルのページ。ブラウザで開く操作を出す。
final class UnsupportedPageController: MediaPageController {
    override func viewDidLoad() {
        super.viewDidLoad()
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "doc")
        configuration.text = "このファイルはアプリで表示できません"
        if let url = item.serverAttachment.flatMap({ $0.remoteUrl ?? $0.url }) {
            configuration.button = .bordered()
            configuration.button.title = "ブラウザで開く"
            configuration.buttonProperties.primaryAction = UIAction { _ in UIApplication.shared.open(url) }
        }
        contentUnavailableConfiguration = configuration
    }
}

/// 画面の下に出す代替テキスト。長ければスクロールして読む。
/// 添付ファイルの説明を、画像を覆わないよう1行で見せる。全文は、タップするか上へ払うかVoiceOverで実行して、シートで読む。
final class CaptionView: UIView {
    private let label = UILabel()
    private let contentGuide = UILayoutGuide()
    /// 全文を読む操作をした。書ける説明では、書き始める操作。
    var onOpen: (() -> Void)?

    /// 投稿欄で選んだメディアの説明。空でも「代替テキストを追加」と出し、タップで書き始める。
    var isEditable = false {
        didSet { updateLabel() }
    }

    var text: String = "" {
        didSet { updateLabel() }
    }

    private func updateLabel() {
        let isPlaceholder = isEditable && text.isEmpty
        label.text = isPlaceholder ? "代替テキストを追加" : text
        label.textColor = isPlaceholder ? UIColor.white.withAlphaComponent(0.6) : .white
        accessibilityLabel = isPlaceholder ? "代替テキストを追加" : text
        accessibilityHint = isEditable ? "代替テキストを編集します。" : "全文を表示します。"
    }

    /// 文字の下端。安全領域に合わせるために使う。
    var contentBottomAnchor: NSLayoutYAxisAnchor { contentGuide.bottomAnchor }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        addLayoutGuide(contentGuide)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            contentGuide.topAnchor.constraint(equalTo: label.topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: label.bottomAnchor),
            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(open))
        swipe.direction = .up
        addGestureRecognizer(swipe)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "全文を表示します。"
    }

    @objc private func open() {
        onOpen?()
    }

    override func accessibilityActivate() -> Bool {
        onOpen?()
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension MediaViewerController.Timing {
    /// チューニングパネルの値で作る。
    /// - Parameter drawsUnderBars: falseなら、チューニングの値によらず、開閉で画像をバーの奥に描かない。
    @MainActor
    init(tuning: TuningStore, drawsUnderBars: Bool = true) {
        self.init(
            openDuration: tuning.value(of: TuningCatalog.mediaOpenDuration),
            closeDuration: tuning.value(of: TuningCatalog.mediaCloseDuration),
            dragCloseBounce: tuning.value(of: TuningCatalog.mediaDragCloseBounce),
            drawsUnderBars: drawsUnderBars && tuning.value(of: TuningCatalog.mediaCloseDrawsUnderBars),
            openHandoffEnd: tuning.value(of: TuningCatalog.mediaOpenHandoffEnd),
            openBarOverlapFadeStart: tuning.value(of: TuningCatalog.mediaOpenBarOverlapFadeStart),
            handoffStart: tuning.value(of: TuningCatalog.mediaCloseHandoffStart),
            barOverlapFadeEnd: tuning.value(of: TuningCatalog.mediaCloseBarOverlapFadeEnd),
            savedChipDuration: tuning.value(of: TuningCatalog.mediaSavedChipDuration),
            savedChipAtBottom: tuning.value(of: TuningCatalog.mediaSavedChipAtBottom)
        )
    }
}

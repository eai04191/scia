import AVKit
import Combine
import CoreImage
import os
import SciaCore
import UIKit
import VisionKit

/// 投稿の添付ファイルを全画面で見る。左右のスワイプで切り替え、画像はピンチとダブルタップで拡大する。
///
/// 開くとき、閉じるとき、下へのスワイプで閉じる操作の間は、画像の複製を一覧のサムネイルとのあいだで動かす。
///
/// UIKitの遷移（標準のズームや、遷移を自前で描く仕組み）は使わない。標準のズームは画面全体に角丸と影を付けて変形するため画面の形の枠が見え、
/// 遷移を自前で描く仕組みは動いている間の操作を受け付けないため、開く途中で下へスワイプしても閉じられない。
/// ビューアはアニメーションなしで出し入れし、動きはビューアの中で描く。開く途中で指が触れたら、動きをその場で止めて指に追従させる。
/// 画像を隠さないよう閉じるボタンは置かず、VoiceOverのエスケープとキーボードのEscでも閉じられるようにする。
final class MediaViewerController: UIViewController {
    private var items: [MediaViewerItem]
    /// 投稿欄で選んだメディアを開いたときの操作。投稿の添付ファイルを見るときはnil。
    private let draftEditing: Editing?
    private let store: MediaImageStore
    /// HDRのメディアを描く明るさを読む設定。
    private let settings: AppSettings
    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private var pages: [Int: MediaPageController] = [:]
    private(set) var currentIndex: Int
    /// 添付ファイルへの操作をまとめたメニューを出す。
    private let menuButton: MenuButton = {
        let button = MenuButton()
        button.configuration = .glass()
        return button
    }()
    private let counterLabel = UILabel()
    let captionView = CaptionView()
    /// 投稿欄から開いたとき、代替テキストを書く入力欄。書いている間だけ出す。
    let descriptionEditor = AltTextEditorView()
    /// 代替テキストを書いている。
    private(set) var isEditingDescription = false
    /// 投稿欄から開いたときの、アップロードや代替テキストの送信の状態。この画面だけのアプリ内通知として、チップの列に差し出す。
    private var draftNotice: Notice?
    /// チップの列から見た、開いている度合い。0で下の画面の位置、1でメニューボタンの行のすぐ下に列を置く。
    private var noticePresence: CGFloat = 0
    /// この画面だけのチップの濃さ。開閉では開いている度合いに、スワイプして閉じる途中はボタン類と同じく背景に合わせる。
    private var noticeScreenAlpha: CGFloat = 0
    /// 共有や保存のために落とす処理。ビューアを閉じても保存を続けるため、セッションで持つ。nilなら共有と保存を出さない（投稿欄から開いたとき）。
    private let transfers: MediaTransferCenter?
    /// 添付ファイルの投稿。共有や保存の失敗を「最近の失敗」に残すときに添える。プロフィールの画像を開いたときはnil。
    private let subject: OperationStatus.Subject?
    /// 画像から読み取った文字を、システムの翻訳シートで訳す。
    private let translation = SystemTranslation()
    private var isChromeHidden = false
    private let dragToDismiss: DragToDismiss
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    /// 閉じる操作を始めたときに押していた位置。`view`の座標。画像をこの点を中心に縮め、指の下に同じ場所が来るようにする。
    private var dismissPanAnchor: CGPoint = .zero
    /// 閉じ終わったときに呼ぶ。複製がサムネイルへ戻る動きは、このあとも続く。
    var onDismiss: (() -> Void)?
    /// メニューの開く項目で、ファイルのURLを開く。ビューアを閉じ終えてから呼ぶ。nilなら開く項目を出さない（Macの別のウィンドウや、編集履歴から開いたとき）。
    var onOpenURL: (@MainActor (URL, LinkBrowser) -> Void)?
    /// 閉じ終えたら開くURL。アプリ内のSafariのシートがビューアの下に隠れないよう、閉じてから開く。
    private var urlToOpenAfterDismiss: (url: URL, browser: LinkBrowser)?
    /// 複製がサムネイルへ戻る動きを終えたときに呼ぶ。投稿欄は、ここで入力欄にキーボードを戻す。
    var onCloseFinish: (() -> Void)?
    /// `closeForSharedContent(dismissed:)`で渡された、画面の重なりから外れたときに呼ぶもの。
    private var dismissedHandlers: [() -> Void] = []
    /// 黒い下地。画像だけを動かし、下地はその場で濃くしたり薄くしたりする。
    private let backdrop = UIView()
    /// 開閉とドラッグで動かす画像の複製。縦横比を保って枠を埋めるように切り抜くため、枠の形をサムネイルとビューアの画像のあいだで変えるだけで、
    /// サムネイルと同じ切り抜き方へ移る。
    private let morph = FocusCroppedImageView()
    /// 複製に載せる、サムネイルの印（ALT、GIF、残りの枚数）の複製。サムネイルに近いほど濃くし、ビューアの画像の大きさでは見せない。
    private var morphDecoration: UIView?
    /// 複製のさらに手前に置く、サムネイルに重なっているビューの複製。印と同じ濃さで出し入れする。
    private var morphOverlap: MediaSourceOverlap?
    /// 複製に敷く、サムネイルの背景の色。印と同じ濃さで出し入れし、透明な部分のある画像でサムネイルとの見え方をそろえる。
    private var morphPlaceholderColor: UIColor?
    /// 複製の画像を、ページが描いている画像に合わせ続けるか。元の画像が届いたら、動いている途中でも差し替える。
    private var morphFollowsPage = false
    private var motion = Motion.idle
    private let timing: Timing
    private let sourceTile: @MainActor (String) -> (any MediaViewerSource)?
    /// 複製を動かしている間、隠している一覧のサムネイル。画像がそこへ戻っていく途中で消えて見えないよう、動かし始めから隠す。
    private var hiddenTile: (any MediaViewerSource)?
    /// 開く途中と、開く途中でつかんでから複製を手前へ寄せ終えるまで、複製を一覧のバーの手前と奥に描き分ける。
    private var barLayering: MediaBarLayering?
    /// `barLayering`で、複製をバーの手前と奥のどちらに見せているか。
    private var barSwap = MediaBarSwap.front
    /// 開く途中でつかんだあと、複製をすべてバーの手前へ寄せる動き。
    private var barConvergence: SpringDriver?
    /// 開閉の動きに、毎フレームの経過時間を送る元。テストでは、実際の時間に頼らずに動きを進めるため、手で送る元を渡す。
    var frameSource: any FrameSource = DisplayLinkFrameSource.shared

    struct Timing {
        /// サムネイルから広げて、ビューアで表示し終えるまでの時間。
        let openDuration: TimeInterval
        /// サムネイルへ縮めて戻すまでの時間。
        let closeDuration: TimeInterval
        /// 下へスワイプして閉じるときの弾み。0で弾まずに止まり、大きいほど行き過ぎてから戻る。
        /// 指で力を加えたときだけ弾ませ、タップで開くときや、ボタンで閉じるときは弾ませない。
        let dragCloseBounce: CGFloat
        /// 開閉するとき、画像のうちバーにかかる部分を、一覧の中に置いた複製でバーの奥に描く。
        let drawsUnderBars: Bool
        /// バーの奥にも描くとき、一覧の中の複製から最前面の複製へ受け渡し終える、開く動きの進み具合。0から1。
        let openHandoffEnd: Double
        /// バーの奥にも描くとき、バーと重なる部分を最前面の複製へ入れ替え始める、開く動きの進み具合。0から1。
        let openBarOverlapFadeStart: Double
        /// バーの奥にも描くとき、最前面の複製を一覧の中の複製へ受け渡し始める進み具合。0から1。
        let handoffStart: Double
        /// バーの奥にも描くとき、閉じ始めにバーと重なっていた部分を一覧の中の複製へ入れ替え終える進み具合。0から1。
        let barOverlapFadeEnd: Double
        /// 写真に保存したことを知らせる表示を出しておく時間。
        let savedChipDuration: TimeInterval
        /// 動画を再生している間、最後に触れてから操作の部品とボタンを隠すまでの時間。
        let videoControlsHideDelay: TimeInterval
        /// ダブルタップで10秒戻ったか進んだことを知らせる表示を、出しておく時間。
        let videoSkipEffectDuration: TimeInterval
        /// 画像をダブルタップして拡大するときと、戻すときの時間。
        let doubleTapZoomDuration: TimeInterval
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
        transfers: MediaTransferCenter? = nil,
        subject: OperationStatus.Subject? = nil,
        settings: AppSettings = AppDependencies.settings,
        sourceTile: @escaping @MainActor (String) -> (any MediaViewerSource)?
    ) {
        precondition(items.indices.contains(startIndex), "開く添付ファイルの位置が範囲外です")
        self.items = items
        self.settings = settings
        self.draftEditing = editing
        self.store = store
        self.transfers = transfers
        self.subject = subject
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
        transfers: MediaTransferCenter? = nil,
        subject: OperationStatus.Subject? = nil,
        sourceTile: @escaping @MainActor (MediaAttachment.ID) -> (any MediaViewerSource)?
    ) {
        self.init(
            items: attachments.map(MediaViewerItem.init),
            startIndex: startIndex,
            store: store,
            dragToDismiss: dragToDismiss,
            timing: timing,
            transfers: transfers,
            subject: subject,
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

    /// 複製を動かしているか。開き終わり、閉じる操作もしていなければfalse。
    var isMoving: Bool {
        if case .idle = motion { return false }
        return true
    }

    override var prefersStatusBarHidden: Bool { isChromeHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { isChromeHidden }

    /// キーボードのEscを受けるため、表示されたら最初の応答者になる。
    override var canBecomeFirstResponder: Bool { true }

    /// 画面に入った最初のフレームから、サムネイルの位置に複製を置いて開き始める。
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if isBeingPresented {
            transfers?.viewerDidOpen(self)
            // チップの列は根の画面のすぐ上にあり、重ねて出したビューアに隠れるため、ビューアの上へ出す。
            overlay?.bringToFront()
            overlay?.update()
            beginOpening()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isEditingDescription {
            becomeFirstResponder()
        }
    }

    /// 閉じたら、チップの列のアプリ全体のものを、閉じる動きと同じ時間をかけて下の画面の位置へ動かす。この画面だけのものは、列から外れて薄くなる。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed {
            overlay?.update(.animated(timing.closeDuration))
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            // 閉じる動きを通らずに閉じられたら、ここでチップの列を根の画面のすぐ上に戻す。動きを通るときは、動きを終えてから戻す。
            if case .closing = motion {} else {
                presentingViewController?.noticeOverlay?.returnBelowPresentations()
            }
            transfers?.viewerDidClose(self)
            showHiddenTile()
            onDismiss?()
            let handlers = dismissedHandlers
            dismissedHandlers = []
            handlers.forEach { $0() }
            if let pending = urlToOpenAfterDismiss {
                urlToOpenAfterDismiss = nil
                onOpenURL?(pending.url, pending.browser)
            }
        }
    }

    /// 画像の複製が見えているか。見えている間はページの画像を隠す。
    var isContentHiddenForTransition: Bool {
        !morph.isHidden
    }

    /// 複製に描いている画像。
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

    /// 複製をサムネイルへ縮めてから閉じる。代替テキストを書いていれば、書き終えてから閉じる。
    @objc func close() {
        UserAction.closeViewer(.button).record()
        beginClosing()
    }

    /// 共有で投稿欄に入れるときのように、ビューアの中の操作によらずに閉じる。閉じ方は`close()`と同じ。
    /// `dismissed`は、画面の重なりから外れたときに呼ぶ。複製がサムネイルへ戻る動きは、そのあとも続く。
    func closeForSharedContent(dismissed: @escaping () -> Void) {
        // 閉じる動きの途中なら、もう画面の重なりから外れている。
        guard presentingViewController != nil, !isBeingDismissed else {
            dismissed()
            return
        }
        dismissedHandlers.append(dismissed)
        // 上に重ねたメニューやシートを先に閉じる。重ねたまま閉じると、閉じる動きの上にそれらが残る。
        if presentedViewController != nil {
            dismiss(animated: false) { [weak self] in self?.beginClosing() }
        } else {
            beginClosing()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.backgroundColor = .black
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        overrideUserInterfaceStyle = .dark
        MediaDynamicRangeTraits.follow(self, settings: settings, { $0.viewerMediaDynamicRange }) { viewer, range in
            viewer.traitOverrides.imageDynamicRange = range
        }
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
        morph.isHidden = true
        view.addSubview(morph)
        setUpChrome()
        updateChrome()
        translation.install(in: self)
        dismissPan.delegate = self
        // ピンチの2本指を閉じる操作と取り違えないようにする。
        dismissPan.maximumNumberOfTouches = 1
        // トラックパッドの2本指スクロールでも、指でスワイプするのと同じように閉じられるようにする（Macやトラックパッド付きのiPad）。
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
        // メニューを開いている間は、動画の部品を自動で隠さない。閉じたら、そこから数え直す。
        menuButton.onMenuOpenChange = { [weak self] isOpen in
            guard let self, !isOpen else { return }
            self.pages[self.currentIndex]?.interactionDidEnd()
        }
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
        setUpDescriptionEditing()
        for view in [menuButton, counterLabel, captionView, descriptionEditor] {
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
    }

    private var chromeViews: [UIView] { [menuButton, counterLabel, captionView] }

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
        for page in pages.values {
            page.isEditingDescription = isEditingDescription
        }
        updateDraftStatus()
        // ページをめくったら、落としている途中のチップを、いま見ている添付ファイルに合わせて出し直す。
        overlay?.update()
        view.setNeedsLayout()
    }

    /// 動画のページに頼まれて、ボタンと説明を隠すか出す。再生している間に触れずにいたときと、再生し終えたとき。
    /// 代替テキストを書いている間と、開閉や閉じる操作で動かしている間は、隠さない。
    private func setChromeHidden(_ hidden: Bool) {
        guard hidden != isChromeHidden else { return }
        if hidden {
            guard !isEditingDescription, !menuButton.isMenuOpen, case .idle = motion else { return }
        }
        toggleChrome()
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
        page.isEditingDescription = isEditingDescription
        if let image = page as? ImagePageController {
            image.doubleTapZoomDuration = timing.doubleTapZoomDuration
        }
        if let player = page as? PlayerPageController {
            player.controlsHideDelay = timing.videoControlsHideDelay
            player.skipEffectDuration = timing.videoSkipEffectDuration
            player.onRequestChromeHidden = { [weak self, weak player] hidden in
                guard let self, let player, player.index == self.currentIndex else { return }
                self.setChromeHidden(hidden)
            }
        }
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
        fileURL(at: currentIndex)
    }

    private func fileURL(at index: Int) -> URL? {
        guard let attachment = items[index].serverAttachment else { return nil }
        switch attachment.type {
        case .image: return (pages[index] as? ImagePageController)?.originalURL
        case .video, .gifv, .audio: return attachment.url ?? attachment.remoteUrl
        case .unknown: return nil
        }
    }

    /// いま見ている添付ファイルの、共有や保存で落とすファイルのURL。落としている途中の知らせを、いま見ているものとほかとに分けるために使う。
    var currentTransferURL: URL? {
        currentFileURL
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

    /// メニューの項目。並びは設定のメディアのメニューに従い、ループ再生と画像の文字の選択は設定の並びの後ろに置く。決まりはdocs/menus.mdの「メディアのメニュー」にある。
    /// 画像の共有や保存は、元のファイルが届くまで選べなくする。動画などは選んでから落とす。
    /// 保存は写真に入る画像、動画、GIFだけ、翻訳は画像から文字を読み取れたときだけ、代替テキストは付いているときだけ出す。
    func menuElements() -> [UIMenuElement] {
        if let editing = draftEditing {
            return editingMenuElements(editing)
        }
        let attachment = currentItem.serverAttachment
        var menu = MediaMenu(kind: currentItem.kind, attachment: attachment)
        let canTransfer = currentFileURL != nil && transfers != nil
        menu.share = MediaMenu.Command(isEnabled: canTransfer || currentUnsupportedURL != nil) { [weak self] in self?.share() }
        menu.saveToPhotos = MediaMenu.Command(isEnabled: canTransfer) { [weak self] in self?.saveToPhotos() }
        if let text = (pages[currentIndex] as? ImagePageController)?.recognizedText, !text.isEmpty {
            menu.translateText = MediaMenu.Command { [weak self] in self?.translation.present(text) }
        }
        menu.showAltText = MediaMenu.Command { [weak self] in self?.showAltText() }
        menu.fileURL = attachment.flatMap { $0.url ?? $0.remoteUrl }
        menu.details = pages[currentIndex]?.fileDetails
        // リンクのコピーは、開く先がなくても出す。
        menu.opensURLs = onOpenURL != nil
        menu.urlHandlers = URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in
                UIPasteboard.general.url = url
                self?.showCopiedNotice(.linkCopied)
            },
            share: { [weak self] url in self?.presentShareSheet(url) },
            open: { [weak self] url, browser in
                self?.urlToOpenAfterDismiss = (url, browser)
                self?.close()
            }
        )
        menu.copyValue = { [weak self] value in
            UIPasteboard.general.string = value
            self?.showCopiedNotice(.textCopied)
        }
        var elements = menu.elements(layout: settings.mediaMenuLayout)
        if let loop = (pages[currentIndex] as? PlayerPageController)?.loopMenuAction() {
            elements.append(UIMenu(options: .displayInline, children: [loop]))
        }
        if let liveText = currentImagePage?.liveTextMenuAction() {
            elements.append(UIMenu(options: .displayInline, children: [liveText]))
        }
        return elements
    }

    /// コピーしたことを、このウインドウのチップの列に数秒出す。
    private func showCopiedNotice(_ notice: Notice) {
        overlay?.showTransient({ _ in notice }, duration: timing.savedChipDuration, replacing: nil)
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
        let loop = (pages[currentIndex] as? PlayerPageController)?.loopMenuAction()
        let liveText = currentImagePage?.liveTextMenuAction()
        return [edit] + [loop, liveText].compactMap(\.self) + editing.menuElements(currentItem.id)
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

    /// 投稿欄から開いたとき、アップロードや代替テキストの送信の状態を、チップの列に差し出す。投稿欄から開いたときは落とすことがないため、落としている途中のものとは重ならない。
    private func updateDraftStatus() {
        guard draftEditing != nil else { return }
        draftNotice = Notice.draftStatus(currentItem.draftStatus, progress: currentItem.draftProgress, reduction: currentItem.draftReduction) { [weak self] in
            guard let self, let editing = self.draftEditing else { return }
            editing.showFailure(self.currentItem.id, self)
        }
        overlay?.update()
    }

    /// 表示中の添付ファイルを写真に保存する。手元になければ落としてから保存する。ビューアを閉じても続け、済んだら閉じた先の一覧で知らせる。
    func saveToPhotos() {
        guard let target = currentTransferTarget else { return }
        transfers?.start(.save, target, from: self)
    }

    /// 表示中の添付ファイルを、共有や保存のために落とすときの対象。
    private var currentTransferTarget: MediaTransfers.Target? {
        guard let url = currentFileURL else { return nil }
        return MediaTransfers.Target(url: url, kind: currentItem.kind, subject: subject)
    }

    /// 重ねているウインドウのチップの列。出した直後でウインドウに載る前は、出した画面のウインドウから探す。
    private var overlay: NoticeOverlay? {
        noticeOverlay ?? presentingViewController?.noticeOverlay
    }

    /// このウインドウのチップの列。テストで中身を確かめるのに使う。
    var noticeStack: NoticeStackView? {
        overlay?.column.stack
    }

    /// 写真に保存したことや、共有や保存の失敗を知らせている文言。知らせていなければnil。
    var statusChipText: String? {
        noticeStack?.transientNotice?.text
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
        if let target = currentTransferTarget, let transfers {
            transfers.start(.share, target, from: self)
        } else if let url = currentUnsupportedURL {
            presentShareSheet(url)
        }
    }

    /// 共有のために用意したファイルの、共有のシートを出す。落としている間にページを替えられるため、`url`の添付ファイルのページからプレビューを取る。
    func presentShareSheet(for file: URL, of url: URL) {
        let index = items.indices.first { fileURL(at: $0) == url } ?? currentIndex
        presentShareSheet(shareSheetItem(for: file, at: index))
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
        transfers?.chipNotice(in: NoticeContext(viewer: NoticeContext.Viewer(currentURL: currentTransferURL)))?.text
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
            // 書いている間にスワイプしたら、閉じずにキーボードを下げて書き終える。もう一度スワイプすれば閉じる。
            if isDownward {
                endEditingDescription()
            }
            return false
        }
        return allowsInteractiveDismiss && isDownward
    }

    /// 代替テキストの入力欄の中のドラッグ（スクロールや、長押しからのカーソル移動）は、閉じる操作にせず入力欄に任せる。
    /// ボタンやシークバーの上から始めたドラッグも、閉じる操作にせず、その部品に任せる。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dismissPan, let touched = touch.view else { return true }
        return !touched.isDescendant(of: descriptionEditor) && !Self.isInsideControl(touched)
    }

    private static func isInsideControl(_ view: UIView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0 is UIControl }
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
            // ボタンと説明は、背景が半分透けたところで消えきるようにする。この画面だけのチップは、ボタン類を隠していても残るものがあるため、隠したかによらず薄くする。
            // アプリ全体のチップは消さず、背景の濃さに合わせて下の画面の位置へ近づける。
            for chrome in chromeViews {
                chrome.alpha = isChromeHidden ? 0 : max(backgroundAlpha * 2 - 1, 0)
            }
            setNoticePresence(backgroundAlpha, screenAlpha: max(backgroundAlpha * 2 - 1, 0))
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

// MARK: - 複製の動き

extension MediaViewerController {
    /// 複製の動き。開く、指に追従する、元へ戻す、閉じるの順に移る。開く途中と戻す途中は、指が触れたら止めて追従に移る。
    fileprivate enum Motion {
        /// 複製を隠し、ページの画像を見せている。
        case idle
        case opening(SpringDriver)
        /// 指に追従している。`start`はつかんだときの複製の枠、`visibility`はそのときの開いている度合い。
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
        for chrome in chromeViews {
            chrome.alpha = isChromeHidden ? 0 : visibility
        }
        setNoticePresence(visibility, screenAlpha: visibility)
    }

    /// チップの列に、開いている度合いを伝える。呼んだ側のアニメーションに任せて動かす。
    private func setNoticePresence(_ presence: CGFloat, screenAlpha: CGFloat) {
        noticePresence = presence
        noticeScreenAlpha = screenAlpha
        overlay?.update()
    }

    private var currentTile: (any MediaViewerSource)? {
        sourceTile(currentItem.id)
    }

    private func tileFrame(of tile: any MediaViewerSource) -> CGRect {
        tile.convert(tile.bounds, to: view)
    }

    /// 複製を見せ、ページの画像と一覧のサムネイルを隠す。複製の画像は、ページが描いている画像か、まだ描いていなければサムネイルの画像。
    /// どちらもなければ（アプリで表示できないファイルなど）、ページを描き写した画像を使う。
    /// 画像を描くページなら、最初に画像がなくても、届いた時点で複製を差し替える。
    /// - Parameter decorationAlpha: サムネイルの印の濃さ。サムネイルの位置から始めるなら1、ビューアの画像の位置から始めるなら0。
    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    private func showMorph(frame: CGRect, cornerRadius: CGFloat, tile: (any MediaViewerSource)?, decorationAlpha: CGFloat) {
        let page = pages[currentIndex]
        morph.image = page?.transitionImage ?? tile?.thumbnailImage ?? page.map(Self.snapshot)
        attachDecoration(from: tile, alpha: decorationAlpha)
        morphFollowsPage = page?.drawsImage ?? false
        morph.frame = frame
        morph.layer.cornerRadius = cornerRadius
        morph.layer.cornerCurve = tile?.layer.cornerCurve ?? .continuous
        // リンクカードのサムネイルのように、外側の角だけを丸めたサムネイルもあるため、丸める角も合わせる。
        morph.layer.maskedCorners = tile?.layer.maskedCorners ?? Self.allCorners
        morph.alpha = 1
        morph.isHidden = false
        setPageHidden(true)
        hide(tile)
    }

    /// サムネイルの印の複製を、複製に載せ直す。サムネイルを隠す前に描き写す必要がある。
    /// 切り抜く位置も、サムネイルの焦点に合わせ直す。
    /// 複製の大きさが変わっても角からの位置を保つよう、複製いっぱいに広げて自動で位置を合わせる。
    private func attachDecoration(from tile: (any MediaViewerSource)?, alpha: CGFloat) {
        morphDecoration?.removeFromSuperview()
        morph.focus = tile?.thumbnailFocus
        morphPlaceholderColor = tile?.placeholderColor
        morphDecoration = tile.map { tile in
            let decoration = tile.makeDecorationCopy()
            decoration.frame = morph.bounds
            decoration.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            morph.addSubview(decoration)
            return decoration
        }
        morphOverlap?.view.removeFromSuperview()
        morphOverlap = tile.flatMap { tile in view.window.flatMap { MediaSourceOverlap(source: tile, in: $0) } }
        if let overlap = morphOverlap {
            overlap.move(to: view)
            view.insertSubview(overlap.view, aboveSubview: morph)
        }
        setDecorationAlpha(alpha)
    }

    /// サムネイルの印と背景の濃さ。サムネイルの大きさで1、ビューアの画像の大きさで0。
    private func setDecorationAlpha(_ alpha: CGFloat) {
        morphDecoration?.alpha = alpha
        morphOverlap?.view.alpha = alpha
        morph.backgroundColor = Self.placeholderColor(morphPlaceholderColor, alpha: alpha)
    }

    static func placeholderColor(_ color: UIColor?, alpha: CGFloat) -> UIColor? {
        color.map { $0.withAlphaComponent($0.cgColor.alpha * alpha) }
    }

    private func hideMorph() {
        morph.isHidden = true
        morphOverlap?.view.removeFromSuperview()
        morphOverlap = nil
        morphFollowsPage = false
        setPageHidden(false)
    }

    /// ページを見えなくする。透明にすると触れても反応しなくなるため、空のマスクで隠し、複製を動かしている間も左右の切り替えやタップを受け付ける。
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
    private func hide(_ tile: (any MediaViewerSource)?) {
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

    /// 複製をサムネイルの位置からビューアの画像の位置へ広げる。バーの奥と手前の描き分けを複製の位置と同じフレームで描くため、
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
        let driver = SpringDriver(spring: SpringCurve(duration: timing.openDuration, bounce: 0), source: frameSource, update: update) { [weak self] in
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

    /// 複製をバーの手前と奥に描き分ける準備をする。バーの奥に描かない設定や、サムネイルを含む一覧の行が見つからなければnil。
    private func makeBarLayering(tile: any MediaViewerSource) -> MediaBarLayering? {
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

    /// 複製の今の位置で、バーの手前と奥の描き分けを描き直す。描き分けていなければ何もしない。
    private func applyBarLayering() {
        guard let layering = barLayering, let window = view.window else { return }
        morph.alpha = 1 - barSwap.handoff
        layering.apply(clipRect: layering.visibleRect, overlapRect: window.bounds, swap: barSwap, visibility: 1)
    }

    /// 開く途中でつかんだら、指で動かす複製をすべてバーの手前へ短い時間で寄せる。閉じる操作の間は、複製をバーの手前に描くため。
    private func convergeBarLayeringToFront() {
        guard barLayering != nil else { return }
        let from = barSwap
        let driver = SpringDriver(spring: SpringCurve(duration: Self.barConvergenceDuration, bounce: 0), source: frameSource) { [weak self] progress in
            self?.barSwap = from.converging(toFront: progress)
            self?.applyBarLayering()
        } completion: { [weak self] in
            self?.endBarLayering()
        }
        barConvergence = driver
        driver.start()
    }

    /// 描き分けをやめ、複製をすべてバーの手前に見せる。
    private func endBarLayering() {
        barConvergence?.stop()
        barConvergence = nil
        guard let layering = barLayering else { return }
        layering.tearDown()
        barLayering = nil
        barSwap = .front
        morph.alpha = 1
    }

    /// 開く途中でつかんだあと、複製をバーの手前へ寄せ終えるまでの時間。
    private static let barConvergenceDuration: TimeInterval = 0.15

    /// 開ききったら、複製を隠してページの画像に戻す。隠していたサムネイルも、黒い下地で覆われているので戻す。
    private func finishOpen() {
        endBarLayering()
        hideMorph()
        showHiddenTile()
        pageController.view.alpha = 1
        motion = .idle
        pages[currentIndex]?.interactionDidEnd()
    }

    /// 開いている途中や戻している途中なら、その場で止めてつかむ。開ききっていれば、ビューアの画像の位置に複製を出してつかむ。
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

    /// 開いている途中や戻している途中に止めた複製をつかむ。
    private func grabMovingMorph() {
        if morph.isHidden {
            // 薄くして開いていた途中なら、ここから複製を出す。
            showMorph(frame: contentFrame(in: view), cornerRadius: 0, tile: currentTile, decorationAlpha: 0)
        } else {
            hide(currentTile)
        }
    }

    /// 閉じずに離したら、複製をビューアの画像の枠へ戻し、開ききった状態にする。
    private func settle() {
        guard case .dragging = motion else { return }
        // つかんでから複製を手前へ寄せ終える前に離していたら、残りを寄せずに手前に見せる。寄せる時間（0.15秒）より短い操作に限られるため受け入れる。
        // 戻す動きはUIKitのアニメーションで描くため、描き分けのマスクを複製の位置に合わせ続けられない。
        endBarLayering()
        let animator = makeAnimator(duration: dragToDismiss.restoreDuration, bounce: 0)
        let target = contentFrame(in: view)
        animator.addAnimations {
            self.morph.frame = target
            self.morph.layoutIfNeeded()
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

    /// 閉じると決めたら、すぐにビューアを閉じ、複製と下地とボタンの複製を、操作を素通しする最前面の層へ移してサムネイルへ縮める。
    /// ビューアを残したまま動かすと、残った画面が触れたものを吸い、閉じた直後に別の画像をタップしても開けない。
    /// サムネイルが見つからなければ、その場で薄くする。
    /// - Parameter releaseVelocity: 下へスワイプして閉じたときの、指を離したときの速さ。スワイプして閉じるときだけ、この速さを引き継いで弾ませる。
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
        // Escやメニューから閉じたときに限られ、下へスワイプして閉じるときはつかんだ時点で手前へ寄せ始めているため受け入れる。
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
        morphOverlap?.move(to: overlay)
        window.addSubview(overlay)
        // チップの列は、閉じる動きを描く層の手前に残す。閉じ終えたら、根の画面のすぐ上に戻す。
        let noticeOverlay = self.overlay
        noticeOverlay?.bringToFront()
        let moves = movesImage && tile != nil
        // 複製をサムネイルへ戻すときは、戻り終えてから見せるため、ビューアを閉じたときには戻さない。
        // 複製を動かさないときは、閉じる前に見せる。閉じると画面が描き直されるため、閉じてから見せると、その間サムネイルが消えて見える。
        if !moves {
            showHiddenTile()
        }
        let closingTile = hiddenTile
        hiddenTile = nil
        dismiss(animated: false)

        let attachmentID = currentItem.id
        let sourceTile = sourceTile
        // スワイプした速さで縮み始めるよう、サムネイルへ向かう向きの速さを引き継ぐ。止まった状態から縮み始めると、離した瞬間に一度止まって見える。
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
                overlap: morphOverlap,
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
            source: frameSource,
            findTile: { sourceTile(attachmentID) }
        )
        let onCloseFinish = onCloseFinish
        flight.onFinish = { [weak noticeOverlay] in
            noticeOverlay?.returnBelowPresentations()
            onCloseFinish?()
        }
        flight.start()
    }

    /// バーの奥に描く複製。複製と同じ画像と切り抜き方で、サムネイルの印も載せる。
    private func makeUnderlay(decoratedLike tile: (any MediaViewerSource)?) -> MediaBarLayering.Underlay {
        let image = FocusCroppedImageView()
        image.image = morph.image
        image.focus = morph.focus
        image.layer.cornerCurve = morph.layer.cornerCurve
        image.layer.maskedCorners = morph.layer.maskedCorners
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
        transfers: MediaTransferCenter? = nil,
        subject: OperationStatus.Subject? = nil,
        sourceTile: @escaping @MainActor (MediaAttachment.ID) -> (any MediaViewerSource)?,
        onDismiss: @escaping @MainActor () -> Void,
        openURL: (@MainActor (URL, LinkBrowser) -> Void)? = nil,
        frameSource: any FrameSource = DisplayLinkFrameSource.shared
    ) {
        let viewer = MediaViewerController(
            attachments: attachments,
            startIndex: startIndex,
            store: store,
            dragToDismiss: dragToDismiss,
            timing: timing,
            transfers: transfers,
            subject: subject,
            sourceTile: sourceTile
        )
        viewer.onDismiss = onDismiss
        viewer.onOpenURL = openURL
        viewer.frameSource = frameSource
        // 開く動きはビューアの中で描く。
        presenter.present(viewer, animated: false)
    }
}

/// ビューアの1ページ。
class MediaPageController: UIViewController {
    private(set) var item: MediaViewerItem
    var index = 0
    var onSingleTap: (() -> Void)?
    /// 描いている画像が変わった。開閉の複製を、元の画像が届いた時点で差し替えるために使う。
    var onImageChange: (() -> Void)?
    /// 長押しで出すメニューの項目。右上のメニューボタンと同じものを返す。
    var menuElements: (() -> [UIMenuElement])?
    /// ファイルの中身から読んだ、メディアの情報に出す詳しい値。読み終えるまでと、読めなかったときはnil。
    var fileDetails: MediaFileDetails?

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

    /// 画像を描くページ。開閉の複製を、このページの画像の更新に合わせて差し替える。
    var drawsImage: Bool { false }

    /// 違和感レポートに残す、ページの状態。
    func stateDump() -> String { "" }

    /// ボタンと説明を隠して画像だけにしたとき、ページの中に出しているボタンも合わせて隠す。
    func setChromeHidden(_ hidden: Bool, animated: Bool) {}

    /// 開き終えたか、閉じる操作で動かしたあと閉じずに戻し終えたか、右上のメニューを閉じた。
    /// その間、ビューアはボタンを隠す頼みを受けないため、ここで頼み直す。
    func interactionDidEnd() {}

    /// 画面の下で、ビューアの説明に隠れている高さ。ページの中のボタンをこれより上に出す。
    var bottomCoveredHeight: CGFloat = 0

    /// ビューアで代替テキストを書いている。
    var isEditingDescription = false

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
    /// 元のファイルをキャッシュに置き終えていれば、そのURL。共有や保存はこのURLでキャッシュからコピーを取る。
    private(set) var originalURL: URL? {
        didSet {
            if originalURL != oldValue { readFileDetails() }
        }
    }
    private var detailsTask: Task<Void, Never>?
    /// 一覧で読み込んだサムネイル。
    private let preview: UIImage?
    /// 出している画像の出どころ。違和感レポートに残す。
    private var imageSource = "none"

    /// 元の画像を読み始めた。手元のメディアでは、ファイルを読み込み終えるまで読み始められない。
    private var hasStartedLoading = false
    /// 読み始めた手元のファイル。投稿欄で縮めて作り直したら替わる。
    private var loadedLocalURL: URL?

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

    /// ダブルタップして拡大するときと、戻すときの時間。
    var doubleTapZoomDuration: TimeInterval {
        get { zoomView.doubleTapZoomDuration }
        set { zoomView.doubleTapZoomDuration = newValue }
    }

    override var allowsInteractiveDismiss: Bool { !zoomView.isZoomedIn }

    /// 画像から読み取った文字の全文。解析し終えるまでと、文字のない画像ではnil。
    var recognizedText: String? {
        guard let transcript = liveText.analysis?.transcript, !transcript.isEmpty else { return nil }
        return transcript
    }

    /// 読み取った文字やコードを光らせて、どこにあるかを見せる状態を切り替える。読み取れるものがなければnil。
    /// Live Textのボタンは画像に重なって見る邪魔になるため出さず、この項目で代える。光らせなくても、文字やコードは長押しで選べる。
    func liveTextMenuAction() -> UIAction? {
        guard liveText.analysis?.hasResults(for: [.text, .machineReadableCode]) == true else { return nil }
        return UIAction(title: "画像の文字を選択", image: UIImage(systemName: "text.viewfinder"), state: liveText.selectableItemsHighlighted ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.liveText.selectableItemsHighlighted.toggle()
        }
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
        liveText.isSupplementaryInterfaceHidden = true
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
        if let width = attachment?.meta?.original?.width, let height = attachment?.meta?.original?.height {
            zoomView.naturalSize = CGSize(width: width, height: height)
        }
        zoomView.image = preview ?? placeholder
        onImageChange?()
        load(hasPreview: preview != nil)
    }

    override func itemDidChange() {
        zoomView.imageAccessibilityLabel = item.description
        if !hasStartedLoading {
            load(hasPreview: preview != nil)
        } else if case .local(let file?, _) = item.source, file.url != loadedLocalURL {
            // 投稿欄で縮めて作り直したら、投稿される中身を確かめられるよう読み直す。読み終えるまで、前の画像を出したままにする。
            load(file, hasPreview: true)
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

    /// 投稿欄で選んだメディアを、手元のファイルから読む。キャッシュにはコピーしない。
    private func load(_ file: LocalMediaFile, hasPreview: Bool) {
        if !hasPreview {
            spinner.startAnimating()
        }
        loadedLocalURL = file.url
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await LocalMediaThumbnail.make(for: file, maxPixelSize: CGFloat(MediaImageStore.fullPixelSize))
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image {
                self.imageSource = "local"
                self.zoomView.naturalSize = image.size
                self.zoomView.image = image
                self.onImageChange?()
                self.analyze(image)
            } else {
                self.failureLabel.isHidden = hasPreview
            }
        }
    }

    /// キャッシュに置いた元のファイルから、メディアの情報に出す詳しい値を読む。
    private func readFileDetails() {
        detailsTask?.cancel()
        fileDetails = nil
        guard let url = originalURL else { return }
        detailsTask = Task { [weak self, store] in
            guard let file = await store.originalFile(for: url) else { return }
            let details = await MediaFileDetails.image(at: file)
            guard let self, !Task.isCancelled else { return }
            self.fileDetails = details
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
                // サーバーが元の大きさを返さなければ、届いた画像の大きさを等倍にする。サムネイルを出していた間は画面に収めていたため、ここで大きさが変わる。
                if self.zoomView.naturalSize == nil {
                    self.zoomView.naturalSize = image.size
                }
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
///
/// 動画と音声には、標準の再生画面の操作の部品の代わりに`VideoControlsView`を重ねる。タップで、ビューアのボタンや説明とまとめて出し入れする。
/// 再生している間は、最後に触れてから`controlsHideDelay`秒で、ビューアに隠すよう頼む。長押ししている間は2倍速で再生する。
final class PlayerPageController: MediaPageController {
    private let playerController = AVPlayerViewController()
    /// GIFを最後まで再生したら先頭へ戻す、通知の受け口。
    private var loopObserver: (any NSObjectProtocol)?
    /// 動画を最後まで再生したら、隠したボタンや操作の部品を出すための通知の受け口。
    private var endObserver: (any NSObjectProtocol)?
    /// VoiceOverを入れたり切ったりしたときに、自動で隠すかを決め直す通知の受け口。
    private var voiceOverObserver: (any NSObjectProtocol)?
    /// 再生している間、操作の部品の再生位置を進める受け口。
    private var timeObserver: Any?
    private var statusObservation: AnyCancellable?
    /// 動画の画素を表示の向きにする回し方。端末を縦にして撮った動画は、横向きの画素に回転情報を付けて保存されている。
    private var frameOrientation = UIImage.Orientation.up
    /// 動画と音声の操作の部品。GIFではnil。
    private var controls: VideoControlsView?
    /// 音声のトラックがあるか。なければ消音のボタンを出さない。
    private var hasAudio = false
    /// 再生している間、最後に触れてから操作の部品とビューアのボタンを隠すまでの時間。
    var controlsHideDelay: TimeInterval = 3
    /// ダブルタップで10秒戻ったか進んだことを知らせる表示を、出しておく時間。
    var skipEffectDuration: TimeInterval = 0.3
    /// 最後まで再生したら先頭から続ける。右上のメニューで、その動画を見ている間だけ切り替える。
    private(set) var isLooping = false
    /// ビューアのボタンと説明を隠す（true）か出す（false）よう、ビューアに頼む。
    var onRequestChromeHidden: ((Bool) -> Void)?
    private var isChromeHidden = false
    /// このページで、一度でもボタンと部品を隠したか。隠すまでは、再生を始めたらすぐ隠し、映像だけを見せて始める。
    /// 開く途中など、ビューアが隠す頼みを捨てたときは、動き終えたところで頼み直す。
    private var hasHiddenChrome = false
    /// 時間をおく処理の時計。テストでは手で進める時計に差し替える。
    var clock: any Clock<Duration> = AppDependencies.clock
    private var hideTask: Task<Void, Never>?
    /// シークしている行き先の秒数。シークし終えたらnil。
    private var pendingSeek: Double?
    /// 出したシークの番号。取り消された古いシークの完了を、最新のシークの完了と取り違えないために使う。
    private var seekGeneration = 0
    /// シークバーを動かし始めたとき、再生していたか。動かし終えたら、その状態に戻す。
    private var wasPlayingBeforeScrub = false
    /// 長押しで速く再生し始めたとき、再生していたか。指を離したら、その状態に戻す。長押ししていなければnil。
    private var wasPlayingBeforeFastForward: Bool?

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
        playerController.showsPlaybackControls = false
        // 止めたコマの文字を長押しで選べる機能は、長押しの2倍速とぶつかるため切る。
        playerController.allowsVideoFrameAnalysis = false
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        if item.kind == .gifv {
            addLongPressMenu(to: playerController.view)
        } else {
            // 標準の再生画面は、操作の部品を出さなくても、ダブルタップやピンチを自前で受けて、こちらのタップやダブルタップと取り合う。
            // 映像を描かせるだけにし、タッチはこのページで受ける。
            playerController.view.isUserInteractionEnabled = false
            setUpControls()
            // 標準の再生画面と同じく、左右をダブルタップして10秒戻る・進む。1回のタップは、ダブルタップでないと分かってから扱う。
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }
        setUpPlayer()
        registerForTraitChanges([UITraitImageDynamicRange.self]) { (self: Self, _) in
            self.applyDynamicRange()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyDynamicRange()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyDynamicRange()
    }

    /// 画像と同じく、ビューアの設定の明るさの幅で動画を描く。
    /// `AVPlayerViewController`の`preferredDisplayDynamicRange`だけでは、実機（iPhone 16 Pro、iOS 27）でSDRにしても効かなかったため、中の`AVPlayerLayer`にも直接指定する。
    /// `preferredDisplayDynamicRange`が自動のままだと、`AVPlayerViewController`は画面に出るときにレイヤーを`high`に書き戻すため、こちらにも同じ値を指定して自動をやめさせる。
    /// レイヤーは再生の準備が進んでから作られ、こちらの並べ直しが呼ばれないこともあるので、再生の状態が変わったときにも指定し直す。
    private func applyDynamicRange() {
        let range = traitCollection.imageDynamicRange
        let displayRange = AVDisplayDynamicRange(range)
        if playerController.preferredDisplayDynamicRange != displayRange {
            playerController.preferredDisplayDynamicRange = displayRange
        }
        let dynamicRange = CALayer.DynamicRange(range)
        var pending = [playerController.view.layer]
        while let layer = pending.popLast() {
            if layer is AVPlayerLayer, layer.preferredDynamicRange != dynamicRange {
                layer.preferredDynamicRange = dynamicRange
            }
            pending.append(contentsOf: layer.sublayers ?? [])
        }
    }

    /// 投稿の添付ファイルはURLから、投稿欄で選んだメディアは手元のファイルから再生する。手元のファイルを読み込み終える前なら、読み込み終えたときに作る。
    override func itemDidChange() {
        if playerController.player == nil {
            setUpPlayer()
            if viewIfLoaded?.window != nil {
                playerController.player?.play()
            }
        } else {
            reloadPlayerIfFileChanged()
        }
    }

    /// 投稿欄で動画を書き出し終えたら、投稿される中身を確かめられるよう、書き出したファイルに替える。見ていた位置と再生の状態は保つ。
    private func reloadPlayerIfFileChanged() {
        guard let player = playerController.player, let url = mediaURL, let playing = playingURL, playing != url else { return }
        let time = player.currentTime()
        let wasPlaying = player.timeControlStatus != .paused
        for observer in [loopObserver, endObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
        loopObserver = nil
        endObserver = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation = nil
        player.pause()
        playerController.player = nil
        setUpPlayer()
        playerController.player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying {
            playerController.player?.play()
        }
    }

    /// 再生しているファイルやURL。プレイヤーを作る前はnil。
    var playingURL: URL? {
        (playerController.player?.currentItem?.asset as? AVURLAsset)?.url
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
        // 画素は10bitで受け取る。実機（iPhone 16 Pro、iOS 27）では、8bitのRGBを求めると画面の再生までHDRを失い、HLGの動画が白飛びした。
        playerItem.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]))
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
        } else {
            player.actionAtItemEnd = isLooping ? .none : .pause
            observe(player, playing: playerItem)
        }
        Task { [weak self] in
            guard let track = try? await playerItem.asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform)
            else { return }
            self?.frameOrientation = Self.orientation(of: transform)
        }
        // メディアの情報に出す、コーデックなどの詳しい値。再生と同じく、ストリーミングで読む。
        if let asset = playerItem.asset as? AVURLAsset {
            Task { [weak self] in
                let details = await MediaFileDetails.movie(asset)
                self?.fileDetails = details
            }
        }
    }

    /// 再生の状態と位置を、操作の部品に映す。
    private func observe(_ player: AVPlayer, playing playerItem: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateControls()
            }
        }
        statusObservation = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.playbackStatusDidChange()
                }
            }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isLooping {
                    // 最後で止めずに先頭から続ける。止めないため、隠したボタンや操作の部品は出さない。
                    player?.seek(to: .zero)
                } else {
                    self.onRequestChromeHidden?(false)
                }
            }
        }
        Task { [weak self] in
            let audible = try? await playerItem.asset.loadTracks(withMediaCharacteristic: .audible)
            _ = try? await playerItem.asset.load(.duration)
            self?.hasAudio = audible?.isEmpty == false
            self?.updateControls()
        }
    }

    private func setUpControls() {
        let controls = VideoControlsView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.coveredBottom = bottomCoveredHeight
        controls.onPlayPause = { [weak self] in self?.togglePlayback() }
        controls.onSkip = { [weak self] seconds in
            guard let self else { return }
            self.skip(by: seconds)
            // ボタンで10秒戻ったり進んだりしたときも、ダブルタップと同じく矢印を回す。
            self.controls?.showSkipEffect(forward: seconds > 0, duration: self.skipEffectDuration)
        }
        controls.onScrub = { [weak self] phase, progress in self?.scrub(phase, to: progress) }
        controls.onMuteToggle = { [weak self] in self?.toggleMute() }
        controls.speedMenuElements = { [weak self] in self?.speedMenuElements() ?? [] }
        controls.onInteraction = { [weak self] in self?.scheduleAutoHide() }
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.controls = controls
        // ビューアは、ページを読み込む前に隠しているかを伝えるため、作った時点の状態を映す。
        controls.setControlsHidden(isChromeHidden || isEditingDescription, animated: false)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.delegate = self
        view.addGestureRecognizer(longPress)
        voiceOverObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.voiceOverStatusDidChange()
            }
        }
    }

    /// VoiceOverを入れたら、隠していた部品を出し、自動で隠すのをやめる。切ったら、再生中なら数え直す。
    private func voiceOverStatusDidChange() {
        if UIAccessibility.isVoiceOverRunning {
            onRequestChromeHidden?(false)
        }
        scheduleAutoHide()
    }

    isolated deinit {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let voiceOverObserver {
            NotificationCenter.default.removeObserver(voiceOverObserver)
        }
        if let timeObserver {
            playerController.player?.removeTimeObserver(timeObserver)
        }
    }

    /// 再生している位置を部品に映す。`elapsed`を渡したら、プレイヤーの位置の代わりにそれを出す。シークしてから位置が届くまでの間に使う。
    private func updateControls() {
        guard let controls, let player = playerController.player else { return }
        let current = player.currentItem
        controls.apply(VideoControlsView.State(
            isPlaying: player.timeControlStatus != .paused,
            time: PlaybackTime(elapsed: displayedElapsed ?? 0, duration: current?.duration.seconds ?? 0),
            isMuted: player.isMuted,
            hasAudio: hasAudio
        ))
    }

    private func playbackStatusDidChange() {
        applyDynamicRange()
        updateControls()
        scheduleAutoHide()
    }

    /// 止まっていれば再生し、再生していれば止める。最後まで再生し終えていたら、先頭から再生する。
    private func togglePlayback() {
        guard let player = playerController.player else { return }
        guard player.timeControlStatus == .paused else {
            player.pause()
            return
        }
        if let current = player.currentItem, current.duration.isNumeric, current.currentTime() >= current.duration {
            player.seek(to: .zero)
        }
        player.play()
    }

    /// 部品に出す再生位置。シークしている間は、まだ移動前の位置を返すプレイヤーではなく、行き先を出す。
    private var displayedElapsed: Double? {
        pendingSeek ?? playerController.player?.currentItem?.currentTime().seconds
    }

    /// 10秒戻る・進む。続けて押されたときも押した回数だけ動くよう、シークしている間は行き先から数える。
    private func skip(by seconds: Double) {
        guard let player = playerController.player, let current = player.currentItem else { return }
        var target = max((displayedElapsed ?? 0) + seconds, 0)
        let duration = current.duration.seconds
        if duration.isFinite {
            target = min(target, duration)
        }
        seek(player, to: target)
    }

    private func scrub(_ phase: VideoControlsView.ScrubPhase, to progress: Double) {
        guard let player = playerController.player, let current = player.currentItem else { return }
        let duration = current.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        switch phase {
        case .began:
            wasPlayingBeforeScrub = player.timeControlStatus != .paused
            player.pause()
        case .changed:
            seek(player, to: progress * duration)
        case .ended:
            seek(player, to: progress * duration)
            if wasPlayingBeforeScrub {
                player.play()
            }
        }
    }

    /// シークし終えるまでは、部品に行き先を出し続ける。シークを始めた直後のプレイヤーは移動前の位置を返し、
    /// 0.1秒ごとの再生位置の更新がシークバーを一度元へ戻してから行き先へ飛ばしていたため。
    /// 次のシークで取り消された古いシークの完了は無視する。シークバーを離したときは同じ秒数のシークが続けて出るため、秒数ではなく番号で見分ける。
    private func seek(_ player: AVPlayer, to seconds: Double) {
        pendingSeek = seconds
        seekGeneration += 1
        let generation = seekGeneration
        updateControls()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.seekGeneration == generation else { return }
                    self.pendingSeek = nil
                    self.updateControls()
                }
            }
        }
    }

    private func toggleMute() {
        playerController.player?.isMuted.toggle()
        updateControls()
    }

    /// 再生速度を選ぶ項目。選んだ速さは、止めてから再生し直しても続く。
    private func speedMenuElements() -> [UIMenuElement] {
        guard let player = playerController.player else { return [] }
        let actions = AVPlaybackSpeed.systemDefaultSpeeds.map { speed in
            UIAction(title: speed.localizedNumericName, state: speed.rate == player.defaultRate ? .on : .off) { [weak player] _ in
                guard let player else { return }
                player.defaultRate = speed.rate
                // 再生中なら今の速さも変える。止まっていれば、次に再生したときに`defaultRate`で再生される。
                if player.rate != 0 {
                    player.rate = speed.rate
                }
            }
        }
        return [UIMenu(title: "再生速度", options: .displayInline, children: actions)]
    }

    /// 再生している間、最後に触れてから`controlsHideDelay`秒たったら、ビューアに隠すよう頼む。このページでまだ隠していなければ、すぐ頼む。
    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard let controls,
              Self.hidesAutomatically(
                  isPlaying: playerController.player.map { $0.timeControlStatus != .paused } ?? false,
                  isShown: !isChromeHidden && !isEditingDescription,
                  isInteracting: controls.isInteracting,
                  isVoiceOverRunning: UIAccessibility.isVoiceOverRunning
              )
        else { return }
        hideTask = Task { [weak self, clock, delay = hasHiddenChrome ? controlsHideDelay : 0] in
            try? await clock.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.onRequestChromeHidden?(true)
        }
    }

    /// 操作の部品を自動で隠すか。再生していて、部品を出していて、シークバーを動かしたりメニューを開いたりしていないときだけ隠す。
    /// VoiceOverが動いている間は隠さない。画面に出ていない部品は読み上げの対象から外れるため、探している途中で消えると、出し直すところからやり直しになる。
    static func hidesAutomatically(isPlaying: Bool, isShown: Bool, isInteracting: Bool, isVoiceOverRunning: Bool) -> Bool {
        isPlaying && isShown && !isInteracting && !isVoiceOverRunning
    }

    override func setChromeHidden(_ hidden: Bool, animated: Bool) {
        isChromeHidden = hidden
        if hidden {
            hasHiddenChrome = true
        }
        updateControlsVisibility(animated: animated)
    }

    /// 動かしている間やメニューを開いている間に隠す時間が来ていても、ビューアはその頼みを捨てるため、終えたところから数え直す。
    override func interactionDidEnd() {
        scheduleAutoHide()
    }

    override var isEditingDescription: Bool {
        didSet {
            guard isEditingDescription != oldValue else { return }
            updateControlsVisibility(animated: true)
        }
    }

    /// ボタンと説明を隠している間と、代替テキストを書いている間は、操作の部品も隠す。書いている間は、部品が入力欄やキーボードと重なるため。
    private func updateControlsVisibility(animated: Bool) {
        controls?.setControlsHidden(isChromeHidden || isEditingDescription, animated: animated)
        scheduleAutoHide()
    }

    override var bottomCoveredHeight: CGFloat {
        didSet {
            // ボタンと説明を隠したときや、代替テキストを書き始めたときは、説明の高さが0になる。
            // 部品を薄くしている途中でシークバーが下へ動かないよう、部品を隠している間は位置を変えない。
            if !isChromeHidden && !isEditingDescription {
                controls?.coveredBottom = bottomCoveredHeight
            }
        }
    }

    /// 長押ししている間は2倍速で再生し、離したら元の速さと、再生していたかどうかに戻す。
    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard let player = playerController.player else { return }
        switch recognizer.state {
        case .began:
            wasPlayingBeforeFastForward = player.timeControlStatus != .paused
            player.rate = 2
            controls?.setFastForwarding(true)
            UIImpactFeedbackGenerator(style: .light, view: view).impactOccurred()
        case .ended, .cancelled, .failed:
            guard let wasPlaying = wasPlayingBeforeFastForward else { return }
            wasPlayingBeforeFastForward = nil
            if wasPlaying {
                player.rate = player.defaultRate
            } else {
                player.pause()
            }
            controls?.setFastForwarding(false)
        default:
            break
        }
    }

    /// 再生しているコマ。つかんだり閉じたりしたときに、複製を最初のコマ（サムネイル）へ戻さず、その場の絵から動かすために使う。
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

    /// 右上のメニューに出す、ループ再生を切り替える項目。GIFはもとからくり返すため、nilを返す。
    func loopMenuAction() -> UIAction? {
        guard item.kind != .gifv else { return nil }
        return UIAction(title: "ループ再生", image: UIImage(systemName: "repeat"), state: isLooping ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.setLooping(!self.isLooping)
        }
    }

    /// ループ再生を切り替える。入れている間は、最後で止めずに先頭へ戻して再生を続ける。
    func setLooping(_ looping: Bool) {
        isLooping = looping
        playerController.player?.actionAtItemEnd = looping ? .none : .pause
    }

    /// 左右をダブルタップしたら10秒戻る・進み、その側に短く知らせる。真ん中では何もしない。
    /// 隠している操作の部品は出さない。映像だけを見ているときに、一時停止のボタンなどが映像に重なって出ないようにするため。
    /// 部品を出しているときは出したままにし、隠すまでの時間を数え直す。
    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard let seconds = Self.skipSeconds(forDoubleTapAt: recognizer.location(in: view).x, width: view.bounds.width) else { return }
        skip(by: seconds)
        controls?.showSkipEffect(forward: seconds > 0, duration: skipEffectDuration)
        scheduleAutoHide()
    }

    /// ダブルタップした位置で、戻る・進む秒数を決める。左の3分の1で戻り、右の3分の1で進む。真ん中ではnil。
    static func skipSeconds(forDoubleTapAt x: CGFloat, width: CGFloat) -> Double? {
        guard width > 0 else { return nil }
        if x < width / 3 { return -10 }
        if x > width * 2 / 3 { return 10 }
        return nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playerController.player?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playerController.player?.pause()
        hideTask?.cancel()
    }

    override func stateDump() -> String {
        guard let controls else { return "" }
        return "controls: playing=\(controls.state.isPlaying) chromeHidden=\(isChromeHidden) interacting=\(controls.isInteracting) fastForward=\(wasPlayingBeforeFastForward != nil)"
    }
}

extension PlayerPageController: UIGestureRecognizerDelegate {
    /// 操作の部品の上のタッチは、部品に任せ、動画のタップや長押しにしない。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let controls, let touched = touch.view else { return true }
        return !touched.isDescendant(of: controls)
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
/// 添付ファイルの説明を、画像を覆わないよう1行で見せる。全文は、タップするか上へスワイプするかVoiceOverで実行して、シートで読む。
final class CaptionView: UIView {
    private let label = UILabel()
    private let settings: AppSettings
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
        if isPlaceholder {
            label.text = "代替テキストを追加"
        } else {
            // 人が書いた代替テキストは言語が分からないため、設定の字形で描く。書き始めを促す文言は、ウィンドウに付けたアプリの言語で描く。
            label.attributedText = NSAttributedString(string: text, attributes: [.languageIdentifier: settings.glyphLanguageIdentifier()])
        }
        label.textColor = isPlaceholder ? UIColor.white.withAlphaComponent(0.6) : .white
        accessibilityLabel = isPlaceholder ? "代替テキストを追加" : text
        accessibilityHint = isEditable ? "代替テキストを編集します。" : "全文を表示します。"
    }

    /// 文字の下端。安全領域に合わせるために使う。
    var contentBottomAnchor: NSLayoutYAxisAnchor { contentGuide.bottomAnchor }

    init(settings: AppSettings = AppDependencies.settings) {
        self.settings = settings
        super.init(frame: .zero)
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
            videoControlsHideDelay: tuning.value(of: TuningCatalog.mediaVideoControlsHideDelay),
            videoSkipEffectDuration: tuning.value(of: TuningCatalog.mediaVideoSkipEffectDuration),
            doubleTapZoomDuration: tuning.value(of: TuningCatalog.mediaDoubleTapZoomDuration)
        )
    }
}

extension MediaViewerController: NoticeScreen {
    /// メニューボタンと枚数の表示の行のすぐ下に置く。保存を選ぶメニューの近くで知らせるため。
    /// 開く途中と閉じる途中は、開いている度合いに合わせて、下の画面の位置とのあいだに置く。
    func noticePlacement(below: CGFloat) -> NoticePlacement {
        let own = menuButton.convert(CGPoint(x: 0, y: menuButton.bounds.maxY + 8), to: nil).y
        return NoticePlacement(
            top: below + (own - below) * noticePresence,
            viewer: NoticeContext.Viewer(currentURL: currentTransferURL),
            screenNotice: draftNotice,
            screenAlpha: noticeScreenAlpha,
            hidesChrome: isChromeHidden
        )
    }
}

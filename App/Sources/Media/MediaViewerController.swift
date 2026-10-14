import AVKit
import os
import SciaCore
import UIKit

/// 投稿の添付ファイルを全画面で見る。左右のスワイプで切り替え、画像はピンチとダブルタップで拡大する。
///
/// 開くときと閉じるときの動きは、一覧のサムネイルを起点にするUIKit標準のズームの遷移に任せる。
/// 下へのスワイプで閉じる操作は、標準のものが指を大きく動かさないと閉じず、画像の形で感度も変わるため、自前のパンで持つ。
/// 指に合わせて画像を動かして縮め、閉じると決めたら、その位置からズームの遷移でサムネイルへ縮める。
/// 画像を隠さないよう閉じるボタンは置かず、VoiceOverのエスケープとキーボードのEscでも閉じられるようにする。
final class MediaViewerController: UIViewController {
    private let attachments: [MediaAttachment]
    private let store: MediaImageStore
    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private var pages: [Int: MediaPageController] = [:]
    private(set) var currentIndex: Int
    /// 添付ファイルへの操作をまとめたメニューを出す。
    private let menuButton = UIButton(configuration: .glass())
    private let counterLabel = UILabel()
    private let captionView = CaptionView()
    private var isChromeHidden = false
    private let dragToDismiss: DragToDismiss
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    /// 閉じる操作を始めたときに押していた位置。`view`の座標。画像をこの点を中心に縮め、指の下に同じ場所が来るようにする。
    private var dismissPanAnchor: CGPoint = .zero
    /// 閉じ終わったときに呼ぶ。
    var onDismiss: (() -> Void)?
    /// 黒い下地。ズームの遷移はビューアの画面全体を縮めるため、下地を画面に含めるとサムネイルへ縮んで見える。
    /// 画面の外、表示の入れ物に敷き、開閉ではその場で濃くしたり薄くしたりする。
    private let backdrop = UIView()

    init(attachments: [MediaAttachment], startIndex: Int, store: MediaImageStore, dragToDismiss: DragToDismiss) {
        precondition(attachments.indices.contains(startIndex), "開く添付ファイルの位置が範囲外です")
        self.attachments = attachments
        self.store = store
        self.dragToDismiss = dragToDismiss
        currentIndex = startIndex
        super.init(nibName: nil, bundle: nil)
        // 閉じる操作の間に背景を薄くして一覧を透かすため、開いている間も一覧を残す。
        modalPresentationStyle = .overFullScreen
        // 全画面でない表示では、状態バーの表示を自分で決めると宣言しないと、画像だけにしたときに隠せない。
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentAttachment: MediaAttachment { attachments[currentIndex] }

    /// 拡大して見ている間は、下へのスワイプを画像の移動に使い、閉じる操作にしない。
    var allowsInteractiveDismiss: Bool {
        pages[currentIndex]?.allowsInteractiveDismiss ?? true
    }

    /// 開閉の動きの終点にする、表示中の添付ファイルの枠。`view`の座標で返す。
    func contentFrame(in view: UIView) -> CGRect {
        guard let page = pages[currentIndex] else { return view.bounds }
        return page.view.convert(page.contentFrame, to: view)
    }

    override var prefersStatusBarHidden: Bool { isChromeHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { isChromeHidden }

    /// キーボードのEscを受けるため、表示されたら最初の応答者になる。
    override var canBecomeFirstResponder: Bool { true }

    /// 画面が入れ物に入ってから呼ばれるため、ここで画面のすぐ下に下地を敷く。
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard isBeingPresented, let container = view.superview else { return }
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.insertSubview(backdrop, belowSubview: view)
        fadeBackdrop(to: 1)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed {
            fadeBackdrop(to: 0)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            backdrop.removeFromSuperview()
            onDismiss?()
        }
    }

    /// 開閉の遷移に合わせて下地の濃さを変える。取り消されたら元に戻す。
    private func fadeBackdrop(to alpha: CGFloat) {
        guard let coordinator = transitionCoordinator else {
            backdrop.alpha = alpha
            return
        }
        let original = backdrop.alpha
        coordinator.animate(alongsideTransition: { _ in
            self.backdrop.alpha = alpha
        }, completion: { context in
            if context.isCancelled {
                self.backdrop.alpha = original
            }
        })
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "閉じる", action: #selector(close), input: UIKeyCommand.inputEscape)]
    }

    /// VoiceOverの2本指のZで閉じる。
    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.backgroundColor = .black
        backdrop.alpha = 0
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
        setUpChrome()
        updateChrome()
        dismissPan.delegate = self
        // ピンチの2本指を閉じる操作と取り違えないようにする。
        dismissPan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(dismissPan)
    }

    private func setUpChrome() {
        menuButton.configuration?.image = UIImage(systemName: "ellipsis")
        menuButton.accessibilityLabel = "その他の操作"
        // 開くたびに、表示中の添付ファイルに合わせて項目を作り直す。
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuElements() ?? [])
        }])
        menuButton.showsMenuAsPrimaryAction = true
        counterLabel.font = .preferredFont(forTextStyle: .subheadline)
        counterLabel.textColor = .white
        counterLabel.isHidden = attachments.count == 1
        for view in [menuButton, counterLabel, captionView] {
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
        ])
    }

    private var chromeViews: [UIView] { [menuButton, counterLabel, captionView] }

    private func updateChrome() {
        counterLabel.text = "\(currentIndex + 1) / \(attachments.count)"
        let description = currentAttachment.description ?? ""
        captionView.text = description
        captionView.isHidden = isChromeHidden || description.isEmpty
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
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func page(at index: Int) -> MediaPageController {
        if let page = pages[index] { return page }
        let attachment = attachments[index]
        let page: MediaPageController = switch attachment.type {
        case .image: ImagePageController(attachment: attachment, store: store)
        case .video, .gifv, .audio: PlayerPageController(attachment: attachment)
        case .unknown: UnsupportedPageController(attachment: attachment)
        }
        page.index = index
        page.onSingleTap = { [weak self] in self?.toggleChrome() }
        pages[index] = page
        return page
    }

    private func shareItem() -> Any? {
        if let image = (pages[currentIndex] as? ImagePageController)?.fullImage {
            return image
        }
        return currentAttachment.url ?? currentAttachment.remoteUrl
    }

    /// メニューの項目。共有できるものがなければ、共有を選べなくする。
    func menuElements() -> [UIMenuElement] {
        let share = UIAction(
            title: "共有",
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: shareItem() == nil ? .disabled : []
        ) { [weak self] _ in
            self?.share()
        }
        return [share]
    }

    private func share() {
        guard let item = shareItem() else { return }
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        // 添付ファイルの画像を連絡先の写真にすることはまずないため、出さない。
        activity.excludedActivityTypes = [.assignToContact]
        activity.popoverPresentationController?.sourceItem = menuButton
        present(activity, animated: true)
    }
}

extension MediaViewerController: UIGestureRecognizerDelegate {
    /// 拡大していない画像を、下へ向けて動かし始めたときだけ閉じる操作にする。横は左右の切り替えに、上は何もしないまま残す。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        let velocity = dismissPan.velocity(in: view)
        return allowsInteractiveDismiss && velocity.y > 0 && velocity.y > abs(velocity.x)
    }

    @objc fileprivate func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        guard let page = pages[currentIndex] else { return }
        let height = view.bounds.height
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .began:
            dismissPanAnchor = recognizer.location(in: view)
            pageController.view.isUserInteractionEnabled = false
        case .changed:
            page.view.transform = dragTransform(for: page, translation: translation)
            let backgroundAlpha = dragToDismiss.backgroundAlpha(translation: translation.y, height: height)
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
                dismiss(animated: true)
            } else {
                restoreFromDrag(page: page)
            }
        case .cancelled, .failed:
            pageController.view.isUserInteractionEnabled = true
            restoreFromDrag(page: page)
        default:
            break
        }
    }

    /// 押した位置を中心に縮め、指の動きに合わせて動かす。
    private func dragTransform(for page: MediaPageController, translation: CGPoint) -> CGAffineTransform {
        let scale = dragToDismiss.scale(translation: translation.y, height: view.bounds.height)
        // 変形の影響を受けない、元の位置での中心。
        let center = page.view.superview?.convert(page.view.center, to: view) ?? view.center
        let offset = CGPoint(
            x: translation.x + (1 - scale) * (dismissPanAnchor.x - center.x),
            y: translation.y + (1 - scale) * (dismissPanAnchor.y - center.y)
        )
        return CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
    }

    private func restoreFromDrag(page: MediaPageController) {
        UIView.animate(springDuration: dragToDismiss.restoreDuration, bounce: 0) {
            page.view.transform = .identity
            backdrop.alpha = 1
            for chrome in chromeViews {
                chrome.alpha = isChromeHidden ? 0 : 1
            }
        }
    }
}

extension MediaViewerController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? MediaPageController)?.index, index > 0 else { return nil }
        return page(at: index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? MediaPageController)?.index, index < attachments.count - 1 else { return nil }
        return page(at: index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = pageViewController.viewControllers?.first as? MediaPageController else { return }
        currentIndex = page.index
        captionView.scrollToTop()
        updateChrome()
    }
}

extension MediaViewerController {
    /// 一覧のサムネイルからビューアを開く。`sourceView`は、表示中の添付ファイルのサムネイルを返す。
    /// 閉じる前に一覧のセルが再利用されるなどして見つからなければnilを返し、UIKitに標準の閉じ方を任せる。
    static func present(
        attachments: [MediaAttachment],
        startIndex: Int,
        store: MediaImageStore,
        dragToDismiss: DragToDismiss,
        from presenter: UIViewController,
        sourceView: @escaping @MainActor (MediaAttachment.ID) -> UIView?,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        let viewer = MediaViewerController(attachments: attachments, startIndex: startIndex, store: store, dragToDismiss: dragToDismiss)
        viewer.onDismiss = onDismiss
        let options = UIViewController.Transition.ZoomOptions()
        // 下へのスワイプで閉じる操作は自前のパンで持つため、標準のものは使わない。
        options.interactiveDismissShouldBegin = { _ in false }
        options.alignmentRectProvider = { [weak viewer] context in
            guard let viewer else { return .null }
            return viewer.contentFrame(in: context.zoomedViewController.view)
        }
        viewer.preferredTransition = .zoom(options: options) { [weak viewer] _ in
            guard let viewer else { return nil }
            return sourceView(viewer.currentAttachment.id)
        }
        presenter.present(viewer, animated: true)
    }
}

/// ビューアの1ページ。
class MediaPageController: UIViewController {
    let attachment: MediaAttachment
    var index = 0
    var onSingleTap: (() -> Void)?

    init(attachment: MediaAttachment) {
        self.attachment = attachment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var allowsInteractiveDismiss: Bool { true }

    /// 添付ファイルを描いている枠。`view`の座標。
    var contentFrame: CGRect { view.bounds }
}

/// 画像のページ。一覧のサムネイルをすぐに出し、元の大きさの画像が届いたら差し替える。
final class ImagePageController: MediaPageController {
    private let store: MediaImageStore
    private let zoomView = ZoomingImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private(set) var fullImage: UIImage?

    init(attachment: MediaAttachment, store: MediaImageStore) {
        self.store = store
        super.init(attachment: attachment)
    }

    deinit {
        loadTask?.cancel()
    }

    override var allowsInteractiveDismiss: Bool { !zoomView.isZoomedIn }

    override var contentFrame: CGRect {
        zoomView.imageFrame.map { zoomView.convert($0, to: view) } ?? view.bounds
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        zoomView.frame = view.bounds
        zoomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomView.onSingleTap = { [weak self] in self?.onSingleTap?() }
        zoomView.imageAccessibilityLabel = attachment.description
        view.addSubview(zoomView)
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
        let preview = attachment.previewUrl.flatMap { store.cachedImage(for: $0, maxPixelSize: MediaImageStore.thumbnailPixelSize) }
        zoomView.image = preview ?? attachment.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: attachment.aspectRatio) }
        load(hasPreview: preview != nil)
    }

    /// - Parameter hasPreview: 中身の分かるサムネイルを出せている。blurhashのぼかしだけなら、読み込み中と失敗を知らせる。
    private func load(hasPreview: Bool) {
        guard let url = attachment.url ?? attachment.remoteUrl ?? attachment.previewUrl else {
            failureLabel.isHidden = hasPreview
            return
        }
        if !hasPreview {
            spinner.startAnimating()
        }
        loadTask = Task { [weak self, store] in
            let image = try? await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize)
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image {
                self.fullImage = image
                self.zoomView.image = image
            } else {
                // サムネイルを出せていれば、そのまま見せる。
                self.failureLabel.isHidden = hasPreview
            }
        }
    }
}

/// 動画、GIF、音声のページ。GIFはループして音を出さず、操作の部品も出さない。
final class PlayerPageController: MediaPageController {
    private let playerController = AVPlayerViewController()
    private var looper: AVPlayerLooper?

    override var contentFrame: CGRect {
        let videoBounds = playerController.videoBounds
        guard !videoBounds.isEmpty else { return view.bounds }
        return playerController.view.convert(videoBounds, to: view)
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
        guard let url = attachment.url ?? attachment.remoteUrl else { return }
        let item = AVPlayerItem(url: url)
        if attachment.type == .gifv {
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerController.player = player
            playerController.showsPlaybackControls = false
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            playerController.view.addGestureRecognizer(tap)
        } else {
            playerController.player = AVPlayer(playerItem: item)
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
        if let url = attachment.remoteUrl ?? attachment.url {
            configuration.button = .bordered()
            configuration.button.title = "ブラウザで開く"
            configuration.buttonProperties.primaryAction = UIAction { _ in UIApplication.shared.open(url) }
        }
        contentUnavailableConfiguration = configuration
    }
}

/// 画面の下に出す代替テキスト。長ければスクロールして読む。
private final class CaptionView: UIView {
    private let scrollView = UIScrollView()
    private let label = UILabel()
    private let contentGuide = UILayoutGuide()

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    /// 別の添付ファイルの説明に変わったときに、前の説明を読んでいた位置を引き継がないようにする。
    func scrollToTop() {
        scrollView.contentOffset = .zero
    }

    /// 文字の下端。安全領域に合わせるために使う。
    var contentBottomAnchor: NSLayoutYAxisAnchor { contentGuide.bottomAnchor }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        addLayoutGuide(contentGuide)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(label)
        // 長い説明でも画像を覆いすぎないよう、高さに上限を置く。
        let fitsContent = scrollView.heightAnchor.constraint(equalTo: label.heightAnchor)
        fitsContent.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),
            contentGuide.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 120),
            fitsContent,
            label.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            label.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

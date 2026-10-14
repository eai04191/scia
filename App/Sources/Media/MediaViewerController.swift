import AVKit
import SciaCore
import UIKit

/// 投稿の添付ファイルを全画面で見る。左右のスワイプで切り替え、画像はピンチとダブルタップで拡大する。
///
/// 開くときと閉じるときの動きは、一覧のサムネイルを起点にするUIKit標準のズームの遷移に任せる。下へのスワイプで閉じる操作もこの遷移が持つ。
final class MediaViewerController: UIViewController {
    private let attachments: [MediaAttachment]
    private let store: MediaImageStore
    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
    private var pages: [Int: MediaPageController] = [:]
    private(set) var currentIndex: Int
    private let closeButton = UIButton(configuration: .glass())
    private let shareButton = UIButton(configuration: .glass())
    private let counterLabel = UILabel()
    private let captionView = CaptionView()
    private var isChromeHidden = false

    init(attachments: [MediaAttachment], startIndex: Int, store: MediaImageStore) {
        precondition(attachments.indices.contains(startIndex), "開く添付ファイルの位置が範囲外です")
        self.attachments = attachments
        self.store = store
        currentIndex = startIndex
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
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
    }

    private func setUpChrome() {
        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.accessibilityLabel = "閉じる"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        shareButton.configuration?.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.accessibilityLabel = "共有"
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .primaryActionTriggered)
        counterLabel.font = .preferredFont(forTextStyle: .subheadline)
        counterLabel.textColor = .white
        counterLabel.isHidden = attachments.count == 1
        for view in [closeButton, shareButton, counterLabel, captionView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            shareButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
            shareButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            counterLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            counterLabel.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            captionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            captionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            captionView.contentBottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
        ])
    }

    private func updateChrome() {
        counterLabel.text = "\(currentIndex + 1) / \(attachments.count)"
        let description = currentAttachment.description ?? ""
        captionView.text = description
        captionView.isHidden = isChromeHidden || description.isEmpty
        shareButton.isEnabled = shareItem() != nil
    }

    /// 画像を1回タップしたら、ボタンと説明を隠して画像だけにする。もう1回で戻す。
    fileprivate func toggleChrome() {
        isChromeHidden.toggle()
        UIView.animate(withDuration: 0.2) {
            for view in [self.closeButton, self.shareButton, self.counterLabel] {
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

    private func share() {
        guard let item = shareItem() else { return }
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        activity.popoverPresentationController?.sourceItem = shareButton
        present(activity, animated: true)
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
        from presenter: UIViewController,
        sourceView: @escaping @MainActor (MediaAttachment.ID) -> UIView?
    ) {
        let viewer = MediaViewerController(attachments: attachments, startIndex: startIndex, store: store)
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak viewer] _ in viewer?.allowsInteractiveDismiss ?? true }
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
        if let preview = attachment.previewUrl.flatMap({ store.cachedImage(for: $0, maxPixelSize: MediaImageStore.thumbnailPixelSize) }) {
            zoomView.image = preview
        }
        load()
    }

    private func load() {
        guard let url = attachment.url ?? attachment.remoteUrl ?? attachment.previewUrl else {
            failureLabel.isHidden = zoomView.image != nil
            return
        }
        if zoomView.image == nil {
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
                self.failureLabel.isHidden = self.zoomView.image != nil
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
        playerController.view.backgroundColor = .black
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

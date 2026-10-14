import AVKit
import os
import SciaCore
import UIKit

/// 投稿の添付ファイルを全画面で見る。左右のスワイプで切り替え、画像はピンチとダブルタップで拡大する。
///
/// 開くとき、閉じるとき、下へのスワイプで閉じる操作の間は、画像の写しを一覧のサムネイルとのあいだで動かす。
///
/// UIKitの遷移（標準のズームや、遷移を自前で描く仕組み）は使わない。標準のズームは画面全体に角丸と影を付けて変形するため画面の形の枠が見え、
/// 遷移を自前で描く仕組みは動いている間の操作を受け付けないため、開く途中で下へ払っても閉じられない。
/// ビューアはアニメーションなしで出し入れし、動きはビューアの中で描く。開く途中で指が触れたら、動きをその場で止めて指に追従させる。
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
    /// 黒い下地。画像だけを動かし、下地はその場で濃くしたり薄くしたりする。
    private let backdrop = UIView()
    /// 開閉とドラッグで動かす画像の写し。縦横比を保って枠を埋めるように切り抜くため、枠の形をサムネイルとビューアの画像のあいだで変えるだけで、
    /// サムネイルと同じ切り抜き方へ移る。
    private let morph = UIImageView()
    /// 写しに載せる、サムネイルの印（ALT、GIF、残りの枚数）の写し。サムネイルに近いほど濃くし、ビューアの画像の大きさでは見せない。
    private var morphDecoration: UIView?
    /// 写しの画像を、ページが描いている画像に合わせ続けるか。元の画像が届いたら、動いている途中でも差し替える。
    private var morphFollowsPage = false
    private var motion = Motion.idle
    private let timing: Timing
    private let sourceTile: @MainActor (MediaAttachment.ID) -> MediaTileView?
    /// 写しを動かしている間、隠している一覧のサムネイル。画像がそこへ戻っていく途中で消えて見えないよう、動かし始めから隠す。
    private var hiddenTile: MediaTileView?

    struct Timing {
        /// サムネイルから広げて、ビューアで表示し終えるまでの時間。
        let openDuration: TimeInterval
        /// サムネイルへ縮めて戻すまでの時間。
        let closeDuration: TimeInterval
        /// 0で弾まずに止まり、大きいほど行き過ぎてから戻る。
        let bounce: CGFloat
        /// 閉じるとき、戻る画像のうちバーにかかる部分を、一覧の中に置いた写しでバーの奥に描く。
        let drawsUnderBars: Bool
        /// バーの奥にも描くとき、最前面の写しを一覧の中の写しへ受け渡し始める進み具合。0から1。
        let handoffStart: Double
        /// バーの奥にも描くとき、閉じ始めにバーと重なっていた部分を一覧の中の写しへ入れ替え終える進み具合。0から1。
        let barOverlapFadeEnd: Double
    }

    /// - Parameter sourceTile: 添付ファイルのサムネイルを返す。開閉のたびに呼ぶため、閉じるまでに一覧の行が再利用されても今の位置を返せる。
    ///   見つからなければnilを返し、画像を動かさずに薄くして開閉する。
    init(
        attachments: [MediaAttachment],
        startIndex: Int,
        store: MediaImageStore,
        dragToDismiss: DragToDismiss,
        timing: Timing,
        sourceTile: @escaping @MainActor (MediaAttachment.ID) -> MediaTileView?
    ) {
        precondition(attachments.indices.contains(startIndex), "開く添付ファイルの位置が範囲外です")
        self.attachments = attachments
        self.store = store
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
        becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
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

    /// 写しをサムネイルへ縮めてから閉じる。
    @objc func close() {
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
        dismissPan.delegate = self
        // ピンチの2本指を閉じる操作と取り違えないようにする。
        dismissPan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(dismissPan)
        AppDependencies.stateDumps.register("mediaViewer", owner: self) { $0.stateDump() }
    }

    func stateDump() -> String {
        let page = pages[currentIndex]
        return """
        motion: \(motion.label)
        index: \(currentIndex) / \(attachments.count) type=\(currentAttachment.type)
        aspectRatio: \(currentAttachment.aspectRatio.map { "\($0)" } ?? "nil")
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
        page.onImageChange = { [weak self, weak page] in
            guard let self, let page, self.morphFollowsPage, page.index == self.currentIndex, let image = page.transitionImage else { return }
            self.morph.image = image
        }
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
    /// 開いている途中や、閉じずに戻している途中でも受け付け、その場からつかみ直せるようにする。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        if case .closing = motion { return false }
        let velocity = dismissPan.velocity(in: view)
        return allowsInteractiveDismiss && velocity.y > 0 && velocity.y > abs(velocity.x)
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
                beginClosing()
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
        case opening(UIViewPropertyAnimator)
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
        for chrome in chromeViews {
            chrome.alpha = isChromeHidden ? 0 : visibility
        }
    }

    private var currentTile: MediaTileView? {
        sourceTile(currentAttachment.id)
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
        morphDecoration = tile.map { tile in
            let decoration = tile.makeDecorationCopy()
            decoration.frame = morph.bounds
            decoration.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            decoration.alpha = alpha
            morph.addSubview(decoration)
            return decoration
        }
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
        case .opening(let animator), .settling(let animator):
            animator.stopAnimation(true)
            setVisibility(1)
            finishOpen()
        case .idle, .dragging, .closing:
            break
        }
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

    private func beginOpening() {
        view.layoutIfNeeded()
        let animator = makeAnimator(duration: timing.openDuration, bounce: timing.bounce)
        if movesImage, let tile = currentTile {
            showMorph(frame: tileFrame(of: tile), cornerRadius: tile.layer.cornerRadius, tile: tile, decorationAlpha: 1)
            let target = contentFrame(in: view)
            animator.addAnimations {
                self.morph.frame = target
                self.morph.layer.cornerRadius = 0
                self.morphDecoration?.alpha = 0
            }
        } else {
            pageController.view.alpha = 0
            animator.addAnimations { self.pageController.view.alpha = 1 }
        }
        setVisibility(0)
        animator.addAnimations { self.setVisibility(1) }
        animator.addCompletion { [weak self] position in
            guard position == .end else { return }
            self?.finishOpen()
        }
        motion = .opening(animator)
        animator.startAnimation()
    }

    /// 開ききったら、写しを隠してページの画像に戻す。隠していたサムネイルも、黒い下地で覆われているので戻す。
    private func finishOpen() {
        hideMorph()
        showHiddenTile()
        motion = .idle
    }

    /// 開いている途中や戻している途中なら、その場で止めてつかむ。開ききっていれば、ビューアの画像の位置に写しを出してつかむ。
    private func beginDragging(at location: CGPoint) {
        switch motion {
        case .opening(let animator), .settling(let animator):
            // 止めた時点の見た目のまま残す。
            animator.stopAnimation(true)
            if morph.isHidden {
                // 薄くして開いていた途中なら、ここから写しを出す。
                showMorph(frame: contentFrame(in: view), cornerRadius: 0, tile: currentTile, decorationAlpha: 0)
            } else {
                hide(currentTile)
            }
        case .idle:
            showMorph(frame: contentFrame(in: view), cornerRadius: 0, tile: currentTile, decorationAlpha: 0)
        case .dragging, .closing:
            return
        }
        dismissPanAnchor = location
        pageController.view.isUserInteractionEnabled = false
        motion = .dragging(start: morph.frame, visibility: backdrop.alpha)
    }

    /// 閉じずに離したら、写しをビューアの画像の枠へ戻し、開ききった状態にする。
    private func settle() {
        guard case .dragging = motion else { return }
        let animator = makeAnimator(duration: dragToDismiss.restoreDuration, bounce: 0)
        let target = contentFrame(in: view)
        animator.addAnimations {
            self.morph.frame = target
            self.morph.layer.cornerRadius = 0
            self.morphDecoration?.alpha = 0
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
    private func beginClosing() {
        switch motion {
        case .closing:
            return
        case .opening(let animator), .settling(let animator):
            animator.stopAnimation(true)
        case .idle, .dragging:
            break
        }
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
        // サムネイルは写しが戻り終えてから見せるため、ビューアを閉じたときには戻さない。
        let closingTile = hiddenTile
        hiddenTile = nil
        dismiss(animated: false)

        let attachmentID = currentAttachment.id
        let sourceTile = sourceTile
        let moves = movesImage && tile != nil
        let flight = MediaClosingFlight(
            parts: MediaClosingFlight.Parts(
                overlay: overlay,
                morph: morph,
                decoration: morphDecoration,
                fadingViews: [backdrop] + chromeSnapshots,
                underlay: moves && timing.drawsUnderBars ? makeUnderlay(decoratedLike: tile) : nil
            ),
            window: window,
            spring: SpringCurve(duration: timing.closeDuration, bounce: timing.bounce),
            handoffStart: CGFloat(timing.handoffStart),
            barOverlapFadeEnd: CGFloat(timing.barOverlapFadeEnd),
            // 戻り先が最初から見つからなければ、その場で薄くする。
            movesImage: moves,
            concealedTile: closingTile,
            findTile: { sourceTile(attachmentID) }
        )
        flight.start()
    }

    /// バーの奥に描く写し。写しと同じ画像と切り抜き方で、サムネイルの印も載せる。
    private func makeUnderlay(decoratedLike tile: MediaTileView?) -> MediaClosingFlight.Underlay {
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
        return MediaClosingFlight.Underlay(image: image, decoration: decoration)
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

    /// 開いている途中に左右へ切り替え始めたら、開く動きを終えて切り替えを優先する。
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        completeMotionImmediately()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = pageViewController.viewControllers?.first as? MediaPageController else { return }
        currentIndex = page.index
        captionView.scrollToTop()
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
    let attachment: MediaAttachment
    var index = 0
    var onSingleTap: (() -> Void)?
    /// 描いている画像が変わった。開閉の写しを、元の画像が届いた時点で差し替えるために使う。
    var onImageChange: (() -> Void)?

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

    /// 開閉で動かす、描いている画像。
    var transitionImage: UIImage? { nil }

    /// 画像を描くページ。開閉の写しを、このページの画像の更新に合わせて差し替える。
    var drawsImage: Bool { false }

    /// 違和感レポートに残す、ページの状態。
    func stateDump() -> String { "" }
}

/// 画像のページ。一覧のサムネイルをすぐに出し、元の大きさの画像が届いたら差し替える。
final class ImagePageController: MediaPageController {
    private let store: MediaImageStore
    private let zoomView = ZoomingImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private(set) var fullImage: UIImage?
    /// 出している画像の出どころ。違和感レポートに残す。
    private var imageSource = "none"

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
        let placeholder = preview == nil ? attachment.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: attachment.aspectRatio) } : nil
        imageSource = preview != nil ? "thumbnail" : placeholder != nil ? "blurhash" : "none"
        zoomView.image = preview ?? placeholder
        onImageChange?()
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
                self.imageSource = "full"
                self.zoomView.image = image
                self.onImageChange?()
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

    /// 動画の表示の準備が整うまでは、添付ファイルの縦横比で画面に収めた枠を返す。開く遷移はその準備より先に始まるため。
    override var contentFrame: CGRect {
        let videoBounds = playerController.videoBounds
        if !videoBounds.isEmpty {
            return playerController.view.convert(videoBounds, to: view)
        }
        guard let aspectRatio = attachment.aspectRatio, aspectRatio > 0 else { return view.bounds }
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

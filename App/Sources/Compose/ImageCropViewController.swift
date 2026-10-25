import os
import SciaCore
import UIKit

/// 投稿欄で添付した画像を切り抜く画面。ビューアの上に重ねて出す。決まりはdocs/media-attachment.mdの「トリミング」にある。
///
/// 写真アプリと同じく、画面に置いた枠の下で画像を動かし、枠の中に画像の端が入らないようにする。スクロールビューの`contentInset`を
/// 枠の外の幅にし、縮められる倍率を枠を覆う倍率にすれば、UIKitのスクロールとズームのまま、画像の端が枠に入る手前で止まる。
/// 枠のハンドルを離すと、少し待ってから、枠を画面の中央いっぱいへ広げ、同じ範囲が枠に収まるよう画像を拡大する。
final class ImageCropViewController: UIViewController {
    /// 縦横比の選び方。
    enum Aspect: Equatable {
        case free
        /// 回したあとの画像の比率。
        case original
        case ratio(width: CGFloat, height: CGFloat)

        static let choices: [(title: String, aspect: Aspect)] = [
            ("自由", .free),
            ("元の比率", .original),
            ("1:1", .ratio(width: 1, height: 1)),
            ("4:3", .ratio(width: 4, height: 3)),
            ("3:4", .ratio(width: 3, height: 4)),
            ("16:9", .ratio(width: 16, height: 9)),
            ("9:16", .ratio(width: 9, height: 16)),
        ]

        /// 90度回したときの比率。決めた比率は縦と横を入れ替える。
        var rotated: Aspect {
            guard case .ratio(let width, let height) = self else { return self }
            return .ratio(width: height, height: width)
        }
    }

    /// 「完了」を押した。切り抜かないならnil。プレビューは、切り抜いた範囲を表示用の画像から描いたもの。
    var onFinish: ((_ crop: ImageCrop?, _ preview: UIImage?) -> Void)?

    private let file: LocalMediaFile
    /// 向きを反映した元の大きさ。全体を残すかを画素で決めるのに使う。
    private let originalSize: PixelSize
    private let tuning: TuningStore
    private let clock: any Clock<Duration>
    /// 表示のために縮めて読んだ、回す前の画像。読み込むまでnil。
    private var baseImage: UIImage?
    private var quarterTurns: Int
    /// 回したあとの画像のうち、残す範囲。画像を読み込むまでと、並べ直すときの基準に使う。
    private var pendingRect: CGRect
    private var aspect: Aspect = .free

    /// 画像と枠をまとめて回すためのビュー。回したあとの並びに、回す前の見た目へ戻す変形をかけ、変形なしへ動かす。
    private let canvas = UIView()
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let overlay = CropOverlayView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let cancelButton = UIButton(configuration: .glass())
    private let doneButton = UIButton(configuration: .prominentGlass())
    private let rotateButton = UIButton(configuration: .glass())
    private let aspectButton = UIButton(configuration: .glass())
    private let resetButton = UIButton(configuration: .glass())
    /// 枠。`view`の座標。
    private var box: CGRect = .zero
    private var activeHandle: CropHandle?
    /// 枠のハンドルに触れた瞬間の位置。`overlay`の座標。回している途中なら、回し終える前の見た目での位置。
    private var touchDownLocation: CGPoint = .zero
    private var dragStartBox: CGRect = .zero
    private var recenterTask: Task<Void, Never>?
    /// 回している途中の動き。回していなければnil。
    private var rotation: RotationState?
    private var rotationTicker: FrameTicker?
    private let frameSource: any FrameSource
    /// 枠を中央へ戻す動きか、縦横比を変える動きの途中。
    private var isRecentering = false
    /// 枠を動かした回数。前の動きの完了を見分ける。
    private var recenterGeneration = 0
    /// 最後に並べた大きさ。画面を回して大きさが変わったら、同じ範囲で並べ直す。
    private var laidOutSize: CGSize = .zero

    /// - Parameters:
    ///   - originalSize: 向きを反映した元の大きさ。
    ///   - crop: 前に選んだ範囲。切り抜いていなければnil。
    init(
        file: LocalMediaFile,
        originalSize: PixelSize,
        crop: ImageCrop?,
        tuning: TuningStore = AppDependencies.tuning,
        clock: any Clock<Duration> = AppDependencies.clock,
        frameSource: any FrameSource = DisplayLinkFrameSource.shared
    ) {
        self.file = file
        self.frameSource = frameSource
        self.originalSize = originalSize
        self.tuning = tuning
        self.clock = clock
        quarterTurns = crop?.quarterTurns ?? 0
        pendingRect = crop?.rect ?? ImageCrop.unitRect
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        recenterTask?.cancel()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "キャンセル", action: #selector(cancel), input: UIKeyCommand.inputEscape),
            UIKeyCommand(title: "完了", action: #selector(finish), input: "\r"),
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.addSubview(imageView)
        canvas.addSubview(scrollView)
        // 触れた瞬間の位置を覚え、回している途中なら回し終える。枠のハンドルも画像も、キャンバスの中で触れるので、ここで1か所で受ける。
        let touchDown = TouchDownObserver { [weak self] touch in
            guard let self else { return }
            self.touchDownLocation = touch.location(in: self.overlay)
            self.finishRotation()
        }
        canvas.addGestureRecognizer(touchDown)
        view.addSubview(canvas)
        overlay.isHidden = true
        overlay.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:))))
        canvas.addSubview(overlay)
        spinner.color = .white
        spinner.startAnimating()
        view.addSubview(spinner)

        configure(cancelButton, title: "キャンセル", action: #selector(cancel))
        configure(doneButton, title: "完了", action: #selector(finish))
        configure(rotateButton, symbol: "rotate.left", label: "回転", action: #selector(rotate))
        configure(resetButton, title: "リセット", action: #selector(reset))
        configure(aspectButton, symbol: "aspectratio", label: "縦横比", action: nil)
        aspectButton.showsMenuAsPrimaryAction = true
        updateAspectMenu()
        setControlsEnabled(false)
        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 回している途中は変形をかけているので、frameではなくboundsとcenterで置く。
        canvas.bounds = view.bounds
        canvas.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        scrollView.frame = canvas.bounds
        overlay.frame = canvas.bounds
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let topY = safe.minY + 8
        cancelButton.sizeToFit()
        doneButton.sizeToFit()
        cancelButton.frame = CGRect(x: safe.minX + 16, y: topY, width: cancelButton.bounds.width, height: Self.buttonHeight)
        doneButton.frame = CGRect(x: safe.maxX - 16 - doneButton.bounds.width, y: topY, width: doneButton.bounds.width, height: Self.buttonHeight)
        let bottomY = safe.maxY - 8 - Self.buttonHeight
        rotateButton.frame = CGRect(x: safe.minX + 16, y: bottomY, width: Self.buttonHeight, height: Self.buttonHeight)
        aspectButton.frame = CGRect(x: safe.maxX - 16 - Self.buttonHeight, y: bottomY, width: Self.buttonHeight, height: Self.buttonHeight)
        resetButton.sizeToFit()
        resetButton.frame = CGRect(x: safe.midX - resetButton.bounds.width / 2, y: bottomY, width: resetButton.bounds.width, height: Self.buttonHeight)
        guard baseImage != nil, laidOutSize != view.bounds.size else { return }
        if laidOutSize != .zero {
            pendingRect = currentRect()
        }
        laidOutSize = view.bounds.size
        layout(rect: pendingRect)
    }

    private static let buttonHeight: CGFloat = 44
    /// 枠の辺の、これより短くしない長さ（pt）。
    private static let minimumBoxSide: CGFloat = 48

    /// 枠を置ける範囲。上下のボタンの行を除いた、画面の余白の内側。
    private var cropArea: CGRect {
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let top = safe.minY + 8 + Self.buttonHeight + 20
        let bottom = safe.maxY - 8 - Self.buttonHeight - 20
        return CGRect(x: safe.minX + 20, y: top, width: max(safe.width - 40, 1), height: max(bottom - top, 1))
    }

    /// 回したあとの、表示用の画像。
    private var displayImage: UIImage? {
        guard let cgImage = baseImage?.cgImage else { return nil }
        let orientation: UIImage.Orientation = switch quarterTurns {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }

    /// 縦横比を決めていれば、その比率（幅÷高さ）。
    private var lockedRatio: CGFloat? {
        switch aspect {
        case .free: nil
        case .original: displayImage.map { $0.size.width / $0.size.height }
        case .ratio(let width, let height): width / height
        }
    }

    private func load() {
        Task { [weak self, file] in
            let image = await LocalMediaThumbnail.make(for: file, maxPixelSize: CGFloat(MediaImageStore.fullPixelSize))
            guard let self else { return }
            self.spinner.stopAnimating()
            guard let image else {
                SciaLog.logger(category: "media").error("crop: could not load image")
                self.dismiss(animated: true)
                return
            }
            self.baseImage = image
            self.overlay.isHidden = false
            self.setControlsEnabled(true)
            self.laidOutSize = .zero
            self.view.setNeedsLayout()
        }
    }

    // MARK: 並べ方

    /// 回したあとの画像の`rect`（割合）が、枠いっぱいに収まるよう並べる。
    private func layout(rect: CGRect) {
        guard let image = displayImage else { return }
        cancelRecenter()
        let size = image.size
        let crop = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        let target = CropBox.fit(aspectRatio: crop.width / crop.height, in: cropArea)
        // 大きさを決め直す前に、等倍に戻してから画像の枠を当てる。
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.zoomScale = 1
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        let fitScale = min(cropArea.width / size.width, cropArea.height / size.height)
        let zoom = target.width / crop.width
        scrollView.maximumZoomScale = max(zoom, fitScale * 10, minimumZoom(for: target, imageSize: size))
        apply(box: target)
        scrollView.zoomScale = max(zoom, scrollView.minimumZoomScale)
        scrollView.contentOffset = CGPoint(x: crop.minX * scrollView.zoomScale - target.minX, y: crop.minY * scrollView.zoomScale - target.minY)
        updateResetButton()
    }

    /// 枠を変え、画像を動かせる範囲と縮められる倍率を枠に合わせる。
    private func apply(box: CGRect) {
        self.box = box
        overlay.box = box
        scrollView.contentInset = UIEdgeInsets(top: box.minY, left: box.minX, bottom: view.bounds.height - box.maxY, right: view.bounds.width - box.maxX)
        if let size = imageView.image?.size {
            scrollView.minimumZoomScale = minimumZoom(for: box, imageSize: size)
        }
    }

    /// 画像が枠を覆う、一番小さい倍率。
    private func minimumZoom(for box: CGRect, imageSize: CGSize) -> CGFloat {
        max(box.width / imageSize.width, box.height / imageSize.height)
    }

    /// 枠に見えている範囲を、回したあとの画像の割合で表す。
    private func currentRect() -> CGRect {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return pendingRect }
        let crop = overlay.convert(box, to: imageView)
        return ImageCrop(
            quarterTurns: quarterTurns,
            rect: CGRect(x: crop.minX / size.width, y: crop.minY / size.height, width: crop.width / size.width, height: crop.height / size.height)
        ).rect
    }

    // MARK: 枠の操作

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelRecenter()
            stopRecentering()
            // 始まったと判定される時点では指がもう動いているので、触れた瞬間の位置でハンドルを決める。
            // 速く動かすと、今の位置も、移動量を引いた位置も、ハンドルから外れていた（移動量は判定した時点から数える）。
            activeHandle = overlay.handle(at: touchDownLocation)
            dragStartBox = box
            overlay.showsGrid = true
        case .changed:
            guard let activeHandle else { return }
            let imageFrame = imageView.convert(imageView.bounds, to: overlay)
            let resized = CropBox.resize(
                dragStartBox,
                handle: activeHandle,
                by: CGVector(dx: gesture.translation(in: overlay).x, dy: gesture.translation(in: overlay).y),
                within: cropArea.intersection(imageFrame),
                minimumSide: Self.minimumBoxSide,
                aspectRatio: lockedRatio
            )
            apply(box: resized)
        case .ended, .cancelled, .failed:
            guard activeHandle != nil else { return }
            activeHandle = nil
            overlay.showsGrid = false
            updateResetButton()
            scheduleRecenter()
        default:
            break
        }
    }

    /// 少し待ってから、枠を画面の中央いっぱいへ戻す。待つ間に枠や画像に触れたら、戻すのをやめる。
    private func scheduleRecenter() {
        recenterTask?.cancel()
        let delay = tuning.value(of: TuningCatalog.mediaCropRecenterDelay)
        recenterTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.recenterTask = nil
            self.recenter()
        }
    }

    private func cancelRecenter() {
        recenterTask?.cancel()
        recenterTask = nil
    }

    /// 枠を画面の中央いっぱいへ広げ、同じ範囲が枠に収まるよう画像を拡大する。拡大できる上限を超えるなら、上限の大きさで止める。
    /// 動きの途中にも、枠や画像を操作できる。
    private func recenter() {
        guard activeHandle == nil, !scrollView.isTracking, !scrollView.isZooming, imageView.image != nil else { return }
        let crop = overlay.convert(box, to: imageView)
        guard crop.width > 0, crop.height > 0 else { return }
        var target = CropBox.fit(aspectRatio: box.width / box.height, in: cropArea)
        var zoom = target.width / crop.width
        if zoom > scrollView.maximumZoomScale {
            zoom = scrollView.maximumZoomScale
            let size = CGSize(width: crop.width * zoom, height: crop.height * zoom)
            target = CGRect(x: cropArea.midX - size.width / 2, y: cropArea.midY - size.height / 2, width: size.width, height: size.height)
        }
        guard target != box else { return }
        animateBox {
            self.apply(box: target)
            self.scrollView.zoomScale = zoom
            self.scrollView.contentOffset = CGPoint(x: crop.minX * zoom - target.minX, y: crop.minY * zoom - target.minY)
        }
    }

    /// 枠と画像を動かす。動きの途中に触れたら、`stopRecentering`で見えている位置に止める。
    private func animateBox(_ changes: @escaping () -> Void) {
        recenterGeneration += 1
        let generation = recenterGeneration
        isRecentering = true
        let duration = tuning.value(of: TuningCatalog.mediaCropRecenterDuration)
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]) {
            changes()
            self.overlay.layoutIfNeeded()
        } completion: { _ in
            // 次の動きに置き換えられた前の動きの完了で、今の動きの途中の印を外さない。
            guard generation == self.recenterGeneration else { return }
            self.isRecentering = false
        }
    }

    /// 枠を中央へ戻す動きの途中で枠や画像に触れたら、見えている位置で動きを止め、そこから操作を続ける。
    /// 止めないと、操作は動きの行き先の枠と倍率から始まり、触れた瞬間に枠と画像が飛ぶ。
    private func stopRecentering() {
        guard isRecentering else { return }
        isRecentering = false
        recenterGeneration += 1
        let shownBox = overlay.shownBox
        let offset = scrollView.layer.presentation()?.bounds.origin ?? scrollView.contentOffset
        let zoom = imageView.layer.presentation().map { CGFloat($0.transform.m11) } ?? scrollView.zoomScale
        overlay.removeAllAnimations()
        scrollView.layer.removeAllAnimations()
        imageView.layer.removeAllAnimations()
        apply(box: shownBox)
        scrollView.zoomScale = zoom
        scrollView.contentOffset = offset
        overlay.layoutIfNeeded()
    }

    // MARK: ボタン

    @objc private func cancel() {
        cancelRecenter()
        dismiss(animated: true)
    }

    @objc private func finish() {
        guard let image = displayImage else { return }
        cancelRecenter()
        let crop = ImageCrop(quarterTurns: quarterTurns, rect: currentRect())
        let result = crop.isIdentity(in: originalSize) ? nil : crop
        onFinish?(result, result.map { preview(of: image, rect: $0.rect) } ?? baseImage)
        dismiss(animated: true)
    }

    /// 反時計回りに90度回す。残す範囲も一緒に回し、決めた縦横比は縦と横を入れ替える。
    /// 写真アプリと同じく、画像と枠をまとめて回しながら、回したあとの枠の大きさへ動かす。
    /// 回したあとの並びを先に作り、キャンバスに回す前の見た目へ戻す変形をかけてから、毎コマ変形なしへ近づける。
    /// UIViewのアニメーションに任せないのは、見た目と当たり判定を毎コマそろえるためと、続けて押して180°を超えても同じ向きに回すため。
    /// 回している途中に続けて押したら、見えている変形の上に重ねて続けて回す。「視差効果を減らす」がオンなら、回さずにフェードで替える。
    @objc private func rotate() {
        guard baseImage != nil else { return }
        let shown = rotation?.pose ?? .identity
        stopRotationTicker()
        canvas.transform = .identity
        cancelRecenter()
        stopRecentering()
        let rect = currentRect()
        let oldBox = box
        quarterTurns = (quarterTurns + 3) % 4
        // 反時計回りに回すと、回す前の点(x, y)は(y, 1 - x)に移る。
        let rotated = CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        aspect = aspect.rotated
        updateAspectMenu()
        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.transition(with: view, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.layout(rect: rotated)
            }
            return
        }
        layout(rect: rotated)
        let start = CropRotationPose
            .undoingCounterclockwiseTurn(from: box, to: oldBox, around: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            .followed(by: shown)
        // 回したあとの枠の中心を軸にして回す。画面の中央を軸にすると、枠を置く範囲が中央からずれている分、途中で枠の中心が外れる。
        let state = RotationState(
            start: start,
            pivot: CGPoint(x: box.midX, y: box.midY),
            center: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY),
            duration: tuning.value(of: TuningCatalog.mediaCropRotateDuration)
        )
        rotation = state
        canvas.transform = start.affineTransform
        // 回る途中で、枠の外の暗くしていない画像が画面の隅に見えないよう、枠の外を黒で覆う。
        overlay.coversOutside = true
        let ticker = FrameTicker(source: frameSource, longestElapsed: nil) { [weak self] elapsed in
            guard let self, let rotation = self.rotation, rotation === state else { return false }
            rotation.elapsed += elapsed
            self.canvas.transform = rotation.pose.affineTransform
            guard rotation.isFinished else { return true }
            self.rotation = nil
            self.uncoverOutside()
            return false
        }
        rotationTicker = ticker
        ticker.start()
    }

    /// 回している途中に枠や画像に触れたら、回し終えた状態にして操作を続ける。変形をかけたままでは、指の動きと枠や画像の動きが合わないため。
    /// 触れた位置は、回し終える前の見た目で受け取っている（`touchDownLocation`）。
    private func finishRotation() {
        guard rotation != nil else { return }
        stopRotationTicker()
        canvas.transform = .identity
        uncoverOutside()
    }

    private func stopRotationTicker() {
        rotation = nil
        rotationTicker?.stop()
        rotationTicker = nil
    }

    private func uncoverOutside() {
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.overlay.coversOutside = false
        }
    }

    @objc private func reset() {
        guard baseImage != nil else { return }
        quarterTurns = 0
        aspect = .free
        updateAspectMenu()
        UIView.transition(with: view, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.layout(rect: ImageCrop.unitRect)
        }
    }

    /// 縦横比を選ぶ。今の範囲の中央を保ったまま、画像に収まる一番大きい範囲にする。
    private func choose(_ aspect: Aspect) {
        self.aspect = aspect
        updateAspectMenu()
        guard let image = displayImage, let ratio = lockedRatio else { return }
        let size = image.size
        let current = currentRect()
        let pixels = CropBox.fit(aspectRatio: ratio, in: CGRect(origin: .zero, size: size))
        let width = pixels.width / size.width, height = pixels.height / size.height
        let x = min(max(current.midX - width / 2, 0), 1 - width)
        let y = min(max(current.midY - height / 2, 0), 1 - height)
        animateBox {
            self.layout(rect: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    private func updateAspectMenu() {
        aspectButton.menu = UIMenu(title: "縦横比", options: .singleSelection, children: Aspect.choices.map { choice in
            UIAction(title: choice.title, state: choice.aspect == aspect ? .on : .off) { [weak self] _ in self?.choose(choice.aspect) }
        })
    }

    private func updateResetButton() {
        let changed = !ImageCrop(quarterTurns: quarterTurns, rect: currentRect()).isIdentity(in: originalSize)
        resetButton.isEnabled = changed && baseImage != nil
        resetButton.alpha = changed ? 1 : 0
    }

    private func setControlsEnabled(_ enabled: Bool) {
        for button in [doneButton, rotateButton, aspectButton] {
            button.isEnabled = enabled
        }
        resetButton.isEnabled = false
        resetButton.alpha = 0
    }

    /// 回したあとの表示用の画像から、残す範囲を描く。送るファイルを作り終えるまで、投稿欄とビューアに出す。
    private func preview(of image: UIImage, rect: CGRect) -> UIImage {
        let crop = CGRect(x: rect.minX * image.size.width, y: rect.minY * image.size.height, width: rect.width * image.size.width, height: rect.height * image.size.height)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: max(crop.width.rounded(), 1), height: max(crop.height.rounded(), 1)), format: format).image { _ in
            image.draw(at: CGPoint(x: -crop.minX, y: -crop.minY))
        }
    }

    private func configure(_ button: UIButton, title: String? = nil, symbol: String? = nil, label: String? = nil, action: Selector?) {
        button.configuration?.title = title
        if let symbol {
            button.configuration?.image = UIImage(systemName: symbol)
            button.accessibilityLabel = label
        }
        if let action {
            button.addTarget(self, action: action, for: .primaryActionTriggered)
        }
        view.addSubview(button)
    }
}

extension ImageCropViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelRecenter()
        stopRecentering()
        overlay.showsGrid = true
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        cancelRecenter()
        stopRecentering()
        overlay.showsGrid = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            interactionDidEnd()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        interactionDidEnd()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        interactionDidEnd()
    }

    private func interactionDidEnd() {
        overlay.showsGrid = false
        updateResetButton()
    }
}

/// トリミングの枠。枠の外を暗くし、四隅にハンドルを描く。枠の辺の近くだけで触れたものを受け、ほかはスクロールビューに通す。
final class CropOverlayView: UIView {
    var box: CGRect = .zero {
        didSet { setNeedsLayout() }
    }

    /// 枠の外を、暗くするのではなく黒で覆う。回している途中に使う。
    var coversOutside = false {
        didSet {
            for dim in dimViews { dim.backgroundColor = UIColor.black.withAlphaComponent(coversOutside ? 1 : Self.dimAlpha) }
        }
    }

    private static let dimAlpha: CGFloat = 0.6

    /// 枠を3つに分ける線を出す。枠や画像を動かしている間だけ出す。
    var showsGrid = false {
        didSet {
            guard showsGrid != oldValue else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                for line in self.gridLines { line.alpha = self.showsGrid ? 1 : 0 }
            }
        }
    }

    /// 辺から、触れたものを受ける幅（pt）。
    private static let touchMargin: CGFloat = 22
    private static let cornerLength: CGFloat = 20
    private static let cornerThickness: CGFloat = 3

    private let dimViews = (0..<4).map { _ in UIView() }
    private let border = UIView()
    private let gridLines = (0..<4).map { _ in UIView() }
    private let corners = (0..<8).map { _ in UIView() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for dim in dimViews {
            dim.backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha)
            dim.isUserInteractionEnabled = false
            addSubview(dim)
        }
        border.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        border.layer.borderWidth = 1
        border.isUserInteractionEnabled = false
        addSubview(border)
        for line in gridLines {
            line.backgroundColor = UIColor.white.withAlphaComponent(0.5)
            line.alpha = 0
            border.addSubview(line)
        }
        for corner in corners {
            corner.backgroundColor = .white
            border.addSubview(corner)
        }
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        dimViews[0].frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(box.minY, 0))
        dimViews[1].frame = CGRect(x: 0, y: box.maxY, width: bounds.width, height: max(bounds.height - box.maxY, 0))
        dimViews[2].frame = CGRect(x: 0, y: box.minY, width: max(box.minX, 0), height: box.height)
        dimViews[3].frame = CGRect(x: box.maxX, y: box.minY, width: max(bounds.width - box.maxX, 0), height: box.height)
        border.frame = box
        let size = box.size
        for index in 0..<2 {
            let fraction = CGFloat(index + 1) / 3
            gridLines[index].frame = CGRect(x: size.width * fraction, y: 0, width: 1 / traitCollection.displayScale, height: size.height)
            gridLines[index + 2].frame = CGRect(x: 0, y: size.height * fraction, width: size.width, height: 1 / traitCollection.displayScale)
        }
        // 角ごとに、横と縦の2本の太い線を、枠の外側へはみ出させて描く。
        let length = Self.cornerLength, thickness = Self.cornerThickness
        let origins: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 0, 1, 1), (size.width, 0, -1, 1), (0, size.height, 1, -1), (size.width, size.height, -1, -1)]
        for (index, (x, y, dx, dy)) in origins.enumerated() {
            let horizontalX = dx > 0 ? x - thickness : x - length
            let verticalY = dy > 0 ? y - thickness : y - length
            corners[index * 2].frame = CGRect(x: horizontalX, y: dy > 0 ? y - thickness : y, width: length + thickness, height: thickness)
            corners[index * 2 + 1].frame = CGRect(x: dx > 0 ? x - thickness : x, y: verticalY, width: thickness, height: length + thickness)
        }
    }

    /// 枠の辺の近くだけで触れたものを受ける。枠の内側と外側は、画像を動かすスクロールビューに通す。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        handle(at: point) != nil
    }

    /// 見えている枠。動きの途中なら、動いている途中の位置。
    var shownBox: CGRect {
        border.layer.presentation()?.frame ?? box
    }

    /// 枠の動きを、行き先の位置で止める。
    func removeAllAnimations() {
        for subview in subviews + border.subviews {
            subview.layer.removeAllAnimations()
        }
    }

    /// 触れた位置のハンドル。角を辺より優先する。辺から遠ければnil。動きの途中なら、見えている枠で決める。
    func handle(at point: CGPoint) -> CropHandle? {
        let box = shownBox
        let margin = Self.touchMargin
        guard box.insetBy(dx: -margin, dy: -margin).contains(point) else { return nil }
        let nearLeft = abs(point.x - box.minX) <= margin
        let nearRight = abs(point.x - box.maxX) <= margin
        let nearTop = abs(point.y - box.minY) <= margin
        let nearBottom = abs(point.y - box.maxY) <= margin
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }
}

/// トリミングで回している途中の動き。始めの変形から変形なしへ、経過時間で近づける。
@MainActor
private final class RotationState {
    let start: CropRotationPose
    /// 回す軸にする点。回したあとの枠の中心。
    let pivot: CGPoint
    /// 変形の中心。キャンバスの中央。
    let center: CGPoint
    let duration: CFTimeInterval
    var elapsed: CFTimeInterval = 0

    init(start: CropRotationPose, pivot: CGPoint, center: CGPoint, duration: CFTimeInterval) {
        self.start = start
        self.pivot = pivot
        self.center = center
        self.duration = duration
    }

    var isFinished: Bool { elapsed >= duration }

    /// 今の変形。ゆっくり始まってゆっくり終わる（smoothstep）。
    var pose: CropRotationPose {
        let progress = duration > 0 ? min(max(elapsed / duration, 0), 1) : 1
        let eased = progress * progress * (3 - 2 * progress)
        return start.approachingIdentity(fraction: CGFloat(eased), pivot: pivot, around: center)
    }
}

/// 触れた瞬間を知らせるだけで、何も認識しないジェスチャー。ほかのジェスチャーとビューの操作を止めない。
private final class TouchDownObserver: UIGestureRecognizer {
    private let onTouchDown: @MainActor (UITouch) -> Void

    init(onTouchDown: @escaping @MainActor (UITouch) -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            onTouchDown(touch)
        }
        state = .failed
    }
}

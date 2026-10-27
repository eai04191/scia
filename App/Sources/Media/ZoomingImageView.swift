import UIKit

/// 画像を画面に収めて出し、ピンチとダブルタップで拡大する。画面より小さい画像は、引き伸ばさずに等倍で出す。
final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    /// ダブルタップで拡大するとき、画面に収めた大きさの何倍にするか。
    private static let doubleTapZoomScale: CGFloat = 2.5
    /// 等倍が画面に収めた大きさのこの割合以上なら、等倍ではなく画面に収める。端にわずかな隙間だけが残る見た目を避けるため。
    private static let nearFitRatio: CGFloat = 0.9
    /// ピンチを終えた倍率が、画面に収める倍率とこの割合以内の差なら、画面に収める倍率へ寄せる。
    private static let fitSnapTolerance: CGFloat = 0.15

    /// 等倍で出したときの大きさ。画像の1ピクセルを1ポイントにする。分からなければnilにし、画面に収める。
    /// サムネイルを出している間も元の画像の大きさで決めるよう、出している画像とは別に、`image`より先に設定する。
    var naturalSize: CGSize?

    private let imageView = UIImageView()
    var onSingleTap: (() -> Void)?
    /// ダブルタップして拡大するときと、戻すときの時間。UIScrollViewの`animated`の拡大は時間を変えられないため、自前で動かす。
    var doubleTapZoomDuration: TimeInterval = 0.2
    /// ダブルタップの拡大か縮小が動いている。
    private var isAnimatingZoom = false

    var image: UIImage? {
        get { imageView.image }
        set { setImage(newValue, crossfadeDuration: 0) }
    }

    /// 画像を差し替える。`crossfadeDuration`が0より大きければ、前の画像をその時間で薄くして入れ替える。
    func setImage(_ newImage: UIImage?, crossfadeDuration: TimeInterval) {
        let wasAtRest = isAtRest
        if newImage !== imageView.image {
            imageView.fadeOutCurrentImage(duration: crossfadeDuration)
        }
        imageView.image = newImage
        imageView.isHidden = newImage == nil
        // サムネイルから元の画像へ差し替えたときは、見ている位置を保つため、倍率を変えていれば見た目の大きさを変えない。
        updateZoomScales(resetting: wasAtRest)
    }

    /// 元の画像が届いて、等倍の大きさが初めて分かったときに設定する。開いたときの倍率のままなら、画面に収めた大きさから等倍へ、`duration`秒かけて縮める。
    /// 一度に縮めると、画面幅いっぱいの画像が1コマで小さくなる。`duration`が0なら、動かさずに縮める。拡大していれば、見ている大きさを変えない。
    func setNaturalSize(_ size: CGSize, duration: TimeInterval) {
        let wasAtRest = isAtRest
        naturalSize = size
        guard let imageSize = imageView.image?.size, imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        minimumZoomScale = fitScale * naturalRatio()
        guard wasAtRest, abs(zoomScale - minimumZoomScale) > 0.001 else { return }
        stopZoomAnimation()
        guard duration > 0 else {
            zoomScale = minimumZoomScale
            return
        }
        animateZoom(duration: duration) { $0.setZoomScale($0.minimumZoomScale, animated: false) }
    }

    /// 画像を描いている枠の、いま見えている位置。自身の座標。等倍へ縮めている途中は、動いている途中の枠を返す。
    var presentedImageFrame: CGRect? {
        guard imageView.image != nil else { return nil }
        guard let image = imageView.layer.presentation(), let scroll = layer.presentation() else { return imageView.frame }
        // 自身の座標は境界の原点（スクロールの位置）からの位置なので、見えている原点に合わせて直す。
        return image.frame.offsetBy(dx: bounds.minX - scroll.bounds.minX, dy: bounds.minY - scroll.bounds.minY)
    }

    /// 前の画像から薄く入れ替えている途中なら、前の画像と、いま見えている濃さ。
    var fadingImage: (image: UIImage, alpha: CGFloat)? {
        imageView.fadingImage
    }

    /// 画像そのものに操作を付ける。Live Textのように、画像の中の位置で振る舞いを変え、拡大に合わせて動く必要がある操作に使う。
    func addImageInteraction(_ interaction: any UIInteraction) {
        imageView.isUserInteractionEnabled = true
        imageView.addInteraction(interaction)
    }

    var imageAccessibilityLabel: String? {
        get { imageView.accessibilityLabel }
        set { imageView.accessibilityLabel = newValue }
    }

    /// 画面に収める大きさより拡大している。
    var isZoomedIn: Bool {
        zoomScale > fitScale + 0.01
    }

    /// 開いたときの倍率のまま。
    private var isAtRest: Bool {
        zoomScale <= minimumZoomScale + 0.01
    }

    /// 画面に収める倍率。
    private var fitScale: CGFloat = 1

    /// 画像を描いている枠。自身の座標。
    var imageFrame: CGRect? {
        imageView.image == nil ? nil : imageView.frame
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 倍率を決めたときの大きさ。画像の差し替えでも倍率を決め直すため、レイアウトの時点の大きさではなく、こちらと比べる。
    private var fittedBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedBoundsSize {
            updateZoomScales(resetting: true)
        }
        centerImage()
    }

    /// 画像の大きさを1倍として、画面に収まる倍率と等倍のうち小さいほうを最小にする。
    private func updateZoomScales(resetting: Bool) {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        fittedBoundsSize = bounds.size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let previousImageWidth = imageView.frame.width
        let previousCenter = normalizedVisibleCenter()
        // 倍率の範囲が前の画像のままだと、1への切り替えが範囲へ切り上げられ、拡大した状態の`imageView`に大きさを設定してしまう。
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        fitScale = fit
        minimumZoomScale = fit * naturalRatio()
        maximumZoomScale = max(fit * 4, 1)
        if resetting || previousImageWidth == 0 {
            zoomScale = minimumZoomScale
        } else {
            // 差し替える前と同じ見た目の大きさにする。
            zoomScale = min(max(previousImageWidth / size.width, minimumZoomScale), maximumZoomScale)
            centerImage()
            if let previousCenter {
                restoreVisibleCenter(previousCenter)
            }
            return
        }
        centerImage()
    }

    /// 等倍で出したときの大きさの、画面に収めた大きさに対する割合。1を超えない。等倍が分からないか、ほぼ画面に収まるなら1。
    private func naturalRatio() -> CGFloat {
        guard let naturalSize, naturalSize.width > 0, naturalSize.height > 0 else { return 1 }
        let ratio = 1 / min(bounds.width / naturalSize.width, bounds.height / naturalSize.height)
        return ratio >= Self.nearFitRatio ? 1 : ratio
    }

    /// 違和感レポートに残す、倍率と大きさの状態。
    func stateDump() -> String {
        """
        bounds: \(bounds.size)
        fittedBoundsSize: \(fittedBoundsSize)
        imageSize: \(imageView.image.map { "\($0.size) scale=\($0.scale)" } ?? "nil")
        naturalSize: \(naturalSize.map { "\($0)" } ?? "nil")
        zoomScale: \(zoomScale) min=\(minimumZoomScale) fit=\(fitScale) max=\(maximumZoomScale)
        contentSize: \(contentSize)
        contentInset: \(contentInset)
        contentOffset: \(contentOffset)
        imageView.frame: \(imageView.frame)
        imageView.bounds: \(imageView.bounds)
        """
    }

    /// 画面の中央に見えている点の、画像の中での位置。左上が0、右下が1。
    private func normalizedVisibleCenter() -> CGPoint? {
        let frame = imageView.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let center = CGPoint(x: contentOffset.x + bounds.width / 2, y: contentOffset.y + bounds.height / 2)
        return CGPoint(x: (center.x - frame.minX) / frame.width, y: (center.y - frame.minY) / frame.height)
    }

    /// 画像の中の`point`が画面の中央に来るよう動かす。動かせる範囲を超える分は端で止める。
    private func restoreVisibleCenter(_ point: CGPoint) {
        let frame = imageView.frame
        let target = CGPoint(x: frame.minX + point.x * frame.width - bounds.width / 2, y: frame.minY + point.y * frame.height - bounds.height / 2)
        let minOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        let maxOffset = CGPoint(
            x: max(contentSize.width + contentInset.right - bounds.width, minOffset.x),
            y: max(contentSize.height + contentInset.bottom - bounds.height, minOffset.y)
        )
        contentOffset = CGPoint(x: min(max(target.x, minOffset.x), maxOffset.x), y: min(max(target.y, minOffset.y), maxOffset.y))
    }

    /// 画面より小さいときは真ん中に置く。
    private func centerImage() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        stopZoomAnimation()
        if !isAtRest {
            animateZoom { $0.setZoomScale($0.minimumZoomScale, animated: false) }
            return
        }
        // 等倍で出している小さい画像は、まず画面に収める。
        if fitScale > minimumZoomScale + 0.01 {
            animateZoom { $0.setZoomScale($0.fitScale, animated: false) }
            return
        }
        let scale = min(fitScale * Self.doubleTapZoomScale, maximumZoomScale)
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        animateZoom { $0.zoom(to: rect, animated: false) }
    }

    private func animateZoom(duration: TimeInterval? = nil, _ changes: @escaping (ZoomingImageView) -> Void) {
        isAnimatingZoom = true
        UIView.animate(springDuration: duration ?? doubleTapZoomDuration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            changes(self)
        } completion: { [weak self] finished in
            if finished { self?.isAnimatingZoom = false }
        }
    }

    /// 動いている拡大か縮小を、いま見えている倍率と位置で止める。動いている途中にピンチやスクロールを始めたとき、行き先の倍率から始まって画像が跳ばないようにする。
    private func stopZoomAnimation() {
        guard isAnimatingZoom else { return }
        isAnimatingZoom = false
        let presentedScale = imageView.layer.presentation()?.transform.m11
        let presentedOrigin = layer.presentation()?.bounds.origin
        imageView.layer.removeAllAnimations()
        layer.removeAllAnimations()
        if let presentedScale, presentedScale > 0 {
            setZoomScale(presentedScale, animated: false)
        }
        if let presentedOrigin {
            contentOffset = presentedOrigin
        }
    }

    @objc private func singleTapped() {
        onSingleTap?()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        stopZoomAnimation()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stopZoomAnimation()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    /// 等倍で出している小さい画像を、画面に収める倍率の近くまでピンチしたら、画面に収める。
    /// 等倍へ戻したときは寄せない。等倍が画面に収める倍率に近い画像で、ダブルタップで等倍へ戻せなくなるため。
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard fitScale > minimumZoomScale + 0.01, scale > minimumZoomScale + 0.01, abs(scale - fitScale) > 0.001, abs(scale - fitScale) <= fitScale * Self.fitSnapTolerance else { return }
        setZoomScale(fitScale, animated: true)
    }
}

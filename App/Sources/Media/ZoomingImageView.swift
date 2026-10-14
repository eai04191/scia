import UIKit

/// 画像を画面に収めて出し、ピンチとダブルタップで拡大する。
final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    /// ダブルタップで拡大するとき、画面に収めた大きさの何倍にするか。
    private static let doubleTapZoomScale: CGFloat = 2.5

    private let imageView = UIImageView()
    var onSingleTap: (() -> Void)?

    var image: UIImage? {
        get { imageView.image }
        set {
            let wasZoomedIn = isZoomedIn
            imageView.image = newValue
            imageView.isHidden = newValue == nil
            // サムネイルから元の画像へ差し替えたときは、見ている位置を保つため、拡大していれば倍率を変えない。
            updateZoomScales(resetting: !wasZoomedIn)
        }
    }

    var imageAccessibilityLabel: String? {
        get { imageView.accessibilityLabel }
        set { imageView.accessibilityLabel = newValue }
    }

    var isZoomedIn: Bool {
        zoomScale > minimumZoomScale + 0.01
    }

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

    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            updateZoomScales(resetting: true)
        }
        centerImage()
    }

    /// 画像の大きさを1倍として、画面に収まる倍率を最小にする。
    private func updateZoomScales(resetting: Bool) {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let previousMinimum = minimumZoomScale
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let previousScale = zoomScale
        let previousImageWidth = imageView.frame.width
        let previousCenter = normalizedVisibleCenter()
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 4, 1)
        if resetting || previousImageWidth == 0 {
            zoomScale = fit
        } else {
            // 差し替える前と同じ見た目の大きさにする。
            let ratio = previousScale / previousMinimum
            zoomScale = min(max(fit * ratio, minimumZoomScale), maximumZoomScale)
            centerImage()
            if let previousCenter {
                restoreVisibleCenter(previousCenter)
            }
            return
        }
        centerImage()
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
        if isZoomedIn {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(minimumZoomScale * Self.doubleTapZoomScale, maximumZoomScale)
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    @objc private func singleTapped() {
        onSingleTap?()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }
}

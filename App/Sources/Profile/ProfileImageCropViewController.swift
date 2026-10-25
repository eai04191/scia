import ImageIO
import os
import SciaCore
import UIKit
import UniformTypeIdentifiers

/// アイコンかヘッダー画像を、送る枠に切り抜く画面。
///
/// 枠と同じ大きさのスクロールビューに画像を載せ、ピンチと移動で枠に入れる部分を選ばせる。UIKitのスクロールビューの拡大と慣性をそのまま使う。
/// 枠の外も、画像が見えるよう暗くして残し、枠の外から触れても動かせるようにする。
/// ヘッダー画像は、下の切り替えで3:2と3:1を選べる。既定は、Sciaが勧める3:2。
@MainActor
final class ProfileImageCropViewController: UIViewController {
    /// 切り抜いた画像。送るファイルと、編集画面で見せる画像を渡す。
    var onDone: (MediaUpload, UIImage) -> Void = { _, _ in }
    var onCancel: () -> Void = {}

    private let image: CGImage
    private let kind: ProfileImage
    private var headerAspect: ProfileImageCrop.HeaderAspect = .standard
    private var crop: ProfileImageCrop {
        switch kind {
        case .avatar: .avatar
        case .header: .header(headerAspect)
        }
    }
    private let avatarShape: AvatarShape
    private let aspectControl = UISegmentedControl()
    private let touchArea = CropTouchArea()
    private lazy var cropElement = CropAccessibilityElement(accessibilityContainer: touchArea)
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let dimming = CAShapeLayer()
    private let outline = CAShapeLayer()
    /// 最初に枠を置いたときだけ、画像を枠に収めて中央に置く。回転などで置き直すときは、選んでいた位置を保つ。
    private var placedFrameSize: CGSize?
    private let logger = SciaLog.logger(category: "profile")

    init(image: CGImage, kind: ProfileImage, avatarShape: AvatarShape) {
        self.image = image
        self.kind = kind
        self.avatarShape = avatarShape
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var imagePixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationItem.title = switch kind {
        case .avatar: "アイコンを切り抜く"
        case .header: "ヘッダー画像を切り抜く"
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel() })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完了", style: .prominent, target: nil, action: nil)
        navigationItem.rightBarButtonItem?.primaryAction = UIAction(title: "完了") { [weak self] _ in self?.finish() }

        touchArea.frame = view.bounds
        touchArea.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        touchArea.target = scrollView
        view.addSubview(touchArea)

        imageView.image = UIImage(cgImage: image)
        imageView.frame = CGRect(origin: .zero, size: imagePixelSize)
        scrollView.addSubview(imageView)
        scrollView.contentSize = imagePixelSize
        scrollView.delegate = self
        // 枠の外の画像も見せる。
        scrollView.clipsToBounds = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        touchArea.addSubview(scrollView)

        dimming.fillRule = .evenOdd
        dimming.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
        outline.fillColor = nil
        outline.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        outline.lineWidth = 1
        touchArea.layer.addSublayer(dimming)
        touchArea.layer.addSublayer(outline)
        // ピンチとドラッグの代わりに、VoiceOverでは拡大縮小と範囲を動かす操作で選ぶ。
        cropElement.accessibilityLabel = navigationItem.title
        cropElement.frame = { [weak self] in self?.scrollView.frame ?? .zero }
        cropElement.viewport = { [weak self] in
            guard let self else { return nil }
            return self.scrollView.cropViewport(box: CGRect(origin: .zero, size: self.scrollView.bounds.size))
        }
        cropElement.apply = { [weak self] viewport in self?.scrollView.apply(viewport) }
        touchArea.accessibilityElements = [cropElement]
        if kind == .header {
            configureAspectControl()
        }
    }

    /// ヘッダー画像の比率の切り替え。枠の下に置く。
    private func configureAspectControl() {
        for (index, aspect) in ProfileImageCrop.HeaderAspect.allCases.enumerated() {
            let action = UIAction(title: Self.title(of: aspect)) { [weak self] _ in self?.select(aspect) }
            aspectControl.insertSegment(action: action, at: index, animated: false)
        }
        aspectControl.selectedSegmentIndex = ProfileImageCrop.HeaderAspect.allCases.firstIndex(of: headerAspect) ?? 0
        aspectControl.accessibilityLabel = "縦横比"
        aspectControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(aspectControl)
        NSLayoutConstraint.activate([
            aspectControl.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            aspectControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private static func title(of aspect: ProfileImageCrop.HeaderAspect) -> String {
        switch aspect {
        case .standard: "3:2"
        case .wide: "3:1"
        }
    }

    /// 比率を替えても、枠の中央に見えていた点を中央に残す。
    private func select(_ aspect: ProfileImageCrop.HeaderAspect) {
        guard aspect != headerAspect else { return }
        headerAspect = aspect
        logger.info("profile header crop aspect=\(Self.title(of: aspect), privacy: .public)")
        layoutFrame()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutFrame()
    }

    /// 安全領域の中の中央に、枠を左右16ptの余白で置く。iPadや横向きでは、縦にも収まる大きさにする。
    private func layoutFrame() {
        var area = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 16, dy: 16)
        // 比率の切り替えを出していれば、その上に収める。
        if aspectControl.superview != nil {
            area.size.height -= aspectControl.intrinsicContentSize.height + 16
        }
        guard area.width > 0, area.height > 0 else { return }
        let aspect = CGFloat(crop.aspect)
        let width = min(area.width, area.height * aspect, 600 * max(aspect, 1))
        let size = CGSize(width: width.rounded(), height: (width / aspect).rounded())
        let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        guard scrollView.frame != frame else { return }
        let previousCenter = placedFrameSize == nil ? nil : centerInImage()
        scrollView.frame = frame
        let minimum = ProfileImageCrop.minimumZoomScale(imageSize: imagePixelSize, frameSize: size)
        scrollView.minimumZoomScale = minimum
        scrollView.maximumZoomScale = max(minimum * 5, minimum)
        if placedFrameSize == nil {
            scrollView.zoomScale = minimum
        } else {
            scrollView.zoomScale = min(max(scrollView.zoomScale, minimum), scrollView.maximumZoomScale)
        }
        placedFrameSize = size
        center(on: previousCenter ?? CGPoint(x: imagePixelSize.width / 2, y: imagePixelSize.height / 2))
        updateMask()
    }

    /// 枠の中央にある、画像の中の点（ピクセル）。
    private func centerInImage() -> CGPoint {
        let scale = scrollView.zoomScale
        return CGPoint(
            x: (scrollView.contentOffset.x + scrollView.bounds.width / 2) / scale,
            y: (scrollView.contentOffset.y + scrollView.bounds.height / 2) / scale
        )
    }

    private func center(on point: CGPoint) {
        let scale = scrollView.zoomScale
        let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
        let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        scrollView.contentOffset = CGPoint(
            x: min(max(point.x * scale - scrollView.bounds.width / 2, 0), maxX),
            y: min(max(point.y * scale - scrollView.bounds.height / 2, 0), maxY)
        )
    }

    /// 枠の外を暗くし、枠を細い線で示す。アイコンは、一覧で見せる形（丸か角の丸い四角）で示す。
    private func updateMask() {
        let frame = scrollView.frame
        let hole: UIBezierPath = switch (kind, avatarShape) {
        case (.avatar, .circle): UIBezierPath(ovalIn: frame)
        case (.avatar, .roundedSquare): UIBezierPath(roundedRect: frame, cornerRadius: frame.width * 0.2)
        case (.header, _): UIBezierPath(rect: frame)
        }
        let path = UIBezierPath(rect: touchArea.bounds)
        path.append(hole)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimming.frame = touchArea.bounds
        dimming.path = path.cgPath
        outline.frame = touchArea.bounds
        outline.path = hole.cgPath
        CATransaction.commit()
    }

    private func finish() {
        let rect = crop.cropRect(imageSize: imagePixelSize, frameSize: scrollView.bounds.size, contentOffset: scrollView.contentOffset, zoomScale: scrollView.zoomScale)
        guard let cropped = image.cropping(to: rect) else {
            logger.error("profile image crop failed rect=\(String(describing: rect), privacy: .public)")
            onCancel()
            return
        }
        let output = crop.outputSize(for: rect.size)
        let hasAlpha = switch cropped.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha
        let rendered = UIGraphicsImageRenderer(size: output, format: format).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: output))
        }
        // サーバーはJPEG、PNG、GIF、WebPしか受け付けない。透過があればPNG、なければJPEGで送る。
        let encoded = hasAlpha ? rendered.pngData().map { ($0, "png", UTType.png) } : rendered.jpegData(compressionQuality: 0.9).map { ($0, "jpg", UTType.jpeg) }
        guard let (data, fileExtension, type) = encoded, let mimeType = type.preferredMIMEType else {
            logger.error("profile image encode failed")
            onCancel()
            return
        }
        logger.info("profile image cropped kind=\(self.kind.rawValue, privacy: .public) size=\(Int(output.width))x\(Int(output.height)) bytes=\(data.count)")
        onDone(MediaUpload(data: data, filename: "\(kind.rawValue).\(fileExtension)", mimeType: mimeType), rendered)
    }
}

extension ProfileImageCropViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}

extension ProfileImageCropViewController {
    /// 選んだ写真を、向きを直して読む。大きな写真は、送る大きさより十分大きい辺4096ピクセルまで縮めて展開する。
    /// 書き出し直して送るので、SDRで読む。
    nonisolated static func decode(_ data: Data) -> CGImage? {
        ImageDecoder.thumbnail(of: data, maxPixelSize: 4_096, dynamicRange: .standard)
    }
}

/// 枠の外に触れても、枠のスクロールビューで受ける。
private final class CropTouchArea: UIView {
    weak var target: UIScrollView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), let target else { return super.hitTest(point, with: event) }
        return target
    }
}

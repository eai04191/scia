import SciaCore
import UIKit

/// アカウントのアイコン。大きさは制約で決め、届くまでは同じ形の灰色で埋める。URLがなければ灰色のままにする。
/// 画像が届いても大きさは変わらないため、行の高さも変わらない。
///
/// 灰色はこのビューの背景に敷き、画像は中のビューに描く。届いた画像は、中のビューの透明度だけを上げて灰色の上に浮かび上がらせる。
/// `UIView.transition`のクロスフェードは最後に画面に描いた見た目から始まるため、使い回したセルで灰色に戻した直後に画像が届くと、
/// 灰色が一度も描かれず、前に表示していた人のアイコンから切り替わって見える。
final class AvatarView: UIView {
    struct Content: Equatable {
        /// サーバーが画像のURLを返さなかったときはnil。
        let url: URL?
        let shape: AvatarShape
        let animates: Bool
        /// 角丸の四角の、角の丸みの一辺に対する割合。
        var cornerRatio: CGFloat = 0.2
        /// 縁に細い線を引く。
        var showsBorder = true
    }

    private let store: AvatarImageStore
    private let playsAnimatedImages: () -> Bool
    private let imageView = UIImageView()
    private var content: Content?
    private(set) var loadingKey: AvatarImageStore.Key?
    private var loadTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    /// - Parameter playsAnimatedImages: 端末の設定が動く画像を許すか。`content.animates`でも、許さなければ静止画で描く。
    init(store: AvatarImageStore, playsAnimatedImages: @escaping () -> Bool = { AnimatedImagePlayback.isAllowed }) {
        self.store = store
        self.playsAnimatedImages = playsAnimatedImages
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill
        // 添付ファイルのサムネイルと同じく、明るい背景でも輪郭が分かるよう細い線を引く。
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: AvatarView, _) in
            view.layer.borderColor = UIColor.separator.resolvedColor(with: view.traitCollection).cgColor
            view.updateBorderWidth()
            view.updateImage()
        }
        observers = AnimatedImagePlayback.changeNotifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateImage() }
            }
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content?) {
        guard content != self.content else { return }
        self.content = content
        updateBorderWidth()
        setNeedsLayout()
        updateImage()
    }

    private func updateBorderWidth() {
        layer.borderWidth = content?.showsBorder == false ? 0 : 1 / max(traitCollection.displayScale, 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        layer.cornerRadius = switch content?.shape {
        case .roundedSquare: side * (content?.cornerRatio ?? 0.2)
        case .circle, nil: side / 2
        }
        updateImage()
    }

    /// 今の大きさと内容で読む画像を決める。同じ画像を読んでいる途中なら、そのまま待つ。
    private func updateImage() {
        let scale = traitCollection.displayScale
        guard let content, let url = content.url, bounds.width > 0, scale > 0 else {
            cancelLoad()
            show(nil)
            return
        }
        let key = Self.key(url: url, animates: content.animates, side: bounds.width, scale: scale, playsAnimatedImages: playsAnimatedImages())
        guard key != loadingKey else { return }
        cancelLoad()
        loadingKey = key
        if let cached = store.cachedImage(for: key) {
            show(cached)
            return
        }
        show(nil)
        loadTask = Task { [weak self, store] in
            guard let image = try? await store.image(for: key), let self, !Task.isCancelled, self.loadingKey == key else { return }
            self.show(image)
            self.imageView.alpha = 0
            // フェードの間もプロフィールを開くタップを受け付ける。
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction]) {
                self.imageView.alpha = 1
            }
        }
    }

    /// `side`ポイント四方に描くときに読む画像。行を出す前に読み込んでおくときも、描くときと同じ画像を指すよう、これで決める。
    /// - Parameter playsAnimatedImages: 端末の設定が動く画像を許すか。許さなければ、`animates`でも静止画を読む。
    static func key(
        url: URL,
        animates: Bool,
        side: CGFloat,
        scale: CGFloat,
        playsAnimatedImages: Bool = AnimatedImagePlayback.isAllowed
    ) -> AvatarImageStore.Key {
        AvatarImageStore.Key(url: url, maxPixelSize: Int((side * scale).rounded(.up)), animates: animates && playsAnimatedImages)
    }

    /// 画像をすぐに描く。読み込み中のフェードの途中なら止める。
    private func show(_ image: UIImage?) {
        imageView.layer.removeAllAnimations()
        imageView.alpha = 1
        imageView.image = image
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadingKey = nil
    }
}

/// プロフィールでは、アイコンをタップしてビューアで大きく見る。
extension AvatarView: MediaViewerSource {
    var thumbnailImage: UIImage? { imageView.image }
    var loadedThumbnail: UIImage? { imageView.image }

    var placeholderColor: UIColor? {
        backgroundColor?.resolvedColor(with: traitCollection)
    }

    func makeDecorationCopy() -> UIView {
        let container = UIView(frame: bounds)
        container.isUserInteractionEnabled = false
        return container
    }

    var isConcealedForViewer: Bool {
        get { layer.mask != nil }
        set { layer.mask = newValue ? CALayer() : nil }
    }
}

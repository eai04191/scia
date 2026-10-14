import SciaCore
import UIKit

/// アカウントのアイコン。大きさは制約で決め、届くまでは同じ形の灰色で埋める。
/// 画像が届いても大きさは変わらないため、行の高さも変わらない。
final class AvatarView: UIImageView {
    struct Content: Equatable {
        let url: URL
        let shape: AvatarShape
        let animates: Bool
    }

    private let store: AvatarImageStore
    private var content: Content?
    private var loadingKey: AvatarImageStore.Key?
    private var loadTask: Task<Void, Never>?

    init(store: AvatarImageStore) {
        self.store = store
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill
        // 添付ファイルのサムネイルと同じく、明るい背景でも輪郭が分かるよう細い線を引く。
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: AvatarView, _) in
            view.layer.borderColor = UIColor.separator.resolvedColor(with: view.traitCollection).cgColor
            view.layer.borderWidth = 1 / max(view.traitCollection.displayScale, 1)
            view.updateImage()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content?) {
        guard content != self.content else { return }
        self.content = content
        setNeedsLayout()
        updateImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        layer.cornerRadius = switch content?.shape {
        case .roundedSquare: side * 0.2
        case .circle, nil: side / 2
        }
        updateImage()
    }

    /// 今の大きさと内容で読む画像を決める。同じ画像を読んでいる途中なら、そのまま待つ。
    private func updateImage() {
        let scale = traitCollection.displayScale
        guard let content, bounds.width > 0, scale > 0 else {
            cancelLoad()
            image = nil
            return
        }
        let key = AvatarImageStore.Key(url: content.url, maxPixelSize: Int((bounds.width * scale).rounded(.up)), animates: content.animates)
        guard key != loadingKey else { return }
        cancelLoad()
        loadingKey = key
        if let cached = store.cachedImage(for: key) {
            image = cached
            return
        }
        image = nil
        loadTask = Task { [weak self, store] in
            guard let image = try? await store.image(for: key), let self, !Task.isCancelled, self.loadingKey == key else { return }
            // フェードの間もプロフィールを開くタップを受け付ける。
            UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.image = image
            }
        }
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadingKey = nil
    }
}

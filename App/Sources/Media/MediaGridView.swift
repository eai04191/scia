import SciaCore
import UIKit

/// 一覧の行に、投稿の添付ファイルのサムネイルを並べる。
///
/// 高さは添付ファイルの情報から決め、画像が届いても変えない。幅との比を制約にするのは、置く側の役目。
final class MediaGridView: UIView {
    struct Content: Equatable {
        let attachments: [MediaAttachment]
        /// 閲覧注意として覆っている。
        let isCovered: Bool
        let tallestAspectRatio: Double

        /// 全体の幅を高さで割った値。添付ファイルがなければnil。
        var aspectRatio: Double? {
            layout(width: 1).aspectRatio
        }

        func layout(width: CGFloat) -> MediaGridLayout {
            MediaGridLayout(
                aspectRatios: attachments.map(\.aspectRatio),
                width: width,
                spacing: MediaGridView.spacing,
                tallestAspectRatio: tallestAspectRatio,
                widestAspectRatio: MediaGridView.widestAspectRatio
            )
        }
    }

    nonisolated static let spacing: CGFloat = 4
    static let cornerRadius: CGFloat = 8
    /// 1つだけ出すとき、これより横長なものは左右を切り落とす。パノラマ写真が細くなりすぎないようにする。
    nonisolated static let widestAspectRatio = 3.0

    /// サムネイルがタップされたときに、何番目の添付ファイルかを渡して呼ぶ。
    var onSelect: ((Int) -> Void)?
    /// 閲覧注意の覆いがタップされたときに呼ぶ。
    var onReveal: (() -> Void)?

    private let store: MediaImageStore
    private var tiles: [MediaTileView] = []
    private lazy var cover = makeCover()
    private(set) var content: Content?

    init(store: MediaImageStore) {
        self.store = store
        super.init(frame: .zero)
        addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        let layout = content.layout(width: bounds.width)
        while tiles.count < layout.frames.count {
            let tile = MediaTileView(store: store)
            let index = tiles.count
            tile.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .primaryActionTriggered)
            insertSubview(tile, belowSubview: cover)
            tiles.append(tile)
        }
        for (index, tile) in tiles.enumerated() {
            guard index < layout.frames.count else {
                tile.isHidden = true
                tile.apply(nil, hiddenCount: 0)
                continue
            }
            tile.isHidden = false
            let isLast = index == layout.frames.count - 1
            tile.apply(content.attachments[index], hiddenCount: isLast ? layout.hiddenCount : 0)
        }
        cover.isHidden = !content.isCovered
        // 覆っている間は、中のサムネイルを読み上げない。
        tiles.forEach { $0.accessibilityElementsHidden = content.isCovered }
        setNeedsLayout()
    }

    /// 添付ファイルのサムネイル。ビューアを開くときと閉じるときに、拡大と縮小の起点にする。表示していなければnil。
    func tile(for attachmentID: MediaAttachment.ID) -> UIView? {
        guard let content, !content.isCovered, let index = content.attachments.firstIndex(where: { $0.id == attachmentID }),
              index < tiles.count, !tiles[index].isHidden, window != nil
        else { return nil }
        return tiles[index]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let content else { return }
        let layout = content.layout(width: bounds.width)
        for (tile, frame) in zip(tiles, layout.frames) {
            tile.frame = frame
        }
        cover.frame = bounds
    }

    private func makeCover() -> UIView {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        effect.layer.cornerRadius = Self.cornerRadius
        effect.layer.cornerCurve = .continuous
        effect.clipsToBounds = true
        var configuration = UIButton.Configuration.plain()
        configuration.title = "閲覧注意"
        configuration.subtitle = "タップして表示"
        configuration.image = UIImage(systemName: "eye.slash")
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.titleAlignment = .center
        configuration.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onReveal?() })
        button.frame = effect.contentView.bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effect.contentView.addSubview(button)
        return effect
    }
}

/// 添付ファイル1つ分のサムネイル。
///
/// タップ、キーボード、ポインタのどれで選ばれても`.primaryActionTriggered`で受けられるよう、`UIButton`にする。
/// `UIControl`を直接継承したものは、このイベントを送らない。
final class MediaTileView: UIButton {
    private let store: MediaImageStore
    private let thumbnailView = UIImageView()
    private let symbolView = UIImageView()
    private let altBadge = MediaTileView.makeBadge("ALT")
    private let gifBadge = MediaTileView.makeBadge("GIF")
    private let moreLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var imageURL: URL?

    init(store: MediaImageStore) {
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = MediaGridView.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = [.button, .image]

        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        symbolView.contentMode = .center
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36)
        symbolView.layer.shadowColor = UIColor.black.cgColor
        symbolView.layer.shadowRadius = 4
        symbolView.layer.shadowOffset = .zero
        moreLabel.font = .preferredFont(forTextStyle: .title1).bold
        moreLabel.textColor = .white
        moreLabel.textAlignment = .center
        moreLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        for view in [thumbnailView, symbolView, moreLabel, altBadge, gifBadge] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    func apply(_ attachment: MediaAttachment?, hiddenCount: Int) {
        let url = attachment.flatMap(Self.thumbnailURL(of:))
        if url != imageURL {
            imageURL = url
            loadTask?.cancel()
            loadTask = nil
            thumbnailView.image = url.flatMap { store.cachedImage(for: $0, maxPixelSize: MediaImageStore.thumbnailPixelSize) }
            if let url, thumbnailView.image == nil {
                loadTask = Task { [weak self, store] in
                    guard let image = try? await store.image(for: url, maxPixelSize: MediaImageStore.thumbnailPixelSize),
                          let self, !Task.isCancelled, self.imageURL == url
                    else { return }
                    UIView.transition(with: self.thumbnailView, duration: 0.15, options: .transitionCrossDissolve) {
                        self.thumbnailView.image = image
                    }
                }
            }
        }
        guard let attachment else { return }
        symbolView.image = Self.symbolName(of: attachment.type).flatMap { UIImage(systemName: $0) }
        // 画像の上に重ねるときは白く、画像のない枠の上では本文に近い色にする。
        let isOverImage = url != nil
        symbolView.tintColor = isOverImage ? .white : .secondaryLabel
        symbolView.layer.shadowOpacity = isOverImage ? 0.4 : 0
        gifBadge.isHidden = attachment.type != .gifv
        altBadge.isHidden = attachment.description?.isEmpty ?? true
        moreLabel.isHidden = hiddenCount == 0
        moreLabel.text = "+\(hiddenCount)"
        accessibilityLabel = [Self.kindName(of: attachment.type), attachment.description]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: "、")
        accessibilityValue = hiddenCount > 0 ? "ほか\(hiddenCount)件" : nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        thumbnailView.frame = bounds
        symbolView.frame = bounds
        moreLabel.frame = bounds
        let inset: CGFloat = 6
        let altSize = altBadge.intrinsicContentSize
        altBadge.frame = CGRect(x: inset, y: bounds.maxY - inset - altSize.height, width: altSize.width, height: altSize.height)
        let gifSize = gifBadge.intrinsicContentSize
        gifBadge.frame = CGRect(x: bounds.maxX - inset - gifSize.width, y: bounds.maxY - inset - gifSize.height, width: gifSize.width, height: gifSize.height)
    }

    /// 一覧に出す画像。音声と種類の分からないファイルは、プレビューのURLが画像とは限らないため読まない。
    private static func thumbnailURL(of attachment: MediaAttachment) -> URL? {
        switch attachment.type {
        case .image: attachment.previewUrl ?? attachment.url
        case .video, .gifv: attachment.previewUrl
        case .audio, .unknown: nil
        }
    }

    private static func symbolName(of kind: MediaAttachment.Kind) -> String? {
        switch kind {
        case .image, .gifv: nil
        case .video: "play.circle.fill"
        case .audio: "waveform"
        case .unknown: "doc"
        }
    }

    static func kindName(of kind: MediaAttachment.Kind) -> String {
        switch kind {
        case .image: "画像"
        case .gifv: "GIF"
        case .video: "動画"
        case .audio: "音声"
        case .unknown: "ファイル"
        }
    }

    private static func makeBadge(_ text: String) -> UILabel {
        let label = PaddedLabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption2).bold
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 4
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        return label
    }
}

/// 文字の周りに余白をとるラベル。添付ファイルの種類を示す小さな札に使う。
private final class PaddedLabel: UILabel {
    private let padding = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }
}

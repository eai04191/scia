import SciaCore
import UIKit

/// 一覧の行に、投稿の添付ファイルのサムネイルを並べる。
///
/// 高さは添付ファイルの情報から決め、画像が届いても変えない。高さの制約を張るのは、置く側の役目。
final class MediaGridView: UIView {
    /// サムネイルの並べ方。
    enum Arrangement: Equatable {
        /// 行の幅いっぱいに、添付ファイルの形に合わせて並べる。高さは幅との比で決まる。
        case grid
        /// 一辺`side`の小さな正方形を、左から1列にすべて並べる。行の幅に収まらない分は横にスクロールして見る。高さは`side`で決まる。
        case strip(side: CGFloat)
    }

    struct Content: Equatable {
        let attachments: [MediaAttachment]
        /// 閲覧注意として覆っている。
        let isCovered: Bool
        let tallestAspectRatio: Double
        let thumbnailPolicy: MediaThumbnailPolicy
        var arrangement: Arrangement = .grid

        /// 全体の幅を高さで割った値。添付ファイルがなければnil。
        var aspectRatio: Double? {
            layout(width: 1).aspectRatio
        }

        func layout(width: CGFloat) -> MediaGridLayout {
            switch arrangement {
            case .grid:
                MediaGridLayout(
                    aspectRatios: attachments.map(\.aspectRatio),
                    width: width,
                    spacing: MediaGridView.spacing,
                    tallestAspectRatio: tallestAspectRatio,
                    widestAspectRatio: MediaGridView.widestAspectRatio
                )
            case .strip(let side):
                MediaGridLayout(stripOf: attachments.count, side: side, spacing: MediaGridView.spacing)
            }
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
    /// サムネイルと覆いを載せる。1列に並べるときだけ横にスクロールでき、ほかでは自分と同じ大きさで動かない。
    private let tileContainer = RowContentScrollView()
    private var tiles: [MediaTileView] = []
    private lazy var cover = makeCover()
    private var coverButton: UIButton?
    private(set) var content: Content?

    init(store: MediaImageStore) {
        self.store = store
        super.init(frame: .zero)
        tileContainer.showsHorizontalScrollIndicator = false
        tileContainer.showsVerticalScrollIndicator = false
        tileContainer.alwaysBounceVertical = false
        tileContainer.contentInsetAdjustmentBehavior = .never
        // ステータスバーのタップで先頭へ戻る対象は一覧だけにする。画面に対象が複数あると、UIKitはどれも動かさない。
        tileContainer.scrollsToTop = false
        addSubview(tileContainer)
        tileContainer.addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content) {
        guard content != self.content else { return }
        // 別の投稿のサムネイルに入れ替わったら、横のスクロールを先頭に戻す。覆いを外しただけなら、見ている位置を保つ。
        if content.attachments.map(\.id) != self.content?.attachments.map(\.id) {
            tileContainer.contentOffset = .zero
        }
        self.content = content
        let layout = content.layout(width: bounds.width)
        while tiles.count < layout.frames.count {
            let tile = MediaTileView(store: store)
            let index = tiles.count
            tile.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .primaryActionTriggered)
            tileContainer.insertSubview(tile, belowSubview: cover)
            tiles.append(tile)
        }
        for (index, tile) in tiles.enumerated() {
            guard index < layout.frames.count else {
                tile.isHidden = true
                tile.apply(nil, hiddenCount: 0, isCovered: false, policy: content.thumbnailPolicy)
                continue
            }
            tile.isHidden = false
            let isLast = index == layout.frames.count - 1
            tile.apply(
                content.attachments[index],
                hiddenCount: isLast ? layout.hiddenCount : 0,
                isCovered: content.isCovered,
                policy: content.thumbnailPolicy
            )
        }
        cover.isHidden = !content.isCovered
        updateCoverButton(for: content.arrangement)
        // 覆っている間は、中のサムネイルを読み上げない。
        tiles.forEach { $0.accessibilityElementsHidden = content.isCovered }
        setNeedsLayout()
    }

    /// 添付ファイルのサムネイル。ビューアを開くときと閉じるときに、拡大と縮小の起点にする。表示していなければnil。
    /// 1列に並べていて、横のスクロールで行の外に出ているときは、見える位置までスクロールしてから返す。
    /// ビューアでめくった先の画像へ閉じるとき、行の外へ縮んで消えないようにするため。
    func tile(for attachmentID: MediaAttachment.ID) -> MediaTileView? {
        guard let content, !content.isCovered, let index = content.attachments.firstIndex(where: { $0.id == attachmentID }),
              index < tiles.count, !tiles[index].isHidden, window != nil
        else { return nil }
        let tile = tiles[index]
        if case .strip = content.arrangement {
            tileContainer.layoutIfNeeded()
            tileContainer.scrollRectToVisible(tile.frame, animated: false)
        }
        return tile
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let content else { return }
        let layout = content.layout(width: bounds.width)
        for (tile, frame) in zip(tiles, layout.frames) {
            tile.frame = frame
        }
        tileContainer.frame = bounds
        switch content.arrangement {
        case .grid:
            tileContainer.isScrollEnabled = false
            tileContainer.contentSize = bounds.size
            cover.frame = bounds
        case .strip:
            // 1列に並べるときは、行の幅いっぱいではなく、並べたサムネイルだけを覆う。
            let tilesFrame = layout.frames.reduce(CGRect.null) { $0.union($1) }
            tileContainer.isScrollEnabled = tilesFrame.width > bounds.width
            tileContainer.contentSize = CGSize(width: max(tilesFrame.maxX, bounds.width), height: bounds.height)
            cover.frame = tilesFrame
        }
    }

    /// 小さなサムネイルには文字が入りきらないため、1列に並べるときは記号だけを出す。
    private func updateCoverButton(for arrangement: Arrangement) {
        guard let coverButton, var configuration = coverButton.configuration else { return }
        switch arrangement {
        case .grid:
            configuration.title = "閲覧注意"
            configuration.subtitle = "タップして表示"
        case .strip:
            configuration.title = nil
            configuration.subtitle = nil
        }
        coverButton.configuration = configuration
        coverButton.accessibilityLabel = "閲覧注意、タップして表示"
    }

    private func makeCover() -> UIView {
        // 下のサムネイルは、覆っている間は画像を読まずにblurhashで描くため、色が透けて見える薄い素材にする。
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
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
        coverButton = button
        return effect
    }
}

/// 一覧の行の中で、横にだけスクロールする入れ物。行の一部なので、ビューアが開閉の動きで一覧と行を探すときは飛ばす。
final class RowContentScrollView: UIScrollView {}

/// 添付ファイル1つ分のサムネイル。
///
/// タップ、キーボード、ポインタのどれで選ばれても`.primaryActionTriggered`で受けられるよう、`UIButton`にする。
/// `UIControl`を直接継承したものは、このイベントを送らない。
final class MediaTileView: UIButton, MediaViewerSource {
    private let store: MediaImageStore
    private let thumbnailView = UIImageView()
    private let symbolView = UIImageView()
    private let altBadge = MediaTileView.makeBadge("ALT")
    private let gifBadge = MediaTileView.makeBadge("GIF")
    private let moreLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var attachment: MediaAttachment?
    private var isCovered = false
    private var policy: MediaThumbnailPolicy?
    /// いま描いている画像の出どころ。同じなら描き直さない。
    private var source: Source?
    /// 動画やGIFのように、ビューアではサムネイルと違うコマを描く添付ファイル。
    private var showsMovingImage = false

    private struct Source: Equatable {
        let attachmentID: MediaAttachment.ID
        /// 読み込む画像。閲覧注意で覆っている間と、枠の大きさが決まる前はnilにし、通信しない。
        let request: MediaThumbnailRequest?
        let blurhash: String?
        /// blurhashを展開する縦横比。同じblurhashでも、比が違えば描き直す。
        let aspectRatio: Double?
    }

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
        // 読む画像の大きさは画面の倍率で決まるため、別の画面へ移ったら選び直す。
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 描いているサムネイル。ビューアの開閉で、まだ画像を描いていないページの代わりに動かす。
    var thumbnailImage: UIImage? { thumbnailView.image }

    /// 読み込んだサムネイル。blurhashのぼかしは含まない。ビューアで元の画像が届くまでの下地にする。
    private(set) var loadedThumbnail: UIImage?

    /// 画像の奥に敷いている背景の色。透明な部分のある画像では、この色が透けて見える。
    var placeholderColor: UIColor? {
        backgroundColor?.resolvedColor(with: traitCollection)
    }

    /// 画像の上に重ねている印（ALT、GIF、動画の再生マーク、残りの枚数）の複製。ビューアが動かす画像の複製に載せて、サムネイルとのあいだを一緒に動かす。
    /// 動画とGIFではサムネイルの画像も含める。ビューアの複製は再生していたコマを描くため、印と一緒にサムネイルへ近づくほど濃くし、着地で絵が切り替わらないようにする。
    /// 画像では含めない。複製とサムネイルが同じ絵で、重ねると透明な部分が濃く見えるため。
    /// 複製の大きさが変わっても、サムネイルと同じ角からの位置を保つ。ラベルは画像にし、全体を覆う残りの枚数と中央の再生マークは、伸び縮みしないよう作り直す。
    func makeDecorationCopy() -> UIView {
        let container = UIView(frame: bounds)
        container.isUserInteractionEnabled = false
        if showsMovingImage, let thumbnail = thumbnailView.image {
            let copy = UIImageView(image: thumbnail)
            copy.frame = bounds
            copy.contentMode = thumbnailView.contentMode
            copy.clipsToBounds = true
            copy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(copy)
        }
        let corners: [(UIView, UIView.AutoresizingMask)] = [
            (altBadge, [.flexibleRightMargin, .flexibleTopMargin]),
            (gifBadge, [.flexibleLeftMargin, .flexibleTopMargin]),
        ]
        for (badge, mask) in corners where !badge.isHidden {
            let format = UIGraphicsImageRendererFormat()
            format.scale = traitCollection.displayScale
            let image = UIGraphicsImageRenderer(bounds: badge.bounds, format: format).image { context in
                badge.layer.render(in: context.cgContext)
            }
            let copy = UIImageView(image: image)
            copy.frame = badge.frame
            copy.autoresizingMask = mask
            container.addSubview(copy)
        }
        if let symbol = symbolView.image {
            let copy = UIImageView(image: symbol)
            copy.frame = bounds
            copy.contentMode = symbolView.contentMode
            copy.preferredSymbolConfiguration = symbolView.preferredSymbolConfiguration
            copy.tintColor = symbolView.tintColor
            copy.layer.shadowColor = symbolView.layer.shadowColor
            copy.layer.shadowRadius = symbolView.layer.shadowRadius
            copy.layer.shadowOffset = symbolView.layer.shadowOffset
            copy.layer.shadowOpacity = symbolView.layer.shadowOpacity
            copy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(copy)
        }
        if !moreLabel.isHidden {
            let copy = UILabel(frame: bounds)
            copy.text = moreLabel.text
            copy.font = moreLabel.font
            copy.textColor = moreLabel.textColor
            copy.textAlignment = moreLabel.textAlignment
            copy.backgroundColor = moreLabel.backgroundColor
            copy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(copy)
        }
        return container
    }

    /// ビューアがこのサムネイルとのあいだで画像を動かしている間、見えなくする。
    /// 透明にすると触れても反応しなくなり、閉じる途中にタップし直しても開けないため、空のマスクで隠す。
    var isConcealedForViewer = false {
        didSet { layer.mask = isConcealedForViewer ? CALayer() : nil }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    /// 閲覧注意で覆っている間は画像を読まず、blurhashのぼかしだけを描く。覆いを外さない投稿で通信しないようにする。
    /// 覆っていなければ、読み込むまでblurhashを下地にし、届いたら差し替える。
    /// どの画像を読むかは枠の大きさで決まるため、大きさが決まる`layoutSubviews`で選ぶ。
    func apply(_ attachment: MediaAttachment?, hiddenCount: Int, isCovered: Bool, policy: MediaThumbnailPolicy) {
        self.attachment = attachment
        self.isCovered = isCovered
        self.policy = policy
        showsMovingImage = attachment?.type == .video || attachment?.type == .gifv
        setNeedsLayout()
        guard let attachment else { return }
        symbolView.image = Self.symbolName(of: attachment.type).flatMap { UIImage(systemName: $0) }
        // 画像の上に重ねるときは白く、画像のない枠の上では本文に近い色にする。
        let isOverImage = (!isCovered && Self.hasThumbnail(attachment)) || attachment.blurhash != nil
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
    }

    /// 投稿欄で選んだ手元のメディアを描く。サーバーから読まず、投稿欄で作ったサムネイルをそのまま出す。
    /// 手元のGIFはビューアでも最初のコマを画像として見せるため、動画だけをサムネイルと違うコマを描くものとして扱う。
    /// - Parameter kind: 種類。ファイルを読み込む前で分からなければnilで、読み上げでは「メディア」にする。
    func applyLocal(thumbnail: UIImage?, kind: MediaAttachment.Kind?, description: String) {
        loadTask?.cancel()
        loadTask = nil
        attachment = nil
        source = nil
        showsMovingImage = kind == .video
        loadedThumbnail = thumbnail
        thumbnailView.image = thumbnail
        symbolView.image = kind.flatMap(Self.symbolName(of:)).flatMap { UIImage(systemName: $0) }
        symbolView.tintColor = .white
        symbolView.layer.shadowOpacity = 0.4
        gifBadge.isHidden = kind != .gifv
        altBadge.isHidden = description.isEmpty
        moreLabel.isHidden = true
        accessibilityLabel = [kind.map(Self.kindName(of:)) ?? "メディア", description].filter { !$0.isEmpty }.joined(separator: "、")
        accessibilityValue = nil
        setNeedsLayout()
    }

    /// 枠の大きさと条件から読む画像を選び、変わっていれば読み直す。
    private func updateSource() {
        let source = attachment.map { attachment in
            Source(
                attachmentID: attachment.id,
                request: thumbnailRequest(for: attachment),
                blurhash: attachment.blurhash,
                aspectRatio: attachment.aspectRatio
            )
        }
        guard source != self.source else { return }
        // 同じ添付ファイルを大きさや条件を変えて読み直すときは、届くまで今の画像を残し、ぼかしに戻さない。
        let keepsCurrentImage = loadedThumbnail != nil && source?.request != nil && source?.attachmentID == self.source?.attachmentID
        self.source = source
        showImage(of: attachment, from: source, keepsCurrentImage: keepsCurrentImage)
    }

    private func thumbnailRequest(for attachment: MediaAttachment) -> MediaThumbnailRequest? {
        let scale = traitCollection.displayScale
        guard !isCovered, let policy, !bounds.isEmpty, scale > 0 else { return nil }
        return MediaThumbnailSelection.request(for: attachment, tileSize: bounds.size, displayScale: scale, policy: policy)
    }

    private func showImage(of attachment: MediaAttachment?, from source: Source?, keepsCurrentImage: Bool) {
        loadTask?.cancel()
        loadTask = nil
        if !keepsCurrentImage {
            loadedThumbnail = nil
            thumbnailView.image = attachment.flatMap { attachment in
                attachment.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: attachment.aspectRatio) }
            }
        }
        guard let request = source?.request else { return }
        if let cached = store.cachedImage(for: request.url, maxPixelSize: request.maxPixelSize) {
            loadedThumbnail = cached
            thumbnailView.image = cached
            return
        }
        loadTask = Task { [weak self, store] in
            guard let image = try? await store.image(for: request.url, maxPixelSize: request.maxPixelSize),
                  let self, !Task.isCancelled, self.source?.request == request
            else { return }
            self.loadedThumbnail = image
            UIView.transition(with: self.thumbnailView, duration: 0.15, options: .transitionCrossDissolve) {
                self.thumbnailView.image = image
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSource()
        thumbnailView.frame = bounds
        symbolView.frame = bounds
        moreLabel.frame = bounds
        let inset: CGFloat = 6
        let altSize = altBadge.intrinsicContentSize
        altBadge.frame = CGRect(x: inset, y: bounds.maxY - inset - altSize.height, width: altSize.width, height: altSize.height)
        let gifSize = gifBadge.intrinsicContentSize
        gifBadge.frame = CGRect(x: bounds.maxX - inset - gifSize.width, y: bounds.maxY - inset - gifSize.height, width: gifSize.width, height: gifSize.height)
    }

    /// 一覧に画像を出せるか。音声と種類の分からないファイルは、プレビューのURLが画像とは限らないため読まない。
    private static func hasThumbnail(_ attachment: MediaAttachment) -> Bool {
        switch attachment.type {
        case .image: attachment.previewUrl != nil || attachment.url != nil
        case .video, .gifv: attachment.previewUrl != nil
        case .audio, .unknown: false
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

    static func makeBadge(_ text: String) -> UILabel {
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

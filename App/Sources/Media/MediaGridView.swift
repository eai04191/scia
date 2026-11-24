import SciaCore
import UIKit

/// タイムラインの行に、投稿の添付ファイルのサムネイルを並べる。
///
/// 高さは添付ファイルの情報から決め、画像が届いても変えない。高さの制約を張るのは、置く側の役目。
final class MediaGridView: UIView {
    /// サムネイルの並べ方。
    enum Arrangement: Equatable {
        /// 行の幅いっぱいに、添付ファイルの形に合わせて並べる。高さは幅との比で決まる。
        case grid
        /// 一辺`side`の小さな正方形を、左から1列にすべて並べる。行の幅に収まらない分は横にスクロールして見る。高さは`side`で決まる。
        case strip(side: CGFloat)
        /// 一辺`side`の正方形の中に、紙焼きの写真に見立てて重ねる。本文の右に小さく出すときに使う。重ね方は`MediaPhotoStackView`にある。
        case stack(side: CGFloat)
    }

    struct Content: Equatable {
        let attachments: [MediaAttachment]
        /// ぼかしていればその理由。
        let cover: MediaCover?
        let tallestAspectRatio: Double
        let thumbnailPolicy: MediaThumbnailPolicy
        /// サムネイル同士のすき間。
        var spacing: CGFloat
        var arrangement: Arrangement = .grid
        /// 1つだけ出すとき、これより横長なものは左右を切り落とす。
        var widestAspectRatio = MediaGridView.widestAspectRatio
        /// 代替テキストやGIFなどを示すバッジを出す。
        var showsBadges = true
        /// 重ねるときに、置き方を投稿ごとにばらつかせる種。投稿のID。nilならばらつかせない。
        var stackSeed: String?
        /// 重ねるときに、写真を傾ける。falseなら、どの写真もまっすぐに置く。
        var tiltsStack = true

        var isCovered: Bool { cover != nil }

        var isStacked: Bool {
            if case .stack = arrangement { true } else { false }
        }

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
                    spacing: spacing,
                    tallestAspectRatio: tallestAspectRatio,
                    widestAspectRatio: widestAspectRatio
                )
            case .strip(let side):
                MediaGridLayout(stripOf: attachments.count, side: side, spacing: spacing)
            case .stack(let side):
                MediaGridLayout(squareOf: attachments.count, side: side)
            }
        }
    }

    static let cornerRadius: CGFloat = 8
    /// 1つだけ出すとき、これより横長なものは左右を切り落とす。パノラマ写真が細くなりすぎないようにする。
    nonisolated static let widestAspectRatio = 3.0

    /// サムネイルがタップされたときに、何番目の添付ファイルかを渡して呼ぶ。
    var onSelect: ((Int) -> Void)?
    /// ぼかしがタップされたときに呼ぶ。
    var onReveal: (() -> Void)?

    private let store: MediaImageStore<UIImage>
    /// サムネイルとぼかしを載せる。1列に並べるときだけ横にスクロールでき、ほかでは自分と同じ大きさで動かない。
    private let tileContainer = RowContentScrollView()
    private var tiles: [MediaTileView] = []
    /// 閲覧注意のぼかし。ぼかしの素材と設定付きのボタンを作るのは重く、タイムラインの行はどれも添付ファイルの欄を持つため、初めてぼかすときに作る。
    private var cover: UIView?
    private var coverButton: UIButton?
    /// 本文の右に重ねて出す写真。サムネイルを並べる入れ物とは別に、初めて重ねるときに作る。
    private var photoStack: MediaPhotoStackView?
    private(set) var content: Content?

    init(store: MediaImageStore<UIImage>) {
        self.store = store
        super.init(frame: .zero)
        tileContainer.showsHorizontalScrollIndicator = false
        tileContainer.showsVerticalScrollIndicator = false
        tileContainer.alwaysBounceVertical = false
        tileContainer.contentInsetAdjustmentBehavior = .never
        // ステータスバーのタップで先頭へ戻る対象はタイムラインだけにする。画面に対象が複数あると、UIKitはどれも動かさない。
        tileContainer.scrollsToTop = false
        addSubview(tileContainer)
        // ぼかしの題の境界線は文字の大きさに合わせて作るので、文字の大きさの設定が変わったら入れ直す。
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            if let content = self.content, content.isCovered {
                self.updateCoverButton(for: content)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content) {
        guard content != self.content else { return }
        // 別の投稿のサムネイルに入れ替わったら、横のスクロールを先頭に戻す。ぼかしを外しただけなら、見ている位置を保つ。
        if content.attachments.map(\.id) != self.content?.attachments.map(\.id) {
            tileContainer.contentOffset = .zero
        }
        self.content = content
        if content.isStacked {
            tileContainer.isHidden = true
            loadedPhotoStack().isHidden = false
            photoStack?.apply(content, coverAccessibilityLabel: PostTexts.mediaCoverAccessibilityLabel(content.cover))
            setNeedsLayout()
            return
        }
        photoStack?.isHidden = true
        tileContainer.isHidden = false
        let layout = content.layout(width: bounds.width)
        while tiles.count < layout.frames.count {
            let tile = MediaTileView(store: store)
            let index = tiles.count
            tile.onOpen = { [weak self] in self?.onSelect?(index) }
            tile.addAction(UIAction { [weak tile] _ in tile?.tapped() }, for: .primaryActionTriggered)
            if let cover {
                tileContainer.insertSubview(tile, belowSubview: cover)
            } else {
                tileContainer.addSubview(tile)
            }
            tiles.append(tile)
        }
        for (index, tile) in tiles.enumerated() {
            guard index < layout.frames.count else {
                tile.isHidden = true
                tile.apply(nil, hiddenCount: 0, isCovered: false, policy: content.thumbnailPolicy)
                continue
            }
            tile.isHidden = false
            tile.hidesBadge = !content.showsBadges
            let isLast = index == layout.frames.count - 1
            tile.apply(
                content.attachments[index],
                hiddenCount: isLast ? layout.hiddenCount : 0,
                isCovered: content.isCovered,
                policy: content.thumbnailPolicy
            )
        }
        if content.isCovered {
            loadedCover().isHidden = false
            updateCoverButton(for: content)
        } else {
            cover?.isHidden = true
        }
        // ぼかしている間は、中のサムネイルを読み上げない。
        tiles.forEach { $0.accessibilityElementsHidden = content.isCovered }
        setNeedsLayout()
    }

    /// 添付ファイルのサムネイル。ビューアを開くときと閉じるときに、拡大と縮小の起点にする。表示していなければnil。
    /// 1列に並べていて、横のスクロールで行の外に出ているときは、見える位置までスクロールしてから返す。
    /// ビューアでめくった先の画像へ閉じるとき、行の外へ縮んで消えないようにするため。
    /// 重ねているときは、その添付ファイルの写真を返す。4枚目より後ろは、3枚目の写真の位置にあるものとして、3枚目の写真を返す。
    func tile(for attachmentID: MediaAttachment.ID) -> MediaTileView? {
        if let content, content.isStacked {
            guard !content.isCovered, let index = content.attachments.firstIndex(where: { $0.id == attachmentID }), window != nil else { return nil }
            return photoStack?.tile(at: index)
        }
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

    /// 表示中のサムネイルの枠。「投稿の見た目」のプレビューで、サムネイル同士のすき間を示すときに使う。
    func tilePreviewFrames(in space: UIView) -> [CGRect] {
        tiles.compactMap { $0.previewFrame(in: space) }.flatMap(\.self)
    }

    /// 表示中のサムネイルのバッジの枠。消していれば、バッジがあった位置。
    /// 重ねているときは、手前の写真のバッジだけ。
    func badgePreviewFrames(in space: UIView) -> [CGRect] {
        if content?.isStacked == true {
            return (photoStack?.frontTile.badgePreviewFrame(in: space)).map { [$0] } ?? []
        }
        return tiles.compactMap { $0.badgePreviewFrame(in: space) }
    }

    private func loadedPhotoStack() -> MediaPhotoStackView {
        if let photoStack { return photoStack }
        let stack = MediaPhotoStackView(store: store)
        stack.frontTile.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.content?.isCovered == true {
                self.onReveal?()
            } else {
                self.onSelect?(0)
            }
        }, for: .primaryActionTriggered)
        stack.onReveal = { [weak self] in self?.onReveal?() }
        addSubview(stack)
        photoStack = stack
        return stack
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let content else { return }
        if content.isStacked {
            photoStack?.frame = bounds
            return
        }
        let layout = content.layout(width: bounds.width)
        for (tile, frame) in zip(tiles, layout.frames) {
            tile.frame = frame
        }
        tileContainer.frame = bounds
        switch content.arrangement {
        case .grid:
            tileContainer.isScrollEnabled = false
            tileContainer.contentSize = bounds.size
            cover?.frame = bounds
        case .stack:
            break
        case .strip:
            // 1列に並べるときは、行の幅いっぱいではなく、並べたサムネイルだけをぼかす。
            let tilesFrame = layout.frames.reduce(CGRect.null) { $0.union($1) }
            tileContainer.isScrollEnabled = tilesFrame.width > bounds.width
            tileContainer.contentSize = CGSize(width: max(tilesFrame.maxX, bounds.width), height: bounds.height)
            cover?.frame = tilesFrame
        }
    }

    /// 小さなサムネイルには文字が入りきらないため、1列に並べるときは記号だけを出す。
    private func updateCoverButton(for content: Content) {
        guard let coverButton, var configuration = coverButton.configuration else { return }
        let title = MediaCover.title(of: content.cover)
        switch content.arrangement {
        case .grid:
            configuration.title = title
            if case .filtered(let titles) = content.cover {
                // 一致したフィルターの名前は、境界線で区切って並べる。線の大きさを文字に合わせるため、文字の大きさを決めて入れる。
                let warning = PostTexts.filterWarning(titles: titles)
                let font = UIFont.preferredFont(forTextStyle: .body)
                configuration.attributedTitle = AttributedString(ListSeparator.attributedString(warning.text, separators: warning.separators, font: font, attributes: [:]))
            }
            configuration.subtitle = PostTexts.mediaCoverHint
        case .strip, .stack:
            configuration.title = nil
            configuration.subtitle = nil
        }
        coverButton.configuration = configuration
        coverButton.accessibilityLabel = PostTexts.mediaCoverAccessibilityLabel(content.cover)
    }

    private func loadedCover() -> UIView {
        if let cover { return cover }
        let view = makeCover()
        tileContainer.addSubview(view)
        cover = view
        return view
    }

    private func makeCover() -> UIView {
        // 下のサムネイルは、ぼかしている間は画像を読まずにblurhashで描くため、色が透けて見える薄い素材にする。
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        effect.layer.cornerRadius = Self.cornerRadius
        effect.layer.cornerCurve = .continuous
        effect.clipsToBounds = true
        var configuration = UIButton.Configuration.plain()
        configuration.title = MediaCover.title(of: nil)
        configuration.subtitle = PostTexts.mediaCoverHint
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

/// タイムラインの行の中で、横にだけスクロールする入れ物。行の一部なので、ビューアが開閉の動きでタイムラインと行を探すときは飛ばす。
final class RowContentScrollView: UIScrollView {}

/// 添付ファイル1つ分のサムネイル。
///
/// タップ、キーボード、ポインタのどれで選ばれても`.primaryActionTriggered`で受けられるよう、`UIButton`にする。
/// `UIControl`を直接継承したものは、このイベントを送らない。
final class MediaTileView: UIButton, MediaViewerSource {
    /// ビューアで開く。タップに選んだ操作によらず、メニューの「開く」と持ち上げた画像のタップでも、これで開く。
    var onOpen: (() -> Void)?
    private let store: MediaImageStore<UIImage>
    /// 窓に開いたアカウントの設定。タイルは投稿の本文の中で何段も親から作られるので、窓から読む。
    private var settings: AppSettings { traitCollection.appSettings }
    private var dynamicRangeGeneration = 0
    private let tuning: TuningStore
    private let thumbnailView = FocusCroppedImageView()
    private let decorationView = MediaTileDecorationView()
    private var loadTask: Task<Void, Never>?
    private var attachment: MediaAttachment?
    /// メディアのメニュー。サムネイルはボタンで、タイムラインの行のコンテキストメニューが届かないため、自分で受ける。
    private var menuInteraction: MediaMenuInteraction?
    private var isCovered = false
    private var policy: MediaThumbnailPolicy?
    /// いま描いている画像の取得元。同じなら描き直さない。
    private var source: Source?
    /// 画像を読みに行く取得元を選んでいるか。閲覧注意でぼかしている間は選ばず、読みに行かない。
    var requestsThumbnail: Bool { source?.request != nil }
    /// 動画やGIFのように、ビューアではサムネイルと違うコマを描く添付ファイル。
    private var showsMovingImage = false

    private struct Source: Equatable {
        let attachmentID: MediaAttachment.ID
        /// 読み込む画像。閲覧注意でぼかしている間と、枠の大きさが決まる前はnilにし、通信しない。
        let request: MediaThumbnailRequest?
        /// ぼかしている間に、外したらすぐ出せるよう先に読んでおく画像。描かずにキャッシュへ入れるだけ。Wi-Fiでだけ読む。
        let prefetchRequest: MediaThumbnailRequest?
        let blurhash: String?
        /// blurhashを展開する縦横比。同じblurhashでも、比が違えば描き直す。
        let aspectRatio: Double?
    }

    init(store: MediaImageStore<UIImage>, tuning: TuningStore = AppDependencies.tuning) {
        self.store = store
        self.tuning = tuning
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = MediaGridView.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = [.button, .image]

        thumbnailView.isUserInteractionEnabled = false
        addSubview(thumbnailView)
        addSubview(decorationView)
        // 読む画像の大きさは画面の倍率で決まるため、別の画面へ移ったら選び直す。
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
        followDynamicRanges()
        registerForTraitChanges([AppSettingsTrait.self]) { (self: Self, _) in
            self.followDynamicRanges()
        }
        followSymbolSizing()
        menuInteraction = MediaMenuInteraction(on: self, wholeImage: { [weak self] in self?.loadedThumbnail }, open: { [weak self] in
            self?.onOpen?()
        }, sharperImage: { [weak self] maxPixelSize in
            // 動画とGIFのサムネイルはコマの画像で、元のファイルは画像として読めないため、読み直さない。
            guard let self, let attachment = self.menuAttachment, attachment.type == .image, let url = attachment.url ?? attachment.remoteUrl else { return nil }
            return try? await self.store.image(for: url, maxPixelSize: maxPixelSize, retriesNow: true, purpose: .action)
        }, offersMenu: { [weak self] _ in self?.menuAttachment != nil })
    }

    /// タップに選んだ操作を行う。既定（開く）は、今のタップの処理のまま開く。決まりはdocs/object-actions.mdにある。
    func tapped() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard !ObjectEntity.media.performsPrimary(.tap, settings: settings), let menuInteraction, menuInteraction.buildsMenu else {
            onOpen?()
            return
        }
        menuInteraction.target(at: center)?.perform(.tap, in: self, at: center)
    }

    /// HDRのバッジを出す明るさの組み合わせかを、設定から決め続ける。選び直すと、出ているバッジにもすぐ効かせる。
    /// 窓の設定が替わったら、替わる前の設定の見張りは世代で止める。止めないと、見張りの系列が替わるたびに増えるため。
    private func followDynamicRanges() {
        dynamicRangeGeneration += 1
        followDynamicRanges(of: settings, generation: dynamicRangeGeneration)
    }

    private func followDynamicRanges(of settings: AppSettings, generation: Int) {
        guard generation == dynamicRangeGeneration else { return }
        withObservationTracking {
            marksHDR = MediaDynamicRange.marksHDR(list: settings.mediaDynamicRange, viewer: settings.viewerMediaDynamicRange)
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                self?.followDynamicRanges(of: settings, generation: generation)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// アイコンの大きさのチューニングを読み続ける。変えたら、出ているタイルのアイコンも描き直す。
    private func followSymbolSizing() {
        withObservationTracking {
            decorationView.sizing = MediaTileSymbolSizing(tuning: tuning)
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                self?.followSymbolSizing()
            }
        }
    }

    /// 描いているサムネイル。ビューアの開閉で、まだ画像を描いていないページの代わりに動かす。
    var thumbnailImage: UIImage? { thumbnailView.image }

    var thumbnailFocus: MediaFocus? { thumbnailView.focus }

    /// 読み込んだサムネイル。blurhashのぼかしは含まない。ビューアで元の画像が届くまでの下地にする。
    private(set) var loadedThumbnail: UIImage? {
        didSet { updateDecoration() }
    }

    /// 画像の奥に敷いている背景の色。透明な部分のある画像では、この色が透けて見える。
    var placeholderColor: UIColor? {
        backgroundColor?.resolvedColor(with: traitCollection)
    }

    /// 画像の上に重ねている表示と、それを並べた大きさ。開閉で動かす複製に、同じ表示を同じ部品で描かせる。
    var decorationLayout: MediaTileDecorationLayout {
        MediaTileDecorationLayout(decoration: decorationView.decoration, sizing: decorationView.sizing, size: bounds.size)
    }

    /// 画像の上に重ねている表示（ALTやGIFのバッジ、動画の再生マーク、残りの枚数）の複製。ビューアが動かす画像の複製に載せて、サムネイルとのあいだを一緒に動かす。
    /// 動画とGIFではサムネイルの画像も含める。ビューアの複製は再生していたコマを描くため、重ねた表示と一緒にサムネイルへ近づくほど濃くし、着地で絵が切り替わらないようにする。
    /// 画像では含めない。複製とサムネイルが同じ絵で、重ねると透明な部分が濃く見えるため。
    func makeDecorationCopy() -> UIView {
        let container = UIView(frame: bounds)
        container.isUserInteractionEnabled = false
        if showsMovingImage, let thumbnail = thumbnailView.image {
            let copy = FocusCroppedImageView(frame: bounds)
            copy.image = thumbnail
            copy.focus = thumbnailView.focus
            copy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(copy)
        }
        let decoration = MediaTileDecorationView(frozen: decorationLayout)
        decoration.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(decoration)
        return container
    }

    /// バッジに出すラベル。
    private var marks: [MediaBadgeView.Mark] = [] {
        didSet { updateDecoration() }
    }

    /// バッジを出さない。投稿欄で、バッジの位置に代替テキストの送信の状態を出している間に使う。
    var hidesBadge = false {
        didSet { updateDecoration() }
    }

    /// 開くとタイムラインより明るくなる設定か。サムネイルがHDRなら、HDRのバッジを出す。
    private var marksHDR = false {
        didSet { updateDecoration() }
    }

    /// 動画の再生アイコンを出す。
    private var showsPlay = false
    /// 中央に出す記号。
    private var symbol: MediaTileDecoration.Symbol?
    /// 残りの枚数。
    private var hiddenCount = 0

    /// 読み上げに使う、添付ファイルの種類と代替テキスト。
    private var accessibilityParts: (kind: String, description: String?) = ("", nil)

    /// サムネイルはサーバーが作るので、サーバーがHDRの情報を消したメディアでは、HDRでもfalseになる。
    private var isHDRThumbnail: Bool { loadedThumbnail?.isHighDynamicRange ?? false }

    private func updateDecoration() {
        let showsHDR = marksHDR && isHDRThumbnail
        // 消していても大きさと位置は決めておき、「投稿の見た目」のプレビューで、バッジがあった位置を示せるようにする。
        decorationView.decoration = MediaTileDecoration(
            showsPlay: showsPlay,
            badgeMarks: marks + (showsHDR ? [.hdr] : []),
            showsBadge: !hidesBadge,
            symbol: symbol,
            hiddenCount: hiddenCount
        )
        accessibilityLabel = [accessibilityParts.kind, showsHDR ? "HDR" : nil, accessibilityParts.description]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joinedAsTextList
    }

    /// バッジの枠。消していれば、バッジがあった位置。付けるラベルがなければnil。
    func badgePreviewFrame(in space: UIView) -> CGRect? {
        guard !isHidden else { return nil }
        return decorationView.badgePreviewFrame(in: space)
    }

    /// ビューアがこのサムネイルとのあいだで画像を動かしている間、見えなくする。
    /// 透明にすると触れても反応しなくなり、閉じる途中にタップし直しても開けないため、空のマスクで隠す。
    var isConcealedForViewer = false {
        didSet {
            layer.mask = isConcealedForViewer ? CALayer() : nil
            onConcealedForViewerChange?(isConcealedForViewer)
        }
    }

    /// 隠したときと出したときに呼ぶ。タイムラインで重ねた写真が、サムネイルだけでなく写真のフチごと隠すのに使う。
    var onConcealedForViewerChange: ((Bool) -> Void)?

    /// 上に重なっているビュー。タイムラインで重ねた奥の写真では、それより手前の写真。
    var overlappingViews: [UIView] = []

    /// 見え方。タイムラインで重ねた写真の中のサムネイルでは、その写真のフチ、中身を描くかと暗さ、スタックの影の濃さ。
    var viewerLook = MediaViewerSourceLook.plain

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    /// タイムラインで重ねた写真の3枚目のサムネイルのように、ほかの添付ファイルを開いたときも開閉の起点にする。
    /// そのときだけ、描いている添付ファイルかを確かめる。ほかでは、ビューアが探すID（投稿欄では下書きの添付のID）と描いている添付ファイルのIDが一致しないことがあり、いつもその添付ファイルを描いている。
    var standsInForOtherAttachments = false

    func showsAttachment(_ id: MediaAttachment.ID) -> Bool {
        !standsInForOtherAttachments || attachment?.id == id
    }

    /// 閲覧注意でぼかしている間は画像を読まず、blurhashのぼかしだけを描く。ぼかしを外さない投稿で通信しないようにする。
    /// ぼかしていなければ、読み込むまでblurhashを下地にし、届いたら差し替える。
    /// どの画像を読むかは枠の大きさで決まるため、大きさが決まる`layoutSubviews`で選ぶ。
    /// 長押しでメディアのメニューを出す添付ファイル。ぼかしている間と、何も出していないときはnil。
    var menuAttachment: MediaAttachment? {
        isCovered || isHidden ? nil : attachment
    }

    func apply(_ attachment: MediaAttachment?, hiddenCount: Int, isCovered: Bool, policy: MediaThumbnailPolicy) {
        self.attachment = attachment
        self.isCovered = isCovered
        self.policy = policy
        showsMovingImage = attachment?.type == .video || attachment?.type == .gifv
        thumbnailView.focus = attachment?.meta?.focus
        setNeedsLayout()
        guard let attachment else { return }
        let isOverImage = (!isCovered && Self.hasThumbnail(attachment)) || attachment.blurhash != nil
        symbol = Self.symbolName(of: attachment.type).map { MediaTileDecoration.Symbol(name: $0, isOverImage: isOverImage) }
        showsPlay = attachment.type == .video
        self.hiddenCount = hiddenCount
        accessibilityParts = (attachment.type.displayName, attachment.description)
        marks = MediaBadgeView.marks(hasDescription: !(attachment.description?.isEmpty ?? true), kind: attachment.type)
        updateDecoration()
        accessibilityValue = hiddenCount > 0 ? PostTexts.hiddenMediaCount(hiddenCount) : nil
    }

    /// 投稿欄で選んだ手元のメディアを描く。サーバーから取得せず、投稿欄で作ったサムネイルをそのまま出す。
    /// 手元のGIFはビューアでも最初のコマを画像として見せるため、動画だけをサムネイルと違うコマを描くものとして扱う。
    /// - Parameter kind: 種類。ファイルを読み込む前で分からなければnilで、読み上げでは「メディア」にする。
    func applyLocal(thumbnail: UIImage?, kind: MediaAttachment.Kind?, description: String) {
        loadTask?.cancel()
        loadTask = nil
        attachment = nil
        source = nil
        showsMovingImage = kind == .video
        thumbnailView.focus = nil
        loadedThumbnail = thumbnail
        thumbnailView.image = thumbnail
        symbol = kind.flatMap(Self.symbolName(of:)).map { MediaTileDecoration.Symbol(name: $0, isOverImage: true) }
        showsPlay = kind == .video
        hiddenCount = 0
        accessibilityParts = (kind.map(\.displayName) ?? PostTexts.unknownMediaKind, description)
        marks = MediaBadgeView.marks(hasDescription: !description.isEmpty, kind: kind)
        updateDecoration()
        accessibilityValue = nil
        setNeedsLayout()
    }

    /// 枠の大きさと条件から読む画像を選び、変わっていれば読み直す。
    private func updateSource() {
        let source = attachment.map { attachment in
            Source(
                attachmentID: attachment.id,
                request: thumbnailRequest(for: attachment),
                prefetchRequest: coveredPrefetchRequest(for: attachment),
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

    /// ぼかしている間に先読みする画像。外したときに読むのと同じものを、先読みの目的で読む（docs/timeline-media.mdの「状態の表示」）。
    private func coveredPrefetchRequest(for attachment: MediaAttachment) -> MediaThumbnailRequest? {
        let scale = traitCollection.displayScale
        guard isCovered, let policy, let purpose = policy.prefetch, !bounds.isEmpty, scale > 0 else { return nil }
        return MediaThumbnailSelection.request(for: attachment, tileSize: bounds.size, displayScale: scale, policy: policy)?.sent(as: purpose)
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
        if let prefetch = source?.prefetchRequest, store.cachedThumbnail(for: prefetch) == nil {
            loadTask = Task(.prefetch) { [store] in
                _ = try? await store.thumbnail(for: prefetch)
            }
        }
        guard let request = source?.request else { return }
        if let cached = store.cachedThumbnail(for: request) {
            loadedThumbnail = cached
            thumbnailView.image = cached
            return
        }
        loadTask = Task(.display) { [weak self, store] in
            guard let image = await store.shownThumbnail(for: request, while: { [weak self] in self?.source?.request == request }, visible: { [weak self] in self?.isInVisibleHierarchy ?? false }),
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
        decorationView.frame = bounds
    }

    /// タイムラインに画像を出せるか。音声と種類の分からないファイルは、プレビューのURLが画像とは限らないため読まない。
    private static func hasThumbnail(_ attachment: MediaAttachment) -> Bool {
        switch attachment.type {
        case .image: attachment.previewUrl != nil || attachment.url != nil
        case .video, .gifv: attachment.previewUrl != nil
        case .audio, .unknown: false
        }
    }

    private static func symbolName(of kind: MediaAttachment.Kind) -> String? {
        switch kind {
        case .image, .gifv, .video: nil
        case .audio: "waveform"
        case .unknown: "doc"
        }
    }
}

/// 添付ファイルのラベル（ALT、GIF、HDR）を1つにまとめたバッジ。タイルの左下に置く。
/// タイルの大きさは並べ方で変わり、ラベルごとにバッジを置くと狭いタイルに入らないため、1つにまとめ、幅に入らなければ頭の1文字にする。
/// ラベルごとの下地を細い隙間で離してつなげ、つなぎ目の角は立て、外側の角だけを丸める。区切りに線を描くより、1つのバッジが区切られて見えるため。
final class MediaBadgeView: UIView {
    enum Mark: CaseIterable {
        case alt
        case gif
        case hdr

        var title: String {
            switch self {
            case .alt: "ALT"
            case .gif: "GIF"
            case .hdr: "HDR"
            }
        }

        var shortTitle: String { String(title.prefix(1)) }
    }

    /// バッジの文字の大きさの上限。文字の大きさの設定に合わせて大きくするが、いちばん狭いタイルでも1文字のバッジが入るよう、ここで止める。
    static let maximumContentSizeCategory = UIContentSizeCategory.extraExtraLarge
    private static let padding = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
    /// 頭の1文字にしたときの左右の余白の範囲。狭いタイルでもすべてのラベルを出せるよう、入るまで最大から最小へ詰める。
    private static let shortHorizontalPaddings: ClosedRange<CGFloat> = 1...3
    /// 余白を詰めても入らないとき、文字を小さくする下限。これより小さくすると読めないので、入らない分は切れる。
    private static let minimumFontSize: CGFloat = 6
    /// ラベルとラベルのあいだの隙間。
    private static let gap: CGFloat = 1
    static let cornerRadius: CGFloat = 4
    /// バッジの下地。画像の明るさによらず白い文字が読めるよう、黒を透かす。
    static let backgroundColor = UIColor.black.withAlphaComponent(0.6)

    /// 出すラベル。空ならバッジを隠す。
    var marks: [Mark] = [] {
        didSet {
            isHidden = marks.isEmpty
            rebuildSegments()
            setNeedsLayout()
        }
    }

    private var segments: [UILabel] = []
    /// いまの幅に入れるために選んだ、ラベルの書き方と左右の余白と文字。
    private var fit = Fit(shortened: false, horizontalPadding: padding.left, font: .preferredFont(forTextStyle: .caption2))

    private struct Fit {
        let shortened: Bool
        let horizontalPadding: CGFloat
        let font: UIFont
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 当てはまるラベルを、ALT、GIFの順に並べる。
    static func marks(hasDescription: Bool, kind: MediaAttachment.Kind?) -> [Mark] {
        var marks: [Mark] = []
        if hasDescription {
            marks.append(.alt)
        }
        if kind == .gifv {
            marks.append(.gif)
        }
        return marks
    }

    /// `size.width`に入る形を選んで大きさを返し、その形で描き直す。できるだけすべてのラベルを出すため、次の順に詰める。
    /// 1. ラベルの名前で並べる
    /// 2. 頭の1文字にし、左右の余白を最大から最小へ詰める
    /// 3. 最小の余白でも入らなければ、文字を下限まで小さくする。下限でも入らない分は切れる
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        fit = Self.fit(marks: marks, width: size.width, font: Self.font(for: traitCollection))
        for (segment, mark) in zip(segments, marks) {
            segment.font = fit.font
            segment.text = fit.shortened ? mark.shortTitle : mark.title
        }
        return Self.size(of: titles(for: fit), font: fit.font, horizontalPadding: fit.horizontalPadding)
    }

    private func titles(for fit: Fit) -> [String] {
        marks.map { fit.shortened ? $0.shortTitle : $0.title }
    }

    private static func fit(marks: [Mark], width: CGFloat, font: UIFont) -> Fit {
        let full = Fit(shortened: false, horizontalPadding: padding.left, font: font)
        if size(of: marks.map(\.title), font: font, horizontalPadding: full.horizontalPadding).width <= width {
            return full
        }
        let titles = marks.map(\.shortTitle)
        for padding in stride(from: shortHorizontalPaddings.upperBound, through: shortHorizontalPaddings.lowerBound, by: -1) where size(of: titles, font: font, horizontalPadding: padding).width <= width {
            return Fit(shortened: true, horizontalPadding: padding, font: font)
        }
        // 余白を最小にしたうえで、文字の幅が残りに収まる大きさにする。文字の幅は大きさにほぼ比例する。
        let padding = shortHorizontalPaddings.lowerBound
        let textWidth = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.reduce(0, +)
        let room = width - padding * 2 * CGFloat(titles.count) - gap * CGFloat(max(titles.count - 1, 0))
        let scale = textWidth > 0 ? room / textWidth : 1
        // 切り上げで1ptほどはみ出すことがあるため、少し小さめにする。
        let fontSize = max(floor(font.pointSize * min(scale, 1) * 10 - 1) / 10, minimumFontSize)
        return Fit(shortened: true, horizontalPadding: padding, font: font.withSize(fontSize))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        let horizontalPadding = fit.horizontalPadding
        for segment in segments {
            let width = Self.segmentWidth(of: segment.text ?? "", font: segment.font, horizontalPadding: horizontalPadding)
            segment.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Self.gap
        }
    }

    private func rebuildSegments() {
        segments.forEach { $0.removeFromSuperview() }
        segments = marks.indices.map { index in
            let segment = UILabel()
            segment.textColor = .white
            segment.textAlignment = .center
            segment.backgroundColor = Self.backgroundColor
            segment.layer.cornerRadius = Self.cornerRadius
            segment.layer.cornerCurve = .continuous
            segment.clipsToBounds = true
            var corners: CACornerMask = []
            if index == 0 {
                corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner])
            }
            if index == marks.count - 1 {
                corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
            }
            segment.layer.maskedCorners = corners
            addSubview(segment)
            return segment
        }
    }

    static func font(for traits: UITraitCollection) -> UIFont {
        let category = min(traits.preferredContentSizeCategory, maximumContentSizeCategory)
        return UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).bold
    }

    private static func segmentWidth(of title: String, font: UIFont, horizontalPadding: CGFloat) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + horizontalPadding * 2
    }

    private static func size(of titles: [String], font: UIFont, horizontalPadding: CGFloat) -> CGSize {
        let widths = titles.map { segmentWidth(of: $0, font: font, horizontalPadding: horizontalPadding) }
        let width = widths.reduce(0, +) + gap * CGFloat(max(titles.count - 1, 0))
        return CGSize(width: width, height: ceil(font.lineHeight) + padding.top + padding.bottom)
    }
}

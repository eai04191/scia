import NaturalLanguage
import SciaCore
import UIKit

/// 投稿のリンクカード。左にサムネイル、右にサイトの名前、見出し、説明を1行ずつ並べる。見せ方は`docs/link-card.md`。
/// 画像のないカードにはサムネイルの枠を出さず、文字を左端から並べる。リンク先だけのカードには、リンクの記号を入れた枠を出す。
///
/// 高さは文字の大きさだけで決め、中身によらない。サーバーのカードが後から届いて、リンク先だけのカードから描き直しても、行の高さを変えないため。
/// 届いたカードに画像がなければ、枠を縮めて消し、文字を左へ寄せる動きでつなぐ。
/// 閲覧注意の投稿では、添付ファイルと同じく、画像を読まずにblurhashで描いてぼかし、押されたらぼかしを外すよう置く側に知らせる。
/// タップ、キーボード、ポインタのどれで選ばれても`.primaryActionTriggered`で受けられるよう、`UIButton`にする。
final class LinkCardView: UIButton {
    struct Content: Equatable {
        var card: LinkCard
        /// 文字の、枠とサムネイルからの余白。
        var padding: CGFloat
        /// リンク先だけのカードに、サーバーのカードが届いたときの、差し替えの時間。
        var transitionDuration: TimeInterval
        /// サムネイルを置く端。
        var thumbnailSide: LinkCardThumbnailSide
        var typography: PostTypography
        /// 一番上にサイト名の行を出す。
        var showsSite = true
        /// 画像を出す。出さなければ、画像のあるカードも文字だけで描く。
        var showsImage = true
        /// 説明の行数。0なら説明を出さない。
        var descriptionLines = 1
        /// サイト名、タイトル、説明の行どうしのあいだ。
        var lineSpacing: CGFloat = 2
        /// タイトルの行数。
        var titleLines = 1
        /// タイトルを太字にする。URLを出しているときは、この設定にかかわらず太字にしない。
        var boldsTitle = true
        /// 画像の幅の上限の、カードの幅に対する割合。
        var imageWidthRatio: CGFloat = 0.3
        /// 画像を閲覧注意でぼかす。画像のないカードとリンク先だけのカードでは、ぼかす画像がないため使わない。
        var coversImage = false

        /// サムネイルの枠を出す。画像のあるカードと、まだカードの届いていないリンク先だけのカード。
        var showsThumbnail: Bool {
            guard showsImage else { return false }
            return switch card {
            case .card(let card): card.image != nil
            case .link: true
            }
        }
    }

    private let store: MediaImageStore<UIImage>
    private let thumbnailView = LinkCardThumbnailView()
    /// 画像を長押ししたときのメディアのメニュー。カードはボタンで、一覧の行の長押しのメニューが届かないため、画像が自分で受ける。
    private var imageMenuInteraction: MediaMenuInteraction?
    /// サムネイルの画像がタップされたときに、ビューアを開閉する起点として、サムネイルを渡して呼ぶ。
    /// 画像を読み込み終えたカードでだけ受け付け、それ以外の場所や画像のないカードのタップは、リンクを開く。
    var onOpenImage: ((LinkCardThumbnailView) -> Void)?
    /// 閲覧注意でぼかした画像がタップされたときに呼ぶ。ぼかしを外すのは置く側で、適用し直すまで見た目は変わらない。リンクは開かない。
    var onRevealImage: (() -> Void)?
    /// 閲覧注意のぼかし。ぼかしの素材を作るのは重く、一覧の行はどれもリンクカードを持つため、初めてぼかすときに作る。
    private var coverView: UIView?
    private let symbolView = UIImageView(image: UIImage(systemName: "link"))
    private let siteLabel = UILabel()
    private let headlineLabel = UILabel()
    private let descriptionLabel = UILabel()
    private(set) var content: Content?
    private var loadTask: Task<Void, Never>?
    /// いま描いているサムネイルの取得元。同じなら読み直さない。
    private var request: Request?
    /// 並べ方で、サムネイルの枠を出すか。枠を縮めて消す動きを始めるまでは、中身と食い違う。
    private var laysOutThumbnail = false

    private struct Request: Equatable {
        let url: URL
        let maxPixelSize: Int
        /// 閲覧注意でぼかしている。ぼかしている間は読まず、blurhashのぼかしだけを描く。
        let isCovered: Bool
    }

    init(store: MediaImageStore<UIImage>) {
        self.store = store
        super.init(frame: .zero)
        layer.cornerRadius = MediaGridView.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .link

        thumbnailView.backgroundColor = .secondarySystemFill
        thumbnailView.layer.cornerRadius = MediaGridView.cornerRadius
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped)))
        imageMenuInteraction = MediaMenuInteraction(on: thumbnailView, wholeImage: { [weak self] in self?.thumbnailView.loadedThumbnail }, open: { [weak self] in
            self?.openImageFromMenu()
        }, sharperImage: { [weak self] maxPixelSize in
            guard let self, let url = self.thumbnailView.imageURL else { return nil }
            return try? await self.store.image(for: url, maxPixelSize: maxPixelSize, retriesNow: true)
        }, offersMenu: { [weak self] _ in self?.menuImage != nil })
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        symbolView.contentMode = .center
        symbolView.tintColor = .secondaryLabel
        siteLabel.textColor = .secondaryLabel
        descriptionLabel.textColor = .secondaryLabel
        for label in [siteLabel, headlineLabel, descriptionLabel] {
            label.lineBreakMode = .byTruncatingTail
        }
        for view in [thumbnailView, symbolView, siteLabel, headlineLabel, descriptionLabel] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        accessibilityCustomActions = []
        updateFonts()
        updateBorderColor()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.updateFonts()
            self.invalidateIntrinsicContentSize()
            self.setNeedsLayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitDisplayScale.self]) { (self: Self, _) in
            self.updateBorderColor()
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content) {
        guard content != self.content else { return }
        let previous = self.content
        let paddingChanged = content.padding != previous?.padding || content.typography != previous?.typography
            || content.showsSite != previous?.showsSite || content.showsImage != previous?.showsImage
            || content.titleLines != previous?.titleLines || content.imageWidthRatio != previous?.imageWidthRatio || content.descriptionLines != previous?.descriptionLines || content.lineSpacing != previous?.lineSpacing
        self.content = content
        let animates = Self.isCardArrival(from: previous?.card, to: content.card) && window != nil && content.transitionDuration > 0
            && !UIAccessibility.isReduceMotionEnabled
        let text = Self.text(of: content.card)
        if !animates {
            showText(of: content)
        }
        accessibilityLabel = ["リンク", text.titleIsURL ? nil : text.title, text.site].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "、")
        if paddingChanged {
            invalidateIntrinsicContentSize()
        }
        holdsThumbnailForArrival = animates
        updateThumbnail()
        setNeedsLayout()
        guard animates else {
            laysOutThumbnail = content.showsThumbnail
            return
        }
        // 一覧は動きを止めて描き直し（animatingDifferences: false）、その中ではUIView.animateが動かないため、描き直しを終えてから動かす。
        // サムネイルも、それまで前の中身のまま残し、動きの中で入れ替える。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.content == content else { return }
            self.holdsThumbnailForArrival = false
            self.animateArrival(of: content)
        }
    }

    /// サーバーのカードが届いた。画像がなければ枠を縮めて消し、文字を左へ寄せる。動きは標準のスプリングで、1回で入れ替える。
    /// 文字が変わる行は、古い文字の像を重ねて、新しい文字と一緒に動かしながら入れ替える。像を置かずに入れ替えると、
    /// 古い文字が元の位置に残ったまま、寄ってくる新しい文字と重なって見えるため。ドメインのように変わらない行は、そのまま動かす。
    private func animateArrival(of content: Content) {
        let text = Self.text(of: content.card)
        let changed = [(siteLabel, text.site), (headlineLabel, text.title), (descriptionLabel, text.description)]
            .filter { label, string in label.text != string }
            .map(\.0)
        removeTransitionSnapshots()
        let snapshots = changed.compactMap { label -> (UILabel, UIView)? in
            guard let snapshot = label.snapshotView(afterScreenUpdates: false) else { return nil }
            snapshot.frame = label.frame
            snapshot.isUserInteractionEnabled = false
            addSubview(snapshot)
            return (label, snapshot)
        }
        transitionSnapshots = snapshots.map(\.1)
        setText(of: content)
        for label in changed { label.alpha = 0 }
        let duration = content.transitionDuration
        // リンクの記号から画像（届くまではblurhashのぼかし）への入れ替えも、新しい文字と同じ時間で薄くして行う。
        updateThumbnail(crossfadeDuration: duration * 0.6)
        let options: UIView.AnimationOptions = [.allowUserInteraction, .beginFromCurrentState]
        UIView.animate(springDuration: duration, bounce: 0, options: options) {
            self.laysOutThumbnail = content.showsThumbnail
            self.setNeedsLayout()
            self.layoutIfNeeded()
            for (label, snapshot) in snapshots {
                // 像は古い文字の大きさのまま、新しい文字の左上に合わせて動かす。
                snapshot.frame.origin = label.frame.origin
            }
        }
        // 濃さは位置と別に、古い文字を先に薄くし、新しい文字を少し遅れて濃くする。同時に入れ替えると、
        // スプリングの出だしで両方が濃いまま重なり、読めない文字が数コマ出るため。
        // 新しい文字は直前に濃さを0にしたばかりで、画面上はまだ濃いため、今の見た目からは始めない。
        // 像は、薄くし終えてから外す。位置の動きの完了で外すと、サムネイルの枠が変わらないカードでは位置の動きが何も動かさず、
        // 完了がすぐ呼ばれて、古い文字が1コマで消えるため。
        UIView.animateSmoothly(duration: duration * 0.4) {
            for (_, snapshot) in snapshots { snapshot.alpha = 0 }
        } completion: {
            self.removeTransitionSnapshots(snapshots.map(\.1))
        }
        UIView.animateSmoothly(duration: duration * 0.6, delay: duration * 0.2) {
            for label in changed { label.alpha = 1 }
        }
    }

    /// 入れ替えの途中で重ねている、古い文字の像とリンクの記号の複製。
    private var transitionSnapshots: [UIView] = []

    private func removeTransitionSnapshots(_ snapshots: [UIView]? = nil) {
        let removing = snapshots ?? transitionSnapshots
        for snapshot in removing { snapshot.removeFromSuperview() }
        transitionSnapshots.removeAll { removing.contains($0) }
    }

    /// 閲覧注意でぼかした画像を押すと、ぼかしを外す。
    /// サムネイルの画像を開けるのは、読み込み終えた画像を出しているとき。ぼかしの下地のうちは、大きくして見るものがないため、リンクを開く。
    private func updateImageInteraction() {
        if isCoveringImage {
            thumbnailView.isUserInteractionEnabled = true
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: "閲覧注意の画像を表示") { [weak self] _ in
                self?.onRevealImage?()
                return true
            }]
            return
        }
        let opensImage = thumbnailView.loadedThumbnail != nil && thumbnailView.imageURL == request?.url
        thumbnailView.isUserInteractionEnabled = opensImage
        accessibilityCustomActions = opensImage
            ? [UIAccessibilityCustomAction(name: "画像を開く") { [weak self] _ in
                self?.openImage()
                return true
            }]
            : []
    }

    /// 長押しでメディアのメニューを出す画像。画像を開ける状態のときだけ返し、ぼかしている間と読み込む前はnil。
    var menuImage: (attachment: MediaAttachment, thumbnail: LinkCardThumbnailView)? {
        guard !isCoveringImage, thumbnailView.isUserInteractionEnabled, let content, case .card(let card) = content.card,
              let attachment = card.imageAttachment
        else { return nil }
        return (attachment, thumbnailView)
    }

    /// メディアのメニューの「開く」。タップしたときと同じく開く。
    func openImageFromMenu() {
        openImage()
    }

    /// 閲覧注意でぼかしている画像がある。
    private var isCoveringImage: Bool {
        guard let content, content.coversImage, content.showsImage, case .card(let card) = content.card else { return false }
        return card.image != nil
    }

    /// 画像のタップに選んだ操作を行う。ぼかしていればぼかしを外し、既定（開く）なら今のタップの処理のまま開く。決まりはdocs/object-actions.mdにある。
    @objc private func imageTapped(_ gesture: UITapGestureRecognizer) {
        guard !isCoveringImage, !ObjectEntity.media.performsPrimary(.tap), let imageMenuInteraction else {
            openImage()
            return
        }
        let point = gesture.location(in: thumbnailView)
        imageMenuInteraction.target(at: point)?.perform(.tap, in: thumbnailView, at: point)
    }

    private func openImage() {
        if isCoveringImage {
            onRevealImage?()
        } else {
            onOpenImage?(thumbnailView)
        }
    }

    private func loadedCoverView() -> UIView {
        if let coverView { return coverView }
        let cover = Self.makeCover()
        cover.frame = thumbnailView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        thumbnailView.addSubview(cover)
        coverView = cover
        return cover
    }

    /// 閲覧注意のぼかし。下のサムネイルは画像を読まずにblurhashで描くため、添付ファイルのぼかしと同じく、色が透けて見える薄い素材にする。
    /// サムネイルには文字が入りきらないため、添付ファイルを1列に並べるときと同じく、記号だけを出す。押されたらサムネイルが受ける。
    private static func makeCover() -> UIView {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        effect.isUserInteractionEnabled = false
        let symbol = UIImageView(image: UIImage(systemName: "eye.slash"))
        symbol.tintColor = .secondaryLabel
        symbol.contentMode = .center
        symbol.frame = effect.contentView.bounds
        symbol.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effect.contentView.addSubview(symbol)
        return effect
    }

    /// 文字を、動きを止めて、すぐに出す。カードが届いた動きの途中で、セルが別の投稿に使い回されたときも、
    /// 前の投稿の枠や文字の動きが新しい中身に重ならないよう、ここで止める。
    private func showText(of content: Content) {
        removeTransitionSnapshots()
        removeIncomingThumbnail()
        for view in [thumbnailView, symbolView] {
            view.layer.removeAllAnimations()
        }
        for label in [siteLabel, headlineLabel, descriptionLabel] {
            label.layer.removeAllAnimations()
            // 届いたときの動きで濃くしている途中なら、その動きも止める。止めないと、使い回した行の新しい文字が薄い状態から濃くなる。
            label.stopFading(at: 1)
        }
        setText(of: content)
    }

    private func setText(of content: Content) {
        let text = Self.text(of: content.card)
        for (label, string) in [(siteLabel, text.site), (headlineLabel, text.title), (descriptionLabel, text.description)] {
            label.text = string
            label.textAlignment = Self.alignment(of: string)
        }
        headlineLabel.textColor = text.titleIsURL ? .secondaryLabel : .label
        updateFonts()
    }

    /// 文字を、その言語の書く方向に寄せる。サムネイルの位置にも、アプリの言語の方向にもよらない。
    /// リンク先のページの言語はサーバーから分からないため、文字から推し量る。
    private static func alignment(of string: String) -> NSTextAlignment {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: string) else { return .left }
        return Locale.Language(identifier: language.rawValue).characterDirection == .rightToLeft ? .right : .left
    }

    /// 同じリンクの、リンク先だけのカードに、サーバーのカードが届いた。
    private static func isCardArrival(from previous: LinkCard?, to card: LinkCard) -> Bool {
        guard case .link(let url)? = previous, case .card = card else { return false }
        return card.url == url
    }

    /// サイトの名前、見出し、説明の文字。サーバーのカードがまだなければ、リンク先のドメインとURLを出す。
    static func text(of card: LinkCard) -> (site: String, title: String, titleIsURL: Bool, description: String) {
        let host = card.url.host(percentEncoded: false) ?? ""
        let address = Self.addressText(of: card.url)
        switch card {
        case .card(let card):
            let site = card.providerName.isEmpty ? host : card.providerName
            return card.title.isEmpty
                ? (site, address, true, card.description)
                : (site, card.title, false, card.description)
        case .link:
            return (host, address, true, "")
        }
    }

    /// スキームを除いたURL。
    private static func addressText(of url: URL) -> String {
        let string = url.absoluteString
        for prefix in ["https://", "http://"] where string.hasPrefix(prefix) {
            return String(string.dropFirst(prefix.count))
        }
        return string
    }

    /// カードを受け取る前は文字を描かないので、大きさは既定の文字で見積もる。
    private var typography: PostTypography { content?.typography ?? .standard }
    private var siteFont: UIFont { typography.font(.linkCardDetail, compatibleWith: traitCollection) }
    /// 見出しの行の高さを決める文字。見出しの代わりにURLを出すときは、太字にせず控えめにする。
    private var titleFont: UIFont { typography.font(.linkCardTitle, compatibleWith: traitCollection) }
    /// 縦に並べる文字の行と、それぞれの文字と行数。出さない行は含めない。
    private var textRows: [(label: UILabel, font: UIFont, lines: Int)] {
        let descriptionLines = content?.descriptionLines ?? 1
        return [
            content?.showsSite == false ? nil : (siteLabel, siteFont, 1),
            (headlineLabel, titleFont, max(content?.titleLines ?? 1, 1)),
            descriptionLines > 0 ? (descriptionLabel, siteFont, descriptionLines) : nil,
        ].compactMap(\.self)
    }

    /// 文字の行を並べた高さ。説明が短くて行数より少なくても、カードの高さを揃えるため、決めた行数ぶんを取る。
    private var textHeight: CGFloat {
        let rows = textRows
        let spacing = content?.lineSpacing ?? 0
        return rows.reduce(0) { $0 + Self.blockHeight(font: $1.font, lines: $1.lines) } + spacing * CGFloat(max(rows.count - 1, 0))
    }

    /// `lines`行ぶんの文字の高さ。1行は書体の行の高さで取る。
    /// 2行以上は、日本語を含めて実際に折り返したときの高さで測る。日本語の代わりの書体は行が高く、書体の行の高さを行数倍した枠には1行しか入らないため。
    private static func blockHeight(font: UIFont, lines: Int) -> CGFloat {
        guard lines > 1 else { return font.lineHeight }
        let sample = Array(repeating: "あA", count: lines).joined(separator: "\n") as NSString
        return ceil(sample.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil).height)
    }

    /// テストで、説明が描く行を確かめるためのラベル。
    var descriptionLabelForTesting: UILabel? {
        descriptionLabel.isHidden ? nil : descriptionLabel
    }

    /// 見出しと、サイト名と説明の枠。「投稿の見た目」のプレビューで場所を示すときに使う。
    func textPreviewFrames(in space: UIView) -> AppearancePreviewFrames {
        var frames: AppearancePreviewFrames = [:]
        frames[.cardTitle] = headlineLabel.previewFrame(in: space)
        frames[.cardImage] = thumbnailWidth > 0 ? thumbnailView.previewFrame(in: space) : nil
        frames[.cardDescription] = descriptionLabel.previewFrame(in: space)
        frames[.cardSite] = siteLabel.previewFrame(in: space)
        let detail = [siteLabel, descriptionLabel].compactMap { $0.previewFrame(in: space) }.flatMap(\.self)
        if !detail.isEmpty {
            frames[.cardDetail] = detail
        }
        let rows = textRows.compactMap { $0.label.previewFrame(in: space)?.first }
        if rows.count > 1 {
            frames[.cardLineGaps] = AppearanceHighlight.gaps(between: rows)
        }
        let thickness = AppearanceHighlight.minimumGapThickness
        let card = convert(bounds, to: space)
        let thumbnailOnRight = content?.thumbnailSide == .right
        if thumbnailWidth > 0 {
            frames[.cardImageSlot] = [convert(thumbnailView.frame, to: space)]
        } else if content?.showsImage == false, case .card(let preview)? = content?.card, preview.image != nil {
            // 画像を出さない設定では、画像があった端を示す。
            frames[.cardImageSlot] = [CGRect(x: thumbnailOnRight ? card.maxX - thickness : card.minX, y: card.minY, width: thickness, height: card.height)]
        }
        if let site = siteLabel.previewFrame(in: space), !siteLabel.isHidden {
            frames[.cardSiteSlot] = site
        } else if content?.showsSite == false, let first = rows.first {
            frames[.cardSiteSlot] = [CGRect(x: first.minX, y: first.minY - thickness, width: first.width, height: thickness)]
        }
        // 文字の側の、枠とサムネイルからの余白。
        let textSide = CGRect(x: thumbnailOnRight ? card.minX : card.minX + thumbnailWidth, y: card.minY, width: card.width - thumbnailWidth, height: card.height)
        frames[.cardPaddingBands] = AppearanceHighlight.paddingBands(of: textSide, padding: content?.padding ?? 0)
        return frames
    }

    private func updateFonts() {
        siteLabel.isHidden = content?.showsSite == false
        descriptionLabel.isHidden = (content?.descriptionLines ?? 1) == 0
        descriptionLabel.numberOfLines = max(content?.descriptionLines ?? 1, 1)
        headlineLabel.numberOfLines = max(content?.titleLines ?? 1, 1)
        siteLabel.font = siteFont
        let showsURL = content.map { Self.text(of: $0.card).titleIsURL } ?? false
        headlineLabel.font = showsURL || content?.boldsTitle == false ? titleFont : titleFont.bold
        descriptionLabel.font = siteFont
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    }

    /// サムネイルの幅。カードの高さと同じ正方形にする。文字を大きくしてカードが高くなっても、文字の幅を残すため、カードの幅に対する設定の割合（`imageWidthRatio`）までにする。
    /// 枠を出さないカードでは0。
    private var thumbnailWidth: CGFloat {
        guard laysOutThumbnail else { return 0 }
        return min(bounds.height, floor(bounds.width * (content?.imageWidthRatio ?? 0.3)))
    }

    /// 文字の3行と余白から決まる高さ。
    private var cardHeight: CGFloat {
        let padding = content?.padding ?? 0
        return ceil(padding * 2 + textHeight)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: cardHeight)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .systemFill : nil }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let thumbnailOnRight = content?.thumbnailSide == .right
        thumbnailView.frame = CGRect(x: thumbnailOnRight ? bounds.width - thumbnailWidth : 0, y: 0, width: thumbnailWidth, height: bounds.height)
        // カードの外側の角だけを丸め、文字の側は角を立てる。ビューアは、この丸みに合わせて画像を縮めて戻す。
        thumbnailView.layer.maskedCorners = thumbnailOnRight
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        // 記号は枠と一緒に押し潰さず、枠の中央で、枠を縮めて消すあいだに小さくしながら薄くする。
        let hidesThumbnail = thumbnailWidth == 0
        symbolView.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.height)
        symbolView.center = CGPoint(x: thumbnailView.frame.midX, y: thumbnailView.frame.midY)
        symbolView.transform = hidesThumbnail ? CGAffineTransform(scaleX: 0.5, y: 0.5) : .identity
        thumbnailView.alpha = hidesThumbnail ? 0 : 1
        symbolView.alpha = hidesThumbnail ? 0 : 1
        let padding = content?.padding ?? 0
        let textX = (thumbnailOnRight ? 0 : thumbnailWidth) + padding
        let textWidth = max(bounds.width - thumbnailWidth - padding * 2, 0)
        var y = (bounds.height - textHeight) / 2
        for (label, font, lines) in textRows {
            // 行数より短い説明は、上に詰めて置く。UILabelは枠の上下中央に描くため、枠を文字の高さに合わせる。
            let block = Self.blockHeight(font: font, lines: lines)
            let fitted = label.textRect(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude), limitedToNumberOfLines: lines).height
            label.frame = CGRect(x: textX, y: y, width: textWidth, height: ceil(max(min(block, fitted), font.lineHeight)))
            y += block + (content?.lineSpacing ?? 0)
        }
        updateThumbnail()
    }

    /// カードが届いた動きを始めるまで、サムネイルを前の中身のまま残す。描き直しの中で入れ替えると、動かせずに1コマで替わるため。
    private var holdsThumbnailForArrival = false

    /// サムネイルを、枠の大きさに合わせて読む。サムネイルのないカードとリンク先だけのカードには、リンクの記号を出す。
    /// - Parameter crossfadeDuration: カードが届いたときに、記号やぼかしの下地をこの時間で薄くして入れ替える。nilならすぐ入れ替える。
    private func updateThumbnail(crossfadeDuration: TimeInterval? = nil) {
        guard !holdsThumbnailForArrival else { return }
        // 画像を出さない設定では、画像を読まず、画像を開く操作も置かない。
        let card: PreviewCard? = if content?.showsImage != false, case .card(let card) = content?.card { card } else { nil }
        let scale = traitCollection.displayScale
        let covers = isCoveringImage
        if covers {
            loadedCoverView().isHidden = false
        } else {
            coverView?.isHidden = true
        }
        let request: Request? = if let image = card?.image, bounds.height > 0, scale > 0 {
            Request(url: image, maxPixelSize: Int(ceil(max(bounds.height, thumbnailWidth) * scale)), isCovered: covers)
        } else {
            nil
        }
        let hidesSymbol = card?.image != nil
        if let crossfadeDuration, hidesSymbol, !symbolView.isHidden {
            fadeOutSymbol(duration: crossfadeDuration)
        }
        symbolView.isHidden = hidesSymbol
        guard request != self.request else {
            updateImageInteraction()
            return
        }
        // ぼかしを掛けるときも外すときも、読み込んだ画像を残さず、ぼかしから描き直す。
        let keepsImage = request != nil && request?.url == self.request?.url && request?.isCovered == false && self.request?.isCovered == false
        self.request = request
        loadTask?.cancel()
        loadTask = nil
        if !keepsImage {
            let placeholder = card?.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: bounds.height > 0 ? thumbnailWidth / bounds.height : 1) }
            crossfadeThumbnail(duration: crossfadeDuration) { $0.showPlaceholder(placeholder) }
        }
        updateImageInteraction()
        // ぼかしている間は画像を読まない。ぼかしを外さない投稿で通信しないようにする。
        guard let request, !request.isCovered else { return }
        if let cached = store.cachedImage(for: request.url, maxPixelSize: request.maxPixelSize) {
            crossfadeThumbnail(duration: crossfadeDuration) { $0.showLoaded(cached, from: request.url) }
            updateImageInteraction()
            return
        }
        loadTask = Task { [weak self, store] in
            guard let image = try? await store.image(for: request.url, maxPixelSize: request.maxPixelSize),
                  let self, !Task.isCancelled, self.request == request
            else { return }
            if let incoming = self.incomingThumbnail {
                // 下地を濃くしている途中に届いたら、重ねている方で入れ替え、サムネイルそのものは前の見え方のまま残す。
                let base = self.thumbnailView.image
                self.thumbnailView.showLoaded(image, from: request.url)
                self.thumbnailView.image = base
                UIView.transition(with: incoming, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    incoming.image = image
                }
            } else {
                UIView.transition(with: self.thumbnailView, duration: 0.15, options: .transitionCrossDissolve) {
                    self.thumbnailView.showLoaded(image, from: request.url)
                }
            }
            self.updateImageInteraction()
        }
    }

    /// サムネイルの見え方を入れ替える。`duration`があれば、新しい見え方をサムネイルの中に重ねて濃くし、濃くし終えてから入れ替える。
    /// 前の見え方を上に重ねて薄くする形にしないのは、灰色の下地が半透明で、下の新しい画像が透けて1コマで替わって見えるため。
    private func crossfadeThumbnail(duration: TimeInterval?, _ change: (LinkCardThumbnailView) -> Void) {
        guard let duration else {
            removeIncomingThumbnail()
            change(thumbnailView)
            return
        }
        // 重ねている途中にまた入れ替えるとき（下地を出した同じ回に、端末に残っていた画像を出すなど）は、重ねていたものを捨て、
        // 前の見え方から濃くし直す。
        let base = incomingThumbnail != nil ? incomingThumbnailBase : thumbnailView.image
        incomingThumbnail?.removeFromSuperview()
        incomingThumbnail = nil
        change(thumbnailView)
        let shown = thumbnailView.image
        guard shown !== base else { return }
        let incoming = UIImageView(image: shown)
        incoming.contentMode = thumbnailView.contentMode
        incoming.clipsToBounds = true
        incoming.frame = thumbnailView.bounds
        incoming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        incoming.alpha = 0
        incoming.isUserInteractionEnabled = false
        // 閲覧注意のぼかしより下に置く。
        thumbnailView.insertSubview(incoming, at: 0)
        thumbnailView.image = base
        incomingThumbnail = incoming
        incomingThumbnailBase = base
        UIView.animateSmoothly(duration: duration) {
            incoming.alpha = 1
        } completion: {
            guard self.incomingThumbnail === incoming else { return }
            self.removeIncomingThumbnail()
        }
    }

    /// 入れ替えの途中で、サムネイルの中に重ねて濃くしている新しい見え方。サムネイルそのものは、その間は前の見え方を描く。
    private var incomingThumbnail: UIImageView?
    private var incomingThumbnailBase: UIImage?

    /// 重ねていた新しい見え方を、サムネイルそのものに描かせて外す。
    private func removeIncomingThumbnail() {
        guard let incoming = incomingThumbnail else { return }
        incomingThumbnail = nil
        incomingThumbnailBase = nil
        thumbnailView.image = incoming.image
        incoming.removeFromSuperview()
    }

    /// リンクの記号の複製を重ねて薄くする。記号そのものは並べ方が濃さを決めるため、動かさずに隠す。
    private func fadeOutSymbol(duration: TimeInterval) {
        let copy = UIImageView(image: symbolView.image)
        copy.tintColor = symbolView.tintColor
        copy.contentMode = symbolView.contentMode
        copy.bounds = symbolView.bounds
        copy.center = symbolView.center
        copy.transform = symbolView.transform
        copy.alpha = symbolView.alpha
        copy.isUserInteractionEnabled = false
        insertSubview(copy, aboveSubview: thumbnailView)
        transitionSnapshots.append(copy)
        UIView.animateSmoothly(duration: duration) {
            copy.alpha = 0
        } completion: {
            self.removeTransitionSnapshots([copy])
        }
    }
}

/// リンクカードのサムネイル。カードの画像をビューアで開くとき、開閉の起点にもなる。
final class LinkCardThumbnailView: UIImageView, MediaViewerSource {
    /// 読み込んだ画像。ぼかしの下地は含まない。ビューアで元の画像が届くまでの下地にする。
    private(set) var loadedThumbnail: UIImage?
    /// 読み込んだ画像のURL。ビューアを閉じるとき、セルが別の投稿に使い回されていないかを確かめる。
    private(set) var imageURL: URL?

    var thumbnailImage: UIImage? { image }

    func showPlaceholder(_ placeholder: UIImage?) {
        loadedThumbnail = nil
        imageURL = nil
        image = placeholder
    }

    func showLoaded(_ loaded: UIImage, from url: URL) {
        loadedThumbnail = loaded
        imageURL = url
        image = loaded
    }

    /// `url`の画像を、画面に出ているカードで描いている。行が別の投稿に使い回されると、カードのない投稿ではカードごと隠れるだけで、
    /// URLが残るため、隠れていないことも確かめる。ビューアを閉じるときの戻り先にしてよいかを決める。
    func isShowing(_ url: URL?) -> Bool {
        guard imageURL == url, window != nil else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha == 0 { return false }
            view = current.superview
        }
        return true
    }
}

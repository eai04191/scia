import SciaCore
import UIKit

/// 投稿のリンクカード。左にサムネイル、右にサイトの名前、見出し、説明を1行ずつ並べる。見せ方は`docs/link-card.md`。
///
/// 高さは文字の大きさだけで決め、中身によらない。サーバーのカードが後から届いて、リンク先だけのカードから描き直しても、行の高さを変えないため。
/// タップ、キーボード、ポインタのどれで選ばれても`.primaryActionTriggered`で受けられるよう、`UIButton`にする。
final class LinkCardView: UIButton {
    struct Content: Equatable {
        var card: LinkCard
        /// 文字の、枠とサムネイルからの余白。
        var padding: CGFloat
    }

    private let store: MediaImageStore
    private let thumbnailView = UIImageView()
    private let symbolView = UIImageView(image: UIImage(systemName: "link"))
    private let siteLabel = UILabel()
    private let headlineLabel = UILabel()
    private let descriptionLabel = UILabel()
    private(set) var content: Content?
    private var loadTask: Task<Void, Never>?
    /// いま描いているサムネイルの出どころ。同じなら読み直さない。
    private var request: Request?

    private struct Request: Equatable {
        let url: URL
        let maxPixelSize: Int
    }

    init(store: MediaImageStore) {
        self.store = store
        super.init(frame: .zero)
        layer.cornerRadius = MediaGridView.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .link

        thumbnailView.backgroundColor = .secondarySystemFill
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
        let paddingChanged = content.padding != self.content?.padding
        self.content = content
        let text = Self.text(of: content.card)
        siteLabel.text = text.site
        headlineLabel.text = text.title
        headlineLabel.textColor = text.titleIsURL ? .secondaryLabel : .label
        updateFonts()
        descriptionLabel.text = text.description
        accessibilityLabel = ["リンク", text.titleIsURL ? nil : text.title, text.site].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "、")
        if paddingChanged {
            invalidateIntrinsicContentSize()
        }
        updateThumbnail()
        setNeedsLayout()
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

    private var siteFont: UIFont { .preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection) }
    /// 見出しの行の高さを決める文字。見出しの代わりにURLを出すときは、太字にせず控えめにする。
    private var titleFont: UIFont { .preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection) }
    /// 文字の行どうしのあいだ。
    private static let lineSpacing: CGFloat = 2

    private func updateFonts() {
        siteLabel.font = siteFont
        let showsURL = content.map { Self.text(of: $0.card).titleIsURL } ?? false
        headlineLabel.font = showsURL ? titleFont : titleFont.bold
        descriptionLabel.font = siteFont
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    }

    /// サムネイルの幅。カードの高さと同じ正方形にする。文字を大きくしてカードが高くなっても、文字の幅を残すため、カードの幅の`thumbnailMaxWidthRatio`までにする。
    private var thumbnailWidth: CGFloat {
        min(bounds.height, floor(bounds.width * Self.thumbnailMaxWidthRatio))
    }

    private static let thumbnailMaxWidthRatio: CGFloat = 0.3

    /// 文字の3行と余白から決まる高さ。
    private var cardHeight: CGFloat {
        let padding = content?.padding ?? 0
        let lines = siteFont.lineHeight * 2 + titleFont.lineHeight + Self.lineSpacing * 2
        return ceil(padding * 2 + lines)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: cardHeight)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .systemFill : nil }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        thumbnailView.frame = CGRect(x: 0, y: 0, width: thumbnailWidth, height: bounds.height)
        symbolView.frame = thumbnailView.frame
        let padding = content?.padding ?? 0
        let textX = thumbnailWidth + padding
        let textWidth = max(bounds.width - textX - padding, 0)
        var y = (bounds.height - (siteFont.lineHeight * 2 + titleFont.lineHeight + Self.lineSpacing * 2)) / 2
        for (label, font) in [(siteLabel, siteFont), (headlineLabel, titleFont), (descriptionLabel, siteFont)] {
            label.frame = CGRect(x: textX, y: y, width: textWidth, height: ceil(font.lineHeight))
            y += font.lineHeight + Self.lineSpacing
        }
        updateThumbnail()
    }

    /// サムネイルを、枠の大きさに合わせて読む。サムネイルのないカードとリンク先だけのカードには、リンクの記号を出す。
    private func updateThumbnail() {
        let card: PreviewCard? = if case .card(let card) = content?.card { card } else { nil }
        let scale = traitCollection.displayScale
        let request: Request? = if let image = card?.image, bounds.height > 0, scale > 0 {
            Request(url: image, maxPixelSize: Int(ceil(max(bounds.height, thumbnailWidth) * scale)))
        } else {
            nil
        }
        symbolView.isHidden = card?.image != nil
        guard request != self.request else { return }
        let keepsImage = request != nil && request?.url == self.request?.url
        self.request = request
        loadTask?.cancel()
        loadTask = nil
        if !keepsImage {
            thumbnailView.image = card?.blurhash.flatMap { store.placeholder(for: $0, aspectRatio: bounds.height > 0 ? thumbnailWidth / bounds.height : 1) }
        }
        guard let request else { return }
        if let cached = store.cachedImage(for: request.url, maxPixelSize: request.maxPixelSize) {
            thumbnailView.image = cached
            return
        }
        loadTask = Task { [weak self, store] in
            guard let image = try? await store.image(for: request.url, maxPixelSize: request.maxPixelSize),
                  let self, !Task.isCancelled, self.request == request
            else { return }
            UIView.transition(with: self.thumbnailView, duration: 0.15, options: .transitionCrossDissolve) {
                self.thumbnailView.image = image
            }
        }
    }
}

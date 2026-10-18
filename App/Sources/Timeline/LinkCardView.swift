import SciaCore
import UIKit

/// 投稿のリンクカード。左にサムネイル、右にサイトの名前、見出し、説明を1行ずつ並べる。見せ方は`docs/link-card.md`。
/// 画像のないカードにはサムネイルの枠を出さず、文字を左端から並べる。リンク先だけのカードには、リンクの記号を入れた枠を出す。
///
/// 高さは文字の大きさだけで決め、中身によらない。サーバーのカードが後から届いて、リンク先だけのカードから描き直しても、行の高さを変えないため。
/// 届いたカードに画像がなければ、枠を縮めて消し、文字を左へ寄せる動きでつなぐ。
/// タップ、キーボード、ポインタのどれで選ばれても`.primaryActionTriggered`で受けられるよう、`UIButton`にする。
final class LinkCardView: UIButton {
    struct Content: Equatable {
        var card: LinkCard
        /// 文字の、枠とサムネイルからの余白。
        var padding: CGFloat
        /// リンク先だけのカードに、サーバーのカードが届いたときの、描き替えの時間。
        var transitionDuration: TimeInterval

        /// サムネイルの枠を出す。画像のあるカードと、まだカードの届いていないリンク先だけのカード。
        var showsThumbnail: Bool {
            switch card {
            case .card(let card): card.image != nil
            case .link: true
            }
        }
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
    /// 並べ方で、サムネイルの枠を出すか。枠を縮めて消す動きを始めるまでは、中身と食い違う。
    private var laysOutThumbnail = false

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
        let previous = self.content
        let paddingChanged = content.padding != previous?.padding
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
        updateThumbnail()
        setNeedsLayout()
        guard animates else {
            laysOutThumbnail = content.showsThumbnail
            return
        }
        // 一覧は動きを止めて描き直し（animatingDifferences: false）、その中ではUIView.animateが動かないため、描き直しを終えてから動かす。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.content == content else { return }
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
        let options: UIView.AnimationOptions = [.allowUserInteraction, .beginFromCurrentState]
        UIView.animate(springDuration: duration, bounce: 0, options: options) {
            self.laysOutThumbnail = content.showsThumbnail
            self.setNeedsLayout()
            self.layoutIfNeeded()
            for (label, snapshot) in snapshots {
                // 像は古い文字の大きさのまま、新しい文字の左上に合わせて動かす。
                snapshot.frame.origin = label.frame.origin
            }
        } completion: { _ in
            self.removeTransitionSnapshots(snapshots.map(\.1))
        }
        // 濃さは位置と別に、古い文字を先に薄くし、新しい文字を少し遅れて濃くする。同時に入れ替えると、
        // スプリングの出だしで両方が濃いまま重なり、読めない文字が数コマ出るため。
        // 新しい文字は直前に濃さを0にしたばかりで、画面上はまだ濃いため、今の見た目からは始めない。
        UIView.animate(withDuration: duration * 0.4, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            for (_, snapshot) in snapshots { snapshot.alpha = 0 }
        }
        UIView.animate(withDuration: duration * 0.6, delay: duration * 0.2, options: [.allowUserInteraction, .curveEaseInOut]) {
            for label in changed { label.alpha = 1 }
        }
    }

    /// 入れ替えの途中で重ねている、古い文字の像。
    private var transitionSnapshots: [UIView] = []

    private func removeTransitionSnapshots(_ snapshots: [UIView]? = nil) {
        let removing = snapshots ?? transitionSnapshots
        for snapshot in removing { snapshot.removeFromSuperview() }
        transitionSnapshots.removeAll { removing.contains($0) }
    }

    /// 文字を、動きを止めて、すぐに出す。
    private func showText(of content: Content) {
        removeTransitionSnapshots()
        for label in [siteLabel, headlineLabel, descriptionLabel] {
            label.layer.removeAllAnimations()
            label.alpha = 1
        }
        setText(of: content)
    }

    private func setText(of content: Content) {
        let text = Self.text(of: content.card)
        siteLabel.text = text.site
        headlineLabel.text = text.title
        descriptionLabel.text = text.description
        headlineLabel.textColor = text.titleIsURL ? .secondaryLabel : .label
        updateFonts()
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
    /// 枠を出さないカードでは0。
    private var thumbnailWidth: CGFloat {
        guard laysOutThumbnail else { return 0 }
        return min(bounds.height, floor(bounds.width * Self.thumbnailMaxWidthRatio))
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
        // 記号は枠と一緒に押し潰さず、枠の中央で、枠を縮めて消すあいだに小さくしながら薄くする。
        let hidesThumbnail = thumbnailWidth == 0
        symbolView.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.height)
        symbolView.center = CGPoint(x: thumbnailView.frame.midX, y: thumbnailView.frame.midY)
        symbolView.transform = hidesThumbnail ? CGAffineTransform(scaleX: 0.5, y: 0.5) : .identity
        thumbnailView.alpha = hidesThumbnail ? 0 : 1
        symbolView.alpha = hidesThumbnail ? 0 : 1
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

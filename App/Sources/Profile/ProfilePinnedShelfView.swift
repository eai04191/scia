import SciaCore
import UIKit

/// プロフィールのヘッダーの下に置く、固定された投稿を横に並べた棚。
/// 一覧の頭に並べると、固定された投稿が多いときに投稿の一覧が下へ押し出されるため、何件あっても高さの変わらない横の列にする。
/// ほかのサーバーのアカウントでは、固定できる数に上限がないこともある。
final class ProfilePinnedShelfView: UIView, UIScrollViewDelegate {
    /// カードが押されたときに、その投稿と、ウインドウの座標でのカードの枠を渡して呼ぶ。
    var onOpen: ((Status, CGRect) -> Void)?

    private let emojiImages: EmojiImageStore
    private let mediaImages: MediaImageStore
    private let titleLabel = UILabel()
    private let scrollView = PinnedShelfScrollView()
    private let cardStack = UIStackView()
    /// 並べている投稿と、それぞれに当てたフィルターの判定。同じなら作り直さない。
    private(set) var items: [ProfileShelfItem] = []
    private var glyphLanguage = ""

    /// カードの幅の、棚の幅に対する割合。次のカードの端をのぞかせ、横にスクロールできると分かるようにする。
    private static let cardWidthRatio: CGFloat = 0.72
    private static let margin: CGFloat = 16

    init(emojiImages: EmojiImageStore, mediaImages: MediaImageStore) {
        self.emojiImages = emojiImages
        self.mediaImages = mediaImages
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        titleLabel.text = "固定された投稿"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header

        scrollView.showsHorizontalScrollIndicator = false
        // ステータスバーのタップで、プロフィールの一覧が先頭へ戻れるようにする。iPhoneでは、対象のスクロールビューが2つ以上あるとどれも動かない。
        scrollView.scrollsToTop = false
        scrollView.alwaysBounceVertical = false
        scrollView.clipsToBounds = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Self.margin, bottom: 0, right: Self.margin)
        scrollView.decelerationRate = .fast
        scrollView.delegate = self
        cardStack.axis = .horizontal
        cardStack.alignment = .fill
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(cardStack)

        for view in [titleLabel, scrollView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // 棚の高さは、一番背の高いカードで決める。カードの文字は縮まないので、低くしようとする制約に勝って、その高さに落ち着く。
        let shrink = scrollView.heightAnchor.constraint(equalToConstant: 0)
        shrink.priority = .init(1)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.margin),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            shrink,
            cardStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            cardStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            cardStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    /// 並べる投稿を変える。中身が同じなら作り直さない。編集や操作で中身が変われば、同じ投稿の並びでも描き直し、押したときに渡す投稿も新しくする。
    /// 同じ投稿の並びのままなら、横のスクロール位置は残す。
    func setItems(_ items: [ProfileShelfItem], glyphLanguage: String) {
        guard items != self.items || glyphLanguage != self.glyphLanguage else { return }
        rebuild(items, glyphLanguage: glyphLanguage)
    }

    /// 並べている投稿のカードを描き直す。本文のカスタム絵文字が読み込まれたときに呼ぶ。読み込む前は、絵文字の場所が空白で描かれているため。
    func redraw() {
        rebuild(items, glyphLanguage: glyphLanguage)
    }

    /// 本文に、`urls`のどれかのカスタム絵文字を使っている投稿がある。
    func uses(emojiURLs urls: Set<URL>) -> Bool {
        items.contains { item in
            item.status.emojis.contains { urls.contains($0.url) || urls.contains($0.staticUrl) }
        }
    }

    private func rebuild(_ items: [ProfileShelfItem], glyphLanguage: String) {
        let keepsOffset = items.map(\.status.id) == self.items.map(\.status.id)
        let offset = scrollView.contentOffset
        self.items = items
        self.glyphLanguage = glyphLanguage
        for card in cardStack.arrangedSubviews {
            card.removeFromSuperview()
        }
        for item in items {
            let status = item.status
            let card = ProfilePinnedCard(status: status, verdict: item.verdict, emojiImages: emojiImages, mediaImages: mediaImages, glyphLanguage: glyphLanguage)
            card.onTap = { [weak self, weak card] in
                guard let card else { return }
                self?.onOpen?(status, card.convert(card.bounds, to: nil))
            }
            cardStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: widthAnchor, multiplier: Self.cardWidthRatio).isActive = true
        }
        scrollView.contentOffset = keepsOffset ? offset : CGPoint(x: -Self.margin, y: 0)
    }

    /// 指を離したら、止まる先に一番近いカードの左端を、左の余白に揃えて止める。App Storeの棚と同じく、カードが途中で切れたまま止まらないようにする。
    /// 軽くはじいて、止まる先が今のカードのままなら、はじいた向きに1枚進める。
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let starts = cardStack.arrangedSubviews.map { $0.frame.minX - Self.margin }
        guard !starts.isEmpty else { return }
        func nearest(to offset: CGFloat) -> Int {
            starts.indices.min { abs(starts[$0] - offset) < abs(starts[$1] - offset) } ?? 0
        }
        let current = nearest(to: scrollView.contentOffset.x)
        var index = nearest(to: targetContentOffset.pointee.x)
        if index == current, abs(velocity.x) > 0.2 {
            index = min(max(current + (velocity.x > 0 ? 1 : -1), 0), starts.count - 1)
        }
        let maxOffset = max(scrollView.contentSize.width + Self.margin - scrollView.bounds.width, -Self.margin)
        targetContentOffset.pointee.x = min(starts[index], maxOffset)
    }
}

/// 固定された投稿のカード。持ち主はプロフィールの本人なので、名前とアイコンは出さず、本文、最初の添付ファイル、投稿した日を出す。
private final class ProfilePinnedCard: UIControl {
    var onTap: (() -> Void)?

    private let bodyLabel = EmojiLabel()
    private let dateLabel = UILabel()
    private let thumbnailView = UIImageView()
    private var thumbnailTask: Task<Void, Never>?

    private static let thumbnailSize: CGFloat = 64

    init(status: Status, verdict: FilterVerdict, emojiImages: EmojiImageStore, mediaImages: MediaImageStore, glyphLanguage: String) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let hasFilterWarning = !verdict.warningTitles.isEmpty
        let hasWarning = hasFilterWarning || !status.spoilerText.isEmpty
        // 警告のフィルターに一致した投稿と、注意書きのある投稿は、警告の文だけを出し、本文と添付ファイルを出さない。開いた先で、いつもどおり読むかを選ぶ。
        // フィルターの警告は、一覧の行（`PostContentBuilder.filterWarning`）と同じ文言にする。
        if hasFilterWarning {
            let text = NSMutableAttributedString(string: "フィルター: ", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
            text.append(NSAttributedString(string: verdict.warningTitles.joined(separator: "、"), attributes: [.font: font, .foregroundColor: UIColor.label]))
            bodyLabel.attributedText = text
        } else {
            let text: RichText = hasWarning ? .plain(status.spoilerText, emojis: status.emojis) : .html(status.content, emojis: status.emojis)
            bodyLabel.attributedText = RichTextRenderer(font: font, textColor: hasWarning ? .secondaryLabel : .label, emojiImages: emojiImages, language: glyphLanguage)
                .render(text)
        }
        bodyLabel.numberOfLines = 5
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        dateLabel.font = .preferredFont(forTextStyle: .caption1)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel
        dateLabel.text = status.createdAt.formatted(date: .numeric, time: .omitted)
        dateLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 8
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.backgroundColor = .tertiarySystemFill
        // 閲覧注意の添付ファイルと、ぼかすフィルターに一致した添付ファイルは、カードでは見せない。
        let showsMedia = !hasWarning && !status.sensitive && verdict.mediaTitles.isEmpty
        let thumbnail = showsMedia ? status.mediaAttachments.first.flatMap { ProfileShelfItem.thumbnailRequest(for: $0, size: Self.thumbnailSize) } : nil
        thumbnailView.isHidden = thumbnail == nil

        let textStack = UIStackView(arrangedSubviews: [bodyLabel, UIView(), dateLabel])
        textStack.axis = .vertical
        textStack.spacing = 6
        let row = UIStackView(arrangedSubviews: [textStack, thumbnailView])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: Self.thumbnailSize),
            thumbnailView.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        let attachments = status.mediaAttachments.isEmpty ? nil : "添付ファイル\(status.mediaAttachments.count)件"
        accessibilityLabel = [bodyLabel.attributedText?.string, attachments, dateLabel.text].compactMap(\.self).joined(separator: "、")

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        if let thumbnail {
            loadThumbnail(thumbnail, from: mediaImages)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        thumbnailTask?.cancel()
    }

    /// 読み上げでダブルタップしたときも開く。`UIControl`はタップで`touchUpInside`を送るが、読み上げの操作では送らないため。
    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    private func loadThumbnail(_ request: MediaThumbnailRequest, from mediaImages: MediaImageStore) {
        if let cached = mediaImages.cachedImage(for: request.url, maxPixelSize: request.maxPixelSize) {
            thumbnailView.image = cached
            return
        }
        thumbnailTask = Task { [weak self] in
            guard let image = try? await mediaImages.image(for: request.url, maxPixelSize: request.maxPixelSize), let self, !Task.isCancelled else { return }
            UIView.transition(with: self.thumbnailView, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.thumbnailView.image = image
            }
        }
    }
}

/// 固定された投稿の棚に並べる投稿と、それに当てたサーバーのフィルターの判定。棚でも、一覧の行と同じく警告とぼかしを当てる。
struct ProfileShelfItem: Equatable {
    let status: Status
    let verdict: FilterVerdict

    /// 棚の小さなサムネイルに読む画像。既存の選び方で、サーバーが縮めたプレビュー画像だけを読む。棚のサムネイルはプレビュー画像で足り、
    /// 元のファイル（動画や音声の本体）を読まないため。読める画像がない種類（音声など）ならnil。
    static func thumbnailRequest(for attachment: MediaAttachment, size: CGFloat) -> MediaThumbnailRequest? {
        MediaThumbnailSelection.request(
            for: attachment,
            tileSize: CGSize(width: size, height: size),
            displayScale: 3,
            policy: MediaThumbnailPolicy(allowsOriginal: false, upscaleTolerance: 1)
        )
    }
}

/// 固定された投稿の棚のスクロールビュー。カードは`UIControl`で、スクロールビューは標準では`UIControl`の上で始まった押下をスクロールに切り替えない。
/// カードを押して少し待ってから横へ動かしてもスクロールできるよう、カードの押下は取り消してスクロールに切り替える。
private final class PinnedShelfScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is ProfilePinnedCard || super.touchesShouldCancel(in: view)
    }
}

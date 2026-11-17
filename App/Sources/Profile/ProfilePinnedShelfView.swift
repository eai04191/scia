import SciaCore
import UIKit

/// プロフィールのヘッダーの下に置く、固定された投稿を横に並べた棚。
/// タイムラインの頭に並べると、固定された投稿が多いときに投稿のタイムラインが下へ押し出されるため、何件あっても高さの変わらない横の列にする。
/// ほかのサーバーのアカウントでは、固定できる数に上限がないこともある。
final class ProfilePinnedShelfView: UIView, UIScrollViewDelegate {
    /// カードが押されたときに、その投稿と、ウインドウの座標でのカードの枠を渡して呼ぶ。
    var onOpen: ((Status, CGRect) -> Void)?

    private let emojiImages: EmojiImageStore<UIImage>
    private let mediaImages: MediaImageStore<UIImage>
    private let titleLabel = UILabel()
    private let scrollView = PinnedShelfScrollView()
    private let cardStack = UIStackView()
    /// 並べている投稿と、それぞれに当てたフィルターの判定。同じなら作り直さない。
    private(set) var items: [ProfileShelfItem] = []
    private var glyphLanguage = ""
    /// カードに付ける色。
    var accent: ProfileAccentAppearance? {
        didSet {
            for case let card as ProfilePinnedCard in cardStack.arrangedSubviews {
                card.applyAccent(accent)
            }
        }
    }

    /// カードの幅の、棚の幅に対する割合。次のカードの端をのぞかせ、横にスクロールできると分かるようにする。
    private static let cardWidthRatio: CGFloat = 0.72
    private static let margin: CGFloat = 16

    init(emojiImages: EmojiImageStore<UIImage>, mediaImages: MediaImageStore<UIImage>) {
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
        titleLabel.text = PostTexts.pinned
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header

        scrollView.showsHorizontalScrollIndicator = false
        // ステータスバーのタップで、プロフィールのタイムラインが先頭へ戻れるようにする。iPhoneでは、対象のスクロールビューが2つ以上あるとどれも動かない。
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
            item.status.emojis.hasImage(in: urls)
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
            let card = ProfilePinnedCard(item: item, emojiImages: emojiImages, mediaImages: mediaImages, glyphLanguage: glyphLanguage)
            card.onTap = { [weak self, weak card] in
                guard let card else { return }
                self?.onOpen?(status, card.convert(card.bounds, to: nil))
            }
            card.applyAccent(accent)
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

/// 固定された投稿のカード。持ち主はプロフィールの本人なので、名前とアイコンは出さず、本文、添付ファイル、投稿した日を出す。
/// 添付ファイルは見せるだけで、押すとカードと同じく投稿を開く。
private final class ProfilePinnedCard: UIControl {
    var onTap: (() -> Void)?

    private let bodyLabel = EmojiLabel()
    private let dateLabel = UILabel()
    private let mediaView: MediaGridView

    init(item: ProfileShelfItem, emojiImages: EmojiImageStore<UIImage>, mediaImages: MediaImageStore<UIImage>, glyphLanguage: String) {
        let status = item.status
        let verdict = item.verdict
        mediaView = MediaGridView(store: mediaImages)
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let hasFilterWarning = !verdict.warningTitles.isEmpty
        let hasWarning = hasFilterWarning || !status.spoilerText.isEmpty
        // 警告のフィルターに一致した投稿と、注意書きのある投稿は、警告の文だけを出し、本文と添付ファイルを出さない。開いた先で、いつもどおり読むかを選ぶ。
        // フィルターの警告は、タイムラインの行（`PostContentBuilder.filterWarning`）と同じ文言にする。
        if hasFilterWarning {
            let warning = PostTexts.filterWarning(titles: verdict.warningTitles)
            let text = NSMutableAttributedString(string: warning.text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
            text.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(warning.emphasis, in: warning.text))
            ListSeparator.replaceSeparators(warning.separators, of: warning.text, in: text, font: font)
            bodyLabel.attributedText = text
        } else {
            let text: RichText = hasWarning ? .plain(status.spoilerText, emojis: status.emojis) : .html(status.content, emojis: status.emojis)
            bodyLabel.attributedText = RichTextRenderer(font: font, textColor: hasWarning ? .secondaryLabel : .label, emojiImages: emojiImages, animatesEmojis: false, language: glyphLanguage)
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

        let mediaSide = item.media?.stackSide ?? 0
        if let media = item.media {
            mediaView.apply(media)
        } else {
            mediaView.isHidden = true
        }

        let textStack = UIStackView(arrangedSubviews: [bodyLabel, UIView(), dateLabel])
        textStack.axis = .vertical
        textStack.spacing = 6
        let row = UIStackView(arrangedSubviews: [textStack, mediaView])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // 一辺は、カードが狭くて本文の幅が残らなければ縮められるよう、上限より弱くする。
        let mediaWidth = mediaView.widthAnchor.constraint(equalToConstant: mediaSide)
        mediaWidth.priority = .required - 1
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            mediaWidth,
            mediaView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5, constant: -12 - row.spacing),
            mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = ProfileTexts.Shelf.pinnedAccessibilityLabel(body: bodyLabel.attributedText?.stringSpeakingListSeparators, attachmentCount: item.spokenAttachmentCount, date: dateLabel.text)

        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// カードに色を付ける。nilならシステムの色に戻す。
    func applyAccent(_ accent: ProfileAccentAppearance?) {
        if let accent {
            accent.apply(to: self)
        } else {
            ProfileAccentAppearance.reset(self)
        }
        dateLabel.textColor = accent?.secondaryText ?? .secondaryLabel
        ProfileAccentAppearance.recolorSecondaryText(in: bodyLabel, to: accent?.secondaryText)
        ProfileAccentAppearance.restyleLinks(in: bodyLabel, underline: accent != nil, badge: nil)
    }

    /// 読み上げでダブルタップしたときも開く。`UIControl`はタップで`touchUpInside`を送るが、読み上げの操作では送らないため。
    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// 固定された投稿の棚に並べる投稿と、それに当てたサーバーのフィルターの判定。棚でも、タイムラインの行と同じく警告とぼかしを当てる。
struct ProfileShelfItem: Equatable {
    let status: Status
    let verdict: FilterVerdict
    /// カードの本文の右に重ねて出す添付ファイル。出さないならnil。ぼかしは、タイムラインの行と同じく、使う人が開いたり隠したりした選択に従う。
    /// 「投稿の見た目」の並べ方によらず、本文の右に小さく出すときの形にする。カードの幅には、本文の下に大きく並べる余地がないため。
    let media: MediaGridView.Content?

    @MainActor
    init(
        status: Status,
        verdict: FilterVerdict,
        covers: MediaCovers,
        settings: AppSettings = AppDependencies.settings,
        tuning: TuningStore = AppDependencies.tuning,
        network: NetworkConditionsMonitor = AppDependencies.network
    ) {
        self.status = status
        self.verdict = verdict
        // 注意書きとフィルターの警告の投稿は、本文と同じく添付ファイルも出さない。
        guard status.spoilerText.isEmpty, verdict.warningTitles.isEmpty else {
            media = nil
            return
        }
        var media = MediaGridView.Content.make(of: status.mediaAttachments, cover: covers.cover(for: status, filterTitles: verdict.mediaTitles), settings: settings, tuning: tuning, network: network)
        media?.arrange(.besideBody, seed: status.id, settings: settings)
        self.media = media
    }

    /// 読み上げで伝える添付ファイルの数。添付ファイルを出さない投稿では、タイムラインで折りたたんだ投稿と同じく、あることを読み上げでも伝えない。
    var spokenAttachmentCount: Int {
        media?.attachments.count ?? 0
    }
}

private extension MediaGridView.Content {
    /// 重ねて出すときの正方形の一辺。重ねていなければnil。
    var stackSide: CGFloat? {
        if case .stack(let side) = arrangement { side } else { nil }
    }
}

/// 固定された投稿の棚のスクロールビュー。カードは`UIControl`で、スクロールビューは標準では`UIControl`の上で始まった押下をスクロールに切り替えない。
/// カードを押して少し待ってから横へ動かしてもスクロールできるよう、カードの押下は取り消してスクロールに切り替える。
private final class PinnedShelfScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is ProfilePinnedCard || super.touchesShouldCancel(in: view)
    }
}

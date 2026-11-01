import SciaCore
import UIKit

/// プロフィールのヘッダーの、見出しと横に流れる列を持つ棚。注目のハッシュタグと紹介しているユーザーで使う。
/// 固定された投稿の棚と同じく、何件あっても高さの変わらない横の列にする。決まりはdocs/profile.mdの「注目のハッシュタグと紹介しているユーザー」にある。
class ProfileShelfView: UIView {
    private let titleLabel = UILabel()
    private let scrollView = UIScrollView()
    let itemStack = UIStackView()
    static let margin: CGFloat = 16

    init(title: String, itemSpacing: CGFloat) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header

        scrollView.showsHorizontalScrollIndicator = false
        // ステータスバーのタップで、プロフィールの一覧が先頭へ戻れるようにする。iPhoneでは、対象のスクロールビューが2つ以上あるとどれも動かない。
        scrollView.scrollsToTop = false
        scrollView.alwaysBounceVertical = false
        // 長押しで持ち上げたカプセルやカードの影が、列の上下で切れないようにする。
        scrollView.clipsToBounds = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Self.margin, bottom: 0, right: Self.margin)
        itemStack.axis = .horizontal
        itemStack.alignment = .fill
        itemStack.spacing = itemSpacing
        itemStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(itemStack)

        for view in [titleLabel, scrollView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // 列の高さは、一番背の高い部品で決める。部品の文字は縮まないので、低くしようとする制約に勝って、その高さに落ち着く。
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
            itemStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            itemStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            itemStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            itemStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            itemStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 並べる部品を差し替える。同じものの並びのままなら、横のスクロール位置は残す。
    func replaceItems(_ views: [UIView], keepsOffset: Bool) {
        let offset = scrollView.contentOffset
        for view in itemStack.arrangedSubviews {
            view.removeFromSuperview()
        }
        for view in views {
            itemStack.addArrangedSubview(view)
        }
        scrollView.contentOffset = keepsOffset ? offset : CGPoint(x: -Self.margin, y: 0)
    }
}

/// 注目のハッシュタグの棚。`#名前`と投稿の数をカプセルで並べる。
final class ProfileFeaturedTagsShelfView: ProfileShelfView {
    /// カプセルが押された。
    var onOpen: ((FeaturedTag) -> Void)?
    /// カプセルを長押ししたときのメニュー。押したカプセルを渡す。nilを返せばメニューを出さない。
    var menuForTag: ((FeaturedTag, UIView) -> UIMenu?)?
    var menuLifecycle = MenuLifecycle()
    private(set) var tags: [FeaturedTag] = []
    private var menuInteractions: [ProfileTextMenuInteraction] = []

    init() {
        super.init(title: "注目のハッシュタグ", itemSpacing: 8)
    }

    /// 並べるタグを変える。中身が同じなら作り直さない。
    func setTags(_ tags: [FeaturedTag]) {
        guard tags != self.tags else { return }
        let keepsOffset = tags.map(\.id) == self.tags.map(\.id)
        self.tags = tags
        menuInteractions = []
        replaceItems(tags.map(makeChip), keepsOffset: keepsOffset)
    }

    private func makeChip(for tag: FeaturedTag) -> UIView {
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        // 名前が長くても、名前と数を省かずに1行で出す。列は横にスクロールするので、幅は抑えない。
        configuration.titleLineBreakMode = .byClipping
        configuration.titleAlignment = .leading
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        configuration.attributedTitle = Self.title(of: tag)
        let chip = UIButton(configuration: configuration)
        // 文字を、ボタンの色ではなく本文の色で描く。ハッシュタグの名前を読ませるためで、地の薄い色で押せることは分かる。
        chip.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = .label
        }
        chip.accessibilityLabel = "#\(tag.name)、\(tag.statusesCount)件の投稿"
        chip.addAction(UIAction { [weak self] _ in self?.onOpen?(tag) }, for: .primaryActionTriggered)
        menuInteractions.append(ProfileTextMenuInteraction(
            on: chip,
            menu: { [weak self, weak chip] in
                guard let self, let chip else { return nil }
                return menuForTag?(tag, chip)
            },
            previewPath: { bounds in UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2) },
            lifecycle: menuLifecycle
        ))
        return chip
    }

    private static func title(of tag: FeaturedTag) -> AttributedString {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let bold = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
        var name = AttributedString("#\(tag.name)")
        name.font = bold
        var count = AttributedString("  \(tag.statusesCount.formatted())")
        count.font = font
        count.foregroundColor = .secondaryLabel
        return name + count
    }
}

/// 紹介しているユーザーの棚。アイコンと表示名とハンドルを縦に積んだ小さなカードで並べる。続きがあれば、最後に「すべて見る」を置く。
final class ProfileEndorsementsShelfView: ProfileShelfView {
    struct Content: Equatable {
        let accounts: [Account]
        let hasMore: Bool
        let avatarShape: AvatarShape
        let animatesAvatars: Bool
        let animatesCustomEmojis: Bool
        let glyphLanguage: String
    }

    /// カードが押された。
    var onOpen: ((Account) -> Void)?
    /// 「すべて見る」が押された。
    var onOpenAll: (() -> Void)?
    /// カードを長押ししたときのメニュー。押したカードを渡す。nilを返せばメニューを出さない。
    var menuForAccount: ((Account, UIView) -> UIMenu?)?
    var menuLifecycle = MenuLifecycle()
    private(set) var content: Content?
    private var menuInteractions: [ProfileTextMenuInteraction] = []
    private let emojiImages: EmojiImageStore<UIImage>
    private let avatarImages: AvatarImageStore<UIImage>

    init(emojiImages: EmojiImageStore<UIImage>, avatarImages: AvatarImageStore<UIImage>) {
        self.emojiImages = emojiImages
        self.avatarImages = avatarImages
        super.init(title: "紹介しているユーザー", itemSpacing: 10)
    }

    /// 並べる人を変える。中身が同じなら作り直さない。
    func setContent(_ content: Content) {
        guard content != self.content else { return }
        rebuild(content)
    }

    /// 並べている人の表示名に、`urls`のどれかのカスタム絵文字を使っている人がいる。
    func uses(emojiURLs urls: Set<URL>) -> Bool {
        content?.accounts.contains { account in
            account.emojis.contains { urls.contains($0.url) || urls.contains($0.staticUrl) }
        } ?? false
    }

    /// カードを描き直す。表示名のカスタム絵文字が読み込まれたときに呼ぶ。読み込む前は、絵文字の場所が空白で描かれているため。
    func redraw() {
        guard let content else { return }
        rebuild(content)
    }

    private func rebuild(_ content: Content) {
        let keepsOffset = content.accounts.map(\.id) == self.content?.accounts.map(\.id)
        self.content = content
        menuInteractions = []
        var cards: [UIView] = content.accounts.map { makeCard(for: $0, content: content) }
        if content.hasMore {
            cards.append(makeShowAllCard())
        }
        replaceItems(cards, keepsOffset: keepsOffset)
    }

    private func makeCard(for account: Account, content: Content) -> UIView {
        let card = ProfileEndorsedCard(account: account, content: content, emojiImages: emojiImages, avatarImages: avatarImages)
        card.addAction(UIAction { [weak self] _ in self?.onOpen?(account) }, for: .primaryActionTriggered)
        menuInteractions.append(ProfileTextMenuInteraction(
            on: card,
            menu: { [weak self, weak card] in
                guard let self, let card else { return nil }
                return menuForAccount?(account, card)
            },
            previewPath: { bounds in UIBezierPath(roundedRect: bounds, cornerRadius: ProfileEndorsedCard.cornerRadius) },
            lifecycle: menuLifecycle
        ))
        return card
    }

    private func makeShowAllCard() -> UIView {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "すべて見る"
        configuration.image = UIImage(systemName: "chevron.forward")
        configuration.imagePlacement = .top
        configuration.imagePadding = 6
        configuration.background.cornerRadius = ProfileEndorsedCard.cornerRadius
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.onOpenAll?() }, for: .primaryActionTriggered)
        button.widthAnchor.constraint(equalToConstant: ProfileEndorsedCard.width).isActive = true
        return button
    }
}

/// 紹介しているユーザーの1人分のカード。
final class ProfileEndorsedCard: UIControl {
    static let width: CGFloat = 104
    static let cornerRadius: CGFloat = 16
    private static let avatarSide: CGFloat = 56

    private let avatarView: AvatarView
    private let nameLabel = EmojiLabel()
    private let handleLabel = UILabel()
    /// 地。「フォロー中」のボタンと同じく、ティントカラーで薄く塗る。同じ塗りにするため、UIKitのボタンの構成で描く。
    private let background = UIButton(configuration: .tinted())

    init(account: Account, content: ProfileEndorsementsShelfView.Content, emojiImages: EmojiImageStore<UIImage>, avatarImages: AvatarImageStore<UIImage>) {
        avatarView = AvatarView(store: avatarImages)
        super.init(frame: .zero)
        background.configuration?.background.cornerRadius = Self.cornerRadius
        background.isUserInteractionEnabled = false
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        avatarView.apply(AvatarView.Content(url: content.animatesAvatars ? account.avatar : account.avatarStatic, shape: content.avatarShape, animates: content.animatesAvatars))
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let bold = font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textAlignment = .center
        nameLabel.emojiImages = content.animatesCustomEmojis ? emojiImages : nil
        nameLabel.attributedText = RichTextRenderer(font: bold, textColor: .label, emojiImages: emojiImages, language: content.glyphLanguage)
            .render(.plain(account.displayNameOrUsername, emojis: account.emojis))
            .truncatingTail(alignment: .center)
        handleLabel.text = "@\(account.acct)"
        handleLabel.font = .preferredFont(forTextStyle: .caption1)
        handleLabel.textColor = .secondaryLabel
        handleLabel.textAlignment = .center
        handleLabel.lineBreakMode = .byTruncatingTail

        let stack = UIStackView(arrangedSubviews: [avatarView, nameLabel, handleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.setCustomSpacing(8, after: avatarView)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSide),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSide),
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            handleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        // 人の一覧の行と同じく、描いた名前を読ませる。カスタム絵文字の`:shortcode:`を読ませないため。
        accessibilityLabel = "\(nameLabel.attributedText?.string ?? account.displayNameOrUsername)、@\(account.acct)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

extension NSAttributedString {
    /// 段落を、`alignment`に揃えて末尾を省く形にした文字。描いた文字の段落の設定は、ラベルの揃えと省き方より優先されるため、名前を1行で描くラベルに入れる前に通す。
    /// カスタム絵文字の行の高さなど、ほかの段落の設定は残す。
    func truncatingTail(alignment: NSTextAlignment) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: self)
        var ranges: [(NSRange, NSParagraphStyle?)] = []
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            ranges.append((range, value as? NSParagraphStyle))
        }
        for (range, style) in ranges {
            let truncating = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            truncating.alignment = alignment
            truncating.lineBreakMode = .byTruncatingTail
            result.addAttribute(.paragraphStyle, value: truncating, range: range)
        }
        return result
    }
}

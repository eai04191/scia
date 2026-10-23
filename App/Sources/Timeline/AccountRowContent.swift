import SciaCore
import UIKit

/// 人の一覧の行の中身。左にアイコン、右に表示名とハンドルを2行で並べる。アイコンと文字の列は、投稿のセルと同じ位置に置く。
struct AccountRowConfiguration: UIContentConfiguration {
    var avatar: AvatarView.Content
    var name: NSAttributedString
    var handle: NSAttributedString
    var margins: NSDirectionalEdgeInsets
    var avatarSize: CGFloat
    /// アイコンの列と、文字の列のあいだ。
    var avatarSpacing: CGFloat
    /// 名前が入りきらないときに、行末をぼかす幅。投稿のセルの名前と同じ。
    var nameFadeWidth: CGFloat
    let avatarImages: AvatarImageStore
    /// 名前のアニメーションするカスタム絵文字を動かすときに、アニメーション版を読む置き場。nilなら動かさない。
    var emojiImages: EmojiImageStore?

    func makeContentView() -> any UIView & UIContentView {
        AccountRowView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> AccountRowConfiguration {
        self
    }
}

final class AccountRowView: UIView, UIContentView {
    private let avatarView: AvatarView
    private let nameLabel = FadingLabel()
    private let handleLabel = UILabel()
    /// 名前とハンドルの2行を囲む枠。アイコンの縦の中央に寄せるのに使う。
    private let textGuide = UILayoutGuide()
    private var current: AccountRowConfiguration
    /// 大きさで変わる制約。適用のたびに作り直す。
    private var variableConstraints: [NSLayoutConstraint] = []

    var configuration: any UIContentConfiguration {
        get { current }
        set {
            guard let configuration = newValue as? AccountRowConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: AccountRowConfiguration) {
        current = configuration
        avatarView = AvatarView(store: configuration.avatarImages)
        super.init(frame: .zero)
        // 長い名前は投稿のセルと同じく行末をぼかし、ハンドルは末尾を省く。
        handleLabel.lineBreakMode = .byTruncatingTail
        for view in [avatarView, nameLabel, handleLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addLayoutGuide(textGuide)
        isAccessibilityElement = true
        accessibilityTraits = .button
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func apply(_ configuration: AccountRowConfiguration) {
        current = configuration
        avatarView.apply(configuration.avatar)
        nameLabel.emojiImages = configuration.emojiImages
        nameLabel.attributedText = configuration.name
        nameLabel.fadeWidth = configuration.nameFadeWidth
        handleLabel.attributedText = configuration.handle
        accessibilityLabel = [configuration.name.string, configuration.handle.string]
            .map { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "、")

        NSLayoutConstraint.deactivate(variableConstraints)
        let margins = configuration.margins
        let textLeading = margins.leading + configuration.avatarSize + configuration.avatarSpacing
        // 一覧は行の高さを画素に丸めるため、下の余白は少し縮められるようにしておく。
        let bottom = bottomAnchor.constraint(greaterThanOrEqualTo: avatarView.bottomAnchor, constant: margins.bottom)
        let textBottom = bottomAnchor.constraint(greaterThanOrEqualTo: handleLabel.bottomAnchor, constant: margins.bottom)
        let fit = bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: margins.bottom)
        fit.priority = .defaultLow
        let centered = textGuide.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor)
        centered.priority = .defaultHigh
        variableConstraints = [
            avatarView.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margins.leading),
            avatarView.widthAnchor.constraint(equalToConstant: configuration.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: configuration.avatarSize),
            // 2行の文字を、アイコンの縦の中央に寄せる。文字がアイコンより高いとき（大きな文字の設定など）は、上から並べて行を伸ばす。
            textGuide.topAnchor.constraint(equalTo: nameLabel.topAnchor),
            textGuide.bottomAnchor.constraint(equalTo: handleLabel.bottomAnchor),
            centered,
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: margins.top),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            handleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            handleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            bottom,
            textBottom,
            fit,
        ]
        NSLayoutConstraint.activate(variableConstraints)
    }
}

extension TimelineViewController {
    /// 人の一覧の行。名前は、投稿のセルの名前と同じ太さと絵文字で描く。
    func accountConfiguration(for account: Account, base: UIListContentConfiguration) -> AccountRowConfiguration {
        let language = settings.glyphLanguageIdentifier()
        let nameFont = base.textProperties.font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base.textProperties.font
        let nameRenderer = RichTextRenderer(font: nameFont, textColor: base.textProperties.color, emojiImages: emojiImages, language: language)
        let handle = NSAttributedString(string: "@\(account.acct)", attributes: [
            .font: base.secondaryTextProperties.font,
            .foregroundColor: UIColor.secondaryLabel,
        ])
        return AccountRowConfiguration(
            avatar: avatarContent(of: account),
            name: nameRenderer.render(.plain(account.displayNameOrUsername, emojis: account.emojis)),
            handle: handle,
            margins: base.directionalLayoutMargins,
            avatarSize: tuning.value(of: TuningCatalog.avatarSize),
            avatarSpacing: tuning.value(of: TuningCatalog.avatarSpacing),
            nameFadeWidth: tuning.value(of: TuningCatalog.nameFadeWidth),
            avatarImages: avatarImages,
            emojiImages: settings.animatesCustomEmojis ? emojiImages : nil
        )
    }
}

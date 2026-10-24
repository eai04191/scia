import SciaCore
import UIKit

/// 投稿のセルの中身を、今のチューニングと設定から組み立てる。一覧と、設定画面の見本の投稿で同じ見た目にするために分けている。
@MainActor
struct PostContentBuilder {
    let tuning: TuningStore
    let settings: AppSettings
    let emojiImages: EmojiImageStore
    let mediaImages: MediaImageStore
    let avatarImages: AvatarImageStore

    /// タップしたときの処理と添付ファイルは含めない。一覧では呼び出し側が足す。
    /// - Parameter isPinned: プロフィールの上に置く、固定された投稿。名前の上に固定されていることを示す行を出す。
    /// - Parameter replyLabel: 名前の上に出す返信のラベル。固定された投稿とブーストでは、そのことを示す行を優先し、ラベルは出さない。
    func configuration(for status: Status, isPinned: Bool = false, replyLabel: ReplyLabel? = nil, base: UIListContentConfiguration) -> PostContentConfiguration {
        let shown = status.displayed
        let secondaryFont = base.secondaryTextProperties.font
        let metrics = PostContentConfiguration.Metrics(
            margins: base.directionalLayoutMargins,
            avatarSize: tuning.value(of: TuningCatalog.avatarSize),
            boosterAvatarSize: tuning.value(of: TuningCatalog.boosterAvatarSize),
            nameFadeWidth: tuning.value(of: TuningCatalog.nameFadeWidth),
            contextSymbolSpacing: tuning.value(of: TuningCatalog.contextSymbolSpacing),
            avatarSpacing: tuning.value(of: TuningCatalog.avatarSpacing),
            contextSpacing: tuning.value(of: TuningCatalog.contextSpacing),
            replyLineWidth: tuning.value(of: TuningCatalog.replyLineWidth),
            replyLineGap: tuning.value(of: TuningCatalog.replyLineGap),
            nameBodySpacing: tuning.value(of: TuningCatalog.nameBodySpacing),
            bodyMediaSpacing: tuning.value(of: TuningCatalog.bodyMediaSpacing),
            nameMediaSpacing: tuning.value(of: TuningCatalog.nameMediaSpacing),
            bodyLinkCardSpacing: tuning.value(of: TuningCatalog.bodyLinkCardSpacing),
            bodyPollSpacing: tuning.value(of: TuningCatalog.bodyPollSpacing),
            nameFont: Self.boldFont(base.textProperties.font),
            secondaryFont: secondaryFont,
            notificationSymbolFont: base.textProperties.font
        )
        let language = settings.glyphLanguageIdentifier()
        let primaryRenderer = RichTextRenderer(font: metrics.nameFont, textColor: base.textProperties.color, emojiImages: emojiImages, language: language)
        let secondaryRenderer = RichTextRenderer(font: secondaryFont, textColor: .secondaryLabel, emojiImages: emojiImages, language: language)
        let nameParts = settings.statusNameStyle.parts.enumerated().map { index, part in
            let renderer = index == 0 ? primaryRenderer : secondaryRenderer
            return switch part {
            case .displayName: renderer.render(.plain(shown.account.displayNameOrUsername, emojis: shown.account.emojis))
            case .acct: renderer.render(.plain("@\(shown.account.acct)", emojis: []))
            }
        }
        let context: PostContentConfiguration.Context? = if isPinned {
            PostContentConfiguration.Context(
                symbolName: "pin.fill",
                avatar: nil,
                text: secondaryRenderer.render(.plain("固定された投稿", emojis: [])),
                accessibilityText: "固定された投稿"
            )
        } else if status.reblog != nil {
            PostContentConfiguration.Context(
                symbolName: "arrow.2.squarepath",
                avatar: avatarContent(of: status.account),
                text: secondaryRenderer.render(.plain(status.account.displayNameOrUsername, emojis: status.account.emojis)),
                accessibilityText: "\(status.account.displayNameOrUsername)がブースト"
            )
        } else if let replyLabel {
            replyContext(replyLabel, font: secondaryFont, language: language)
        } else {
            nil
        }
        var configuration = PostContentConfiguration(
            context: context,
            avatar: avatarContent(of: shown.account),
            nameParts: nameParts,
            createdAt: shown.createdAt,
            isEdited: shown.editedAt != nil,
            visibility: shown.visibility,
            timeStyle: settings.statusTimeStyle,
            body: body(of: shown, base: base),
            spoiler: spoiler(of: shown, base: base),
            metrics: metrics,
            card: linkCard(of: shown),
            statusID: shown.id,
            mediaImages: mediaImages,
            avatarImages: avatarImages,
            emojiImages: settings.animatesCustomEmojis ? emojiImages : nil
        )
        configuration.reactionGlow = reactionGlow(for: shown)
        configuration.hashtagAccount = shown.account
        return configuration
    }

    /// `shown`は表示している投稿。ブーストなら、ブーストされた投稿。
    func reactionGlow(for shown: Status) -> ReactionGlow {
        ReactionGlow(statusID: shown.id, isReblogged: shown.reblogged, isFavourited: shown.favourited, style: ReactionGlow.Style(tuning: tuning, settings: settings))
    }

    /// 返信のラベル。自分への返信は、一覧の中で気づけるよう、記号と文字をアプリの色で描く。
    private func replyContext(_ label: ReplyLabel, font: UIFont, language: String) -> PostContentConfiguration.Context {
        let text = switch label {
        case .continuation: "続き"
        case .toMe: "自分への返信"
        case .toAccount(let acct): "@\(acct)への返信"
        case .unknownAccount: "返信"
        }
        let color: UIColor = label == .toMe ? .tintColor : .secondaryLabel
        let renderer = RichTextRenderer(font: font, textColor: color, emojiImages: emojiImages, language: language)
        return PostContentConfiguration.Context(
            symbolName: "arrowshape.turn.up.left",
            symbolColor: color,
            avatar: nil,
            text: renderer.render(.plain(text, emojis: [])),
            accessibilityText: text,
            opensAccount: false
        )
    }

    func avatarContent(of account: Account) -> AvatarView.Content {
        AvatarView.Content(
            url: settings.animatesAvatars ? account.avatar : account.avatarStatic,
            shape: settings.avatarShape,
            animates: settings.animatesAvatars
        )
    }

    private static func boldFont(_ font: UIFont) -> UIFont {
        font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
    }

    /// 投稿の本文。注意書きがあっても本文を返し、折りたたむかどうかは`spoiler(of:base:color:)`で決める。
    /// 文字の大きさは標準のリストの2行目の文字に揃え、色は読むものなのでいちばん濃い色を既定にする。
    /// 引用ブロックは、RichTextRendererがこれより一段薄く描く。
    func body(of status: Status, base: UIListContentConfiguration, color: UIColor = .label) -> NSAttributedString {
        bodyRenderer(of: status, base: base, color: color).render(.status(status))
    }

    /// 投稿のリンクカード。出さない投稿ならnil。
    func linkCard(of status: Status) -> LinkCardView.Content? {
        LinkCard(status: status).map {
            LinkCardView.Content(
                card: $0,
                padding: tuning.value(of: TuningCatalog.linkCardPadding),
                transitionDuration: tuning.value(of: TuningCatalog.linkCardTransitionDuration),
                thumbnailSide: settings.linkCardThumbnailSide
            )
        }
    }

    /// fxtwitterから読んだXの投稿の囲み。作者の行と本文はリンクカードの文字と同じ大きさにし、名前だけを太くする。
    /// 本文はXの投稿の言語が分からないため、使う人の言語で描く。
    func xPost(_ post: XPost, media: MediaGridView.Content?, base: UIListContentConfiguration) -> XPostView.Content {
        let font = base.secondaryTextProperties.font
        let language = settings.glyphLanguageIdentifier()
        let primary = RichTextRenderer(font: Self.boldFont(font), textColor: base.textProperties.color, emojiImages: emojiImages, language: language)
        let secondary = RichTextRenderer(font: font, textColor: .secondaryLabel, emojiImages: emojiImages, language: language)
        let name = NSMutableAttributedString(attributedString: primary.render(.plain(post.authorName, emojis: [])))
        name.append(secondary.render(.plain(" @\(post.authorScreenName)", emojis: [])))
        let body = RichTextRenderer(font: font, textColor: .label, emojiImages: emojiImages, language: language)
        return XPostView.Content(
            post: post,
            // Xのアイコンは静止画なので、アニメーションの設定によらず動かさない。
            avatar: AvatarView.Content(url: post.authorAvatar, shape: settings.avatarShape, animates: false),
            avatarSize: tuning.value(of: TuningCatalog.xPostAvatarSize),
            name: name,
            text: body.render(post.text),
            media: media,
            padding: tuning.value(of: TuningCatalog.linkCardPadding),
            spacing: tuning.value(of: TuningCatalog.bodyMediaSpacing),
            transitionDuration: tuning.value(of: TuningCatalog.linkCardTransitionDuration)
        )
    }

    /// 投稿の注意書き。注意書きがなければnil。開いているかは一覧が覚えているため、ここでは折りたたんだ形で返す。
    func spoiler(of status: Status, base: UIListContentConfiguration, color: UIColor = .label) -> PostBodyContent.Spoiler? {
        guard !status.spoilerText.isEmpty else { return nil }
        return PostBodyContent.Spoiler(
            text: bodyRenderer(of: status, base: base, color: color).render(.plain(status.spoilerText, emojis: status.emojis)),
            isCollapsed: true,
            padding: tuning.value(of: TuningCatalog.spoilerPadding),
            bodySpacing: tuning.value(of: TuningCatalog.spoilerBodySpacing)
        )
    }

    /// フィルターの警告。本文の代わりに注意書きのボックスに入れて出し、開くまで本文も添付ファイルも出さない。
    /// フィルターの名前は使う人が付けたものなので、投稿の言語ではなく、アプリの文字で描く。
    func filterWarning(titles: [String], base: UIListContentConfiguration) -> PostBodyContent.Spoiler {
        let font = base.secondaryTextProperties.font
        let text = NSMutableAttributedString(string: "フィルター: ", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        text.append(NSAttributedString(string: titles.joined(separator: "、"), attributes: [.font: font, .foregroundColor: UIColor.label]))
        return PostBodyContent.Spoiler(
            text: text,
            isCollapsed: true,
            kind: .filter,
            padding: tuning.value(of: TuningCatalog.spoilerPadding),
            bodySpacing: tuning.value(of: TuningCatalog.spoilerBodySpacing)
        )
    }

    /// 自分の投稿が、自分のフィルターに一致していることを示す1行。投稿は折りたたまないので、目立たせず、本文より小さく控えめな色で描く。
    func ownFilterNote(titles: [String]) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let text = NSMutableAttributedString()
        if let symbol = UIImage(systemName: "line.3.horizontal.decrease.circle", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol.withRenderingMode(.alwaysTemplate))))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: "フィルター" + titles.map { "「\($0)」" }.joined() + "に一致"))
        text.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel], range: NSRange(location: 0, length: text.length))
        return text
    }

    /// 本文と注意書きは投稿した人が書いたものなので、投稿の言語で描く。
    private func bodyRenderer(of status: Status, base: UIListContentConfiguration, color: UIColor) -> RichTextRenderer {
        RichTextRenderer(
            font: base.secondaryTextProperties.font,
            textColor: color,
            paragraphSpacing: tuning.value(of: TuningCatalog.paragraphSpacing),
            emojiImages: emojiImages,
            language: settings.glyphLanguageIdentifier(for: status.language)
        )
    }
}

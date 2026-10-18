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
    func configuration(for status: Status, isPinned: Bool = false, base: UIListContentConfiguration) -> PostContentConfiguration {
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
            nameBodySpacing: tuning.value(of: TuningCatalog.nameBodySpacing),
            bodyMediaSpacing: tuning.value(of: TuningCatalog.bodyMediaSpacing),
            nameMediaSpacing: tuning.value(of: TuningCatalog.nameMediaSpacing),
            bodyLinkCardSpacing: tuning.value(of: TuningCatalog.bodyLinkCardSpacing),
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
        } else {
            nil
        }
        return PostContentConfiguration(
            context: context,
            avatar: avatarContent(of: shown.account),
            nameParts: nameParts,
            createdAt: shown.createdAt,
            timeStyle: settings.statusTimeStyle,
            body: body(of: shown, base: base),
            spoiler: spoiler(of: shown, base: base),
            metrics: metrics,
            card: linkCard(of: shown),
            mediaImages: mediaImages,
            avatarImages: avatarImages
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

    /// 投稿の本文。注意書きがあっても本文を返し、畳むかどうかは`spoiler(of:base:color:)`で決める。
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

    /// 投稿の注意書き。注意書きがなければnil。開いているかは一覧が覚えているため、ここでは畳んだ形で返す。
    func spoiler(of status: Status, base: UIListContentConfiguration, color: UIColor = .label) -> PostBodyContent.Spoiler? {
        guard !status.spoilerText.isEmpty else { return nil }
        return PostBodyContent.Spoiler(
            text: bodyRenderer(of: status, base: base, color: color).render(.plain(status.spoilerText, emojis: status.emojis)),
            isCollapsed: true,
            padding: tuning.value(of: TuningCatalog.spoilerPadding),
            bodySpacing: tuning.value(of: TuningCatalog.spoilerBodySpacing)
        )
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

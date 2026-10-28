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
        let typography = PostTypography(settings: settings)
        // 名前の上の行も名前を描くので、名前の行と同じ割合で絵文字の大きさを変える。本文の絵文字は本文の割合で描く。
        let emojiScale = CGFloat(settings.value(of: AppearanceCatalog.nameCustomEmojiScale))
        let metrics = PostContentConfiguration.Metrics(
            margins: settings.rowMargins,
            avatarSize: settings.value(of: AppearanceCatalog.avatarSize),
            boosterAvatarSize: settings.value(of: AppearanceCatalog.boosterAvatarSize),
            nameFadeWidth: settings.value(of: AppearanceCatalog.nameFadeWidth),
            contextSymbolSpacing: settings.value(of: AppearanceCatalog.contextSymbolSpacing),
            contextAvatarTextSpacing: settings.value(of: AppearanceCatalog.contextAvatarTextSpacing),
            avatarSpacing: settings.value(of: AppearanceCatalog.avatarSpacing),
            contextSpacing: settings.value(of: AppearanceCatalog.contextSpacing),
            replyLineWidth: settings.value(of: AppearanceCatalog.replyLineWidth),
            replyLineGap: settings.value(of: AppearanceCatalog.replyLineGap),
            nameBodySpacing: settings.value(of: AppearanceCatalog.nameBodySpacing),
            bodyMediaSpacing: settings.value(of: AppearanceCatalog.bodyMediaSpacing),
            nameMediaSpacing: settings.value(of: AppearanceCatalog.nameMediaSpacing),
            bodyLinkCardSpacing: settings.value(of: AppearanceCatalog.bodyLinkCardSpacing),
            bodyPollSpacing: settings.value(of: AppearanceCatalog.bodyPollSpacing),
            namePartsSpacing: settings.value(of: AppearanceCatalog.namePartsSpacing),
            nameTimeSpacing: settings.value(of: AppearanceCatalog.nameTimeSpacing),
            nameFont: typography.font(.namePrimary),
            timeFont: typography.font(.time),
            // 名前の上の行は、ブーストならブーストした人の名前の文字、返信と固定ならラベルの文字で描く。記号の大きさもこれに合わせる。
            contextFont: typography.font(status.reblog != nil ? .context : .contextLabel),
            visibilitySymbolSpacing: settings.value(of: AppearanceCatalog.visibilitySymbolSpacing),
            editedMarkSpacing: settings.value(of: AppearanceCatalog.editedMarkSpacing),
            filterNoteSpacing: settings.value(of: AppearanceCatalog.filterNoteSpacing),
            showsContextSymbol: settings.showsContextSymbol,
            bodyEmbedSpacing: settings.value(of: AppearanceCatalog.bodyXPostSpacing)
        )
        let language = settings.glyphLanguageIdentifier()
        let primaryRenderer = RichTextRenderer(font: metrics.nameFont, textColor: base.textProperties.color, emojiScale: emojiScale, emojiImages: emojiImages, language: language)
        let secondaryRenderer = RichTextRenderer(font: typography.font(.nameSecondary), textColor: .secondaryLabel, emojiScale: emojiScale, emojiImages: emojiImages, language: language)
        let contextRenderer = RichTextRenderer(font: metrics.contextFont, textColor: .secondaryLabel, emojiScale: emojiScale, emojiImages: emojiImages, language: language)
        let contextSecondaryRenderer = RichTextRenderer(font: typography.font(.contextSecondary), textColor: .secondaryLabel, emojiScale: emojiScale, emojiImages: emojiImages, language: language)
        let boosterName = Self.joined(spacing: settings.value(of: AppearanceCatalog.contextPartsSpacing), settings.contextNameStyle.parts.enumerated().map { index, part in
            let renderer = index == 0 ? contextRenderer : contextSecondaryRenderer
            return switch part {
            case .displayName: renderer.render(.plain(status.account.displayNameOrUsername, emojis: status.account.emojis))
            case .acct: renderer.render(.plain("@\(status.account.acct)", emojis: []))
            }
        })
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
                text: contextRenderer.render(.plain("固定された投稿", emojis: [])),
                accessibilityText: "固定された投稿"
            )
        } else if status.reblog != nil {
            PostContentConfiguration.Context(
                symbolName: "arrow.2.squarepath",
                avatar: settings.showsBoosterAvatar ? avatarContent(of: status.account) : nil,
                text: boosterName.text,
                secondaryRange: boosterName.secondaryRange,
                accessibilityText: "\(status.account.displayNameOrUsername)がブースト",
                accountName: status.account.displayNameOrUsername
            )
        } else if let replyLabel, settings.showsReplyLabel {
            replyContext(replyLabel, font: metrics.contextFont, language: language)
        } else {
            nil
        }
        var configuration = PostContentConfiguration(
            context: context,
            avatar: avatarContent(of: shown.account),
            nameParts: nameParts,
            authorName: shown.account.displayNameOrUsername,
            createdAt: shown.createdAt,
            isEdited: shown.editedAt != nil,
            visibility: shown.visibility,
            showsVisibilitySymbol: settings.showsVisibilitySymbol,
            showsEditedMark: settings.showsEditedMark,
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
        configuration.showsReplyLines = settings.showsReplyLines
        configuration.showsTime = settings.showsTime
        configuration.isBoost = status.reblog != nil
        configuration.isReply = replyLabel != nil && status.reblog == nil && !isPinned
        configuration.hasHiddenLinkCard = !settings.showsLinkCard && LinkCard(status: shown) != nil
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
            animates: settings.animatesAvatars,
            cornerRatio: settings.value(of: AppearanceCatalog.avatarCornerRatio),
            showsBorder: settings.showsAvatarBorder
        )
    }

    /// 名前の上の行の、ブーストした人の名前の部分をつなぐ。2つ目の部分があれば、その範囲も返す。
    /// すき間は空白ではなく、前の部分の最後の文字の後ろに足す字送りで取る。空白の幅は文字の大きさで変わり、すき間だけを決められないため。
    private static func joined(spacing: CGFloat, _ parts: [NSAttributedString]) -> (text: NSAttributedString, secondaryRange: NSRange?) {
        let text = NSMutableAttributedString()
        var secondaryRange: NSRange?
        for part in parts where part.length > 0 {
            if text.length > 0 {
                text.addAttribute(.kern, value: spacing, range: NSRange(location: text.length - 1, length: 1))
                secondaryRange = NSRange(location: text.length, length: part.length)
            }
            text.append(part)
        }
        return (text, secondaryRange)
    }

    private static func boldFont(_ font: UIFont) -> UIFont {
        font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
    }

    /// 投稿の本文。注意書きがあっても本文を返し、折りたたむかどうかは`spoiler(of:base:color:)`で決める。
    /// 文字の大きさは「投稿の見た目」の本文の文字にし、色は読むものなのでいちばん濃い色を既定にする。
    /// 引用ブロックは、RichTextRendererがこれより一段薄く描く。
    /// - Parameter font: 本文の文字と違う大きさで描くときの書体。通知で再掲する投稿は「通知の見た目」の文字で描く。
    func body(of status: Status, base: UIListContentConfiguration, color: UIColor = .label, font: UIFont? = nil) -> NSAttributedString {
        bodyRenderer(of: status, font: font ?? PostTypography(settings: settings).font(.body), color: color).render(.status(status))
    }

    /// HTMLではない文字（予約した投稿のソースなど）を、投稿の本文と同じ文字の大きさと行間で描く。空白と改行は書いたまま残す。
    func body(plain text: String, of status: Status, base: UIListContentConfiguration) -> NSAttributedString {
        bodyRenderer(of: status, font: PostTypography(settings: settings).font(.body), color: .label).render(.plain(text, emojis: status.emojis))
    }

    /// 投稿のリンクカード。出さない投稿ならnil。
    func linkCard(of status: Status) -> LinkCardView.Content? {
        guard settings.showsLinkCard else { return nil }
        return LinkCard(status: status).map {
            LinkCardView.Content(
                card: $0,
                padding: settings.value(of: AppearanceCatalog.linkCardPadding),
                transitionDuration: tuning.value(of: TuningCatalog.linkCardTransitionDuration),
                thumbnailSide: settings.linkCardThumbnailSide,
                typography: PostTypography(settings: settings),
                showsSite: settings.showsLinkCardSite,
                showsImage: settings.showsLinkCardImage,
                descriptionLines: Int(settings.value(of: AppearanceCatalog.linkCardDescriptionLines)),
                lineSpacing: settings.value(of: AppearanceCatalog.linkCardLineSpacing),
                titleLines: Int(settings.value(of: AppearanceCatalog.linkCardTitleLines)),
                boldsTitle: settings.boldsLinkCardTitle,
                imageWidthRatio: settings.value(of: AppearanceCatalog.linkCardImageWidthRatio)
            )
        }
    }

    /// fxtwitterから読んだXの投稿の囲み。作者の行は名前だけを太くする。
    /// 本文はXの投稿の言語が分からないため、使う人の言語で描く。
    func xPost(_ post: XPost, media: MediaGridView.Content?, base: UIListContentConfiguration) -> EmbeddedPostView.Content {
        let typography = PostTypography(settings: settings)
        let language = settings.glyphLanguageIdentifier()
        let body = RichTextRenderer(font: typography.font(.xPostBody), textColor: .label, emojiImages: emojiImages, language: language)
        return embed(
            id: "x:\(post.id)",
            header: EmbeddedPostView.Content.Header(
                // Xのアイコンは静止画なので、アニメーションの設定によらず動かさない。
                avatar: AvatarView.Content(url: post.authorAvatar, shape: settings.avatarShape, animates: false),
                name: embedName(.plain(post.authorName, emojis: []), handle: post.authorScreenName, base: base),
                opensAccount: false
            ),
            text: body.render(post.text),
            media: media,
            openActionName: "Xの投稿を開く"
        )
    }

    /// 引用元の投稿の囲み。作者の行は名前だけを太くし、本文は引用元の投稿の言語で描く。
    /// - Parameters:
    ///   - spoiler: 引用元の注意書きかフィルターの警告。開いているかは一覧が覚えているため、置く側が決めて渡す。
    ///   - media: 引用元の添付ファイル。ぼかすかは一覧が覚えているため、置く側が決めて渡す。
    func quote(_ quoted: Status, spoiler: PostBodyContent.Spoiler?, media: MediaGridView.Content?, base: UIListContentConfiguration) -> EmbeddedPostView.Content {
        let font = PostTypography(settings: settings).font(.xPostBody)
        var notes: [EmbeddedPostView.Content.Note] = []
        // 囲みが投稿1件分に近い重さにならないよう、投票は選択肢を並べず、あることだけを示す。
        if quoted.poll != nil {
            notes.append(EmbeddedPostView.Content.Note(text: noteText("投票", symbolName: "chart.bar.xaxis", color: .secondaryLabel, font: font), isPressable: false))
        }
        switch NestedQuote(quoted.quote) {
        case .link:
            notes.append(EmbeddedPostView.Content.Note(text: noteText("引用した投稿があります", symbolName: "quote.bubble", color: .tintColor, font: font), isPressable: true))
        case .unavailable(let reason):
            notes.append(EmbeddedPostView.Content.Note(text: noteText(Self.quoteUnavailableText(reason), symbolName: "quote.bubble", color: .secondaryLabel, font: font), isPressable: false))
        case nil:
            break
        }
        return embed(
            id: "quote:\(quoted.id)",
            header: EmbeddedPostView.Content.Header(
                avatar: avatarContent(of: quoted.account),
                name: embedName(.plain(quoted.account.displayNameOrUsername, emojis: quoted.account.emojis), handle: quoted.account.acct, base: base),
                opensAccount: true
            ),
            spoiler: spoiler.map {
                SpoilerView.Content(text: $0.text, isCollapsed: $0.isCollapsed, kind: $0.kind, padding: $0.padding, buttonFont: $0.buttonFont, buttonSpacing: $0.buttonSpacing, cornerRadius: $0.cornerRadius)
            },
            text: bodyRenderer(of: quoted, font: font, color: .label).render(.status(quoted)),
            media: media,
            notes: notes,
            openActionName: "引用元の投稿を開く"
        )
    }

    /// 引用元を出せないときの囲み。作者の行を出さず、理由の1行だけを控えめな色で出す。
    /// - Parameters:
    ///   - id: 引用した投稿のID。
    ///   - revealTitle: 押して開けるときに、理由の下に添える押せることを示す文言。開けなければnil。
    func quotePlaceholder(id: Status.ID, message: String, revealTitle: String?, base: UIListContentConfiguration) -> EmbeddedPostView.Content {
        let font = PostTypography(settings: settings).font(.xPostBody)
        let text = NSMutableAttributedString(string: message, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        if let revealTitle {
            text.append(NSAttributedString(string: "\n" + revealTitle, attributes: [.font: font, .foregroundColor: UIColor.tintColor]))
        }
        var content = embed(id: "quote-placeholder:\(id)", header: nil, text: text, media: nil, openActionName: revealTitle ?? "")
        content.isPressable = revealTitle != nil
        return content
    }

    /// 引用元を出せない理由の文言。
    static func quoteUnavailableText(_ reason: QuoteDisplay.Reason) -> String {
        switch reason {
        case .pending: "承認待ちの引用です"
        case .withdrawn: "引用元の投稿者が引用を取り消しました"
        case .deleted: "引用元の投稿は削除されました"
        case .unauthorized: "引用元の投稿を表示できません"
        case .blockedAccount: "ブロックしている人の投稿です"
        case .blockedDomain: "ブロックしているドメインの人の投稿です"
        case .mutedAccount: "ミュートしている人の投稿です"
        }
    }

    /// お気に入りやブーストの通知で再掲する投稿に、囲みの代わりに添える、引用のある投稿であることを示す1行。
    func quoteNote(font: UIFont) -> NSAttributedString {
        noteText("引用した投稿", symbolName: "quote.bubble", color: .secondaryLabel, font: font)
    }

    private func embed(
        id: String,
        header: EmbeddedPostView.Content.Header?,
        spoiler: SpoilerView.Content? = nil,
        text: NSAttributedString,
        media: MediaGridView.Content?,
        notes: [EmbeddedPostView.Content.Note] = [],
        openActionName: String
    ) -> EmbeddedPostView.Content {
        EmbeddedPostView.Content(
            id: id,
            header: header,
            avatarSize: settings.value(of: AppearanceCatalog.xPostAvatarSize),
            spoiler: spoiler,
            text: text,
            media: media,
            notes: notes,
            openActionName: openActionName,
            padding: settings.value(of: AppearanceCatalog.xPostPadding),
            avatarNameSpacing: settings.value(of: AppearanceCatalog.xPostAvatarNameSpacing),
            headerSpacing: settings.value(of: AppearanceCatalog.xPostHeaderSpacing),
            mediaSpacing: settings.value(of: AppearanceCatalog.xPostMediaSpacing),
            transitionDuration: tuning.value(of: TuningCatalog.linkCardTransitionDuration)
        )
    }

    /// 囲みの作者の行。名前だけを太くし、ハンドルを控えめに添える。
    private func embedName(_ name: RichText, handle: String, base: UIListContentConfiguration) -> NSAttributedString {
        let nameFont = PostTypography(settings: settings).font(.xPostName)
        let language = settings.glyphLanguageIdentifier()
        let primary = RichTextRenderer(font: Self.boldFont(nameFont), textColor: base.textProperties.color, emojiImages: emojiImages, language: language)
        let secondary = RichTextRenderer(font: nameFont, textColor: .secondaryLabel, emojiImages: emojiImages, language: language)
        let text = NSMutableAttributedString(attributedString: primary.render(name))
        text.append(secondary.render(.plain(" @\(handle)", emojis: [])))
        return text
    }

    /// 囲みの補足の1行。先頭に記号を置く。文言はアプリのものなので、アプリの文字で描く。
    private func noteText(_ string: String, symbolName: String, color: UIColor, font: UIFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let symbol = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol.withRenderingMode(.alwaysTemplate))))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: string))
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }

    /// 投稿の注意書き。注意書きがなければnil。開いているかは一覧が覚えているため、ここでは折りたたんだ形で返す。
    /// - Parameter font: 注意書きの文字の書体。nilなら本文の文字で描く。
    func spoiler(of status: Status, base: UIListContentConfiguration, color: UIColor = .label, font: UIFont? = nil) -> PostBodyContent.Spoiler? {
        guard !status.spoilerText.isEmpty else { return nil }
        return PostBodyContent.Spoiler(
            text: bodyRenderer(of: status, font: font ?? PostTypography(settings: settings).font(.body), color: color).render(.plain(status.spoilerText, emojis: status.emojis)),
            isCollapsed: true,
            padding: settings.value(of: AppearanceCatalog.spoilerPadding),
            bodySpacing: settings.value(of: AppearanceCatalog.spoilerBodySpacing),
            buttonFont: PostTypography(settings: settings).font(.spoilerButton),
            buttonSpacing: settings.value(of: AppearanceCatalog.spoilerButtonSpacing),
            cornerRadius: settings.value(of: AppearanceCatalog.spoilerCornerRadius)
        )
    }

    /// フィルターの警告。本文の代わりに注意書きのボックスに入れて出し、開くまで本文も添付ファイルも出さない。
    /// フィルターの名前は使う人が付けたものなので、投稿の言語ではなく、アプリの文字で描く。
    func filterWarning(titles: [String], base: UIListContentConfiguration) -> PostBodyContent.Spoiler {
        let font = PostTypography(settings: settings).font(.body)
        let text = NSMutableAttributedString(string: "フィルター: ", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        text.append(NSAttributedString(string: titles.joined(separator: "、"), attributes: [.font: font, .foregroundColor: UIColor.label]))
        return PostBodyContent.Spoiler(
            text: text,
            isCollapsed: true,
            kind: .filter,
            padding: settings.value(of: AppearanceCatalog.spoilerPadding),
            bodySpacing: settings.value(of: AppearanceCatalog.spoilerBodySpacing),
            buttonFont: PostTypography(settings: settings).font(.spoilerButton),
            buttonSpacing: settings.value(of: AppearanceCatalog.spoilerButtonSpacing),
            cornerRadius: settings.value(of: AppearanceCatalog.spoilerCornerRadius)
        )
    }

    /// 自分の投稿が、自分のフィルターに一致していることを示す1行。投稿は折りたたまないので、目立たせず、本文より小さく控えめな色で描く。
    func ownFilterNote(titles: [String]) -> NSAttributedString {
        let font = PostTypography(settings: settings).font(.filterNote)
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
    private func bodyRenderer(of status: Status, font: UIFont, color: UIColor) -> RichTextRenderer {
        RichTextRenderer(
            font: font,
            textColor: color,
            paragraphSpacing: settings.value(of: AppearanceCatalog.paragraphSpacing),
            lineSpacing: settings.value(of: AppearanceCatalog.bodyLineSpacing),
            indentPerLevel: settings.value(of: AppearanceCatalog.quoteIndent),
            emojiScale: settings.value(of: AppearanceCatalog.customEmojiScale),
            emojiImages: emojiImages,
            language: settings.glyphLanguageIdentifier(for: status.language)
        )
    }
}

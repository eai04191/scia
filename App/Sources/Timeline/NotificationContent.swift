import SciaCore
import UIKit

extension TimelineViewController {
    /// 通知のセルの中身。種類ごとの組み方は`MastodonNotification.Layout`で決める。
    /// - Parameter itemID: この中身を置く行。注意書きを開閉したときに、この行の画面上の位置を保つ。
    func contentConfiguration(for notification: MastodonNotification, itemID: ItemID? = nil, base: UIListContentConfiguration) -> any UIContentConfiguration {
        switch notification.layout {
        case .post:
            guard let status = notification.status else { return headerOnlyConfiguration(for: notification, base: base) }
            return postConfiguration(for: notification, status: status, itemID: itemID, base: base)
        case .quoted(let showsPollResults):
            guard let status = notification.status else { return headerOnlyConfiguration(for: notification, base: base) }
            return quotedConfiguration(for: notification, status: status, showsPollResults: showsPollResults, itemID: itemID, base: base)
        case .headerOnly:
            return headerOnlyConfiguration(for: notification, base: base)
        }
    }

    /// メンションなど、相手が書いた投稿を読む通知。投稿として扱い、投稿の部品は「投稿の見た目」で描く。
    /// 名前の上に足す、誰が何をしたかの行だけは、通知のための部品なので「通知の見た目」で描く。
    /// 投稿した人は通知を送った人と同じで、下の名前の行にアイコンが出るため、上の行にはアイコンを出さない。
    private func postConfiguration(for notification: MastodonNotification, status: Status, itemID: ItemID?, base: UIListContentConfiguration) -> PostContentConfiguration {
        var configuration = contentConfiguration(for: status, itemID: itemID, base: base)
        let appearance = NotificationAppearance(notification.type)
        let typography = PostTypography(settings: settings)
        let renderer = RichTextRenderer(font: typography.font(.notificationContext), textColor: .secondaryLabel, emojiImages: emojiImages, language: settings.glyphLanguageIdentifier())
        // 言い回しはアプリの文言なので、言語を外し、ウィンドウに付けたアプリの言語で描く。
        func phrase(_ string: String) -> NSAttributedString {
            let rendered = NSMutableAttributedString(attributedString: renderer.render(.plain(string, emojis: [])))
            rendered.removeAttribute(.languageIdentifier, range: NSRange(location: 0, length: rendered.length))
            return rendered
        }
        let text = NSMutableAttributedString(attributedString: phrase(appearance.phrase.before))
        if appearance.phrase.includesName {
            text.append(renderer.render(.plain(notification.account.displayNameOrUsername, emojis: notification.account.emojis)))
        }
        text.append(phrase(appearance.phrase.after))
        configuration.context = PostContentConfiguration.Context(
            symbolName: appearance.symbolName,
            symbolColor: appearance.color,
            notificationSymbolFont: typography.font(.notificationHeader),
            avatar: nil,
            text: text,
            accessibilityText: text.string,
            accountName: notification.account.displayNameOrUsername
        )
        configuration.metrics.contextSymbolSpacing = settings.value(of: NotificationAppearanceCatalog.symbolSpacing)
        configuration.metrics.contextSpacing = settings.value(of: NotificationAppearanceCatalog.contextSpacing)
        configuration.onOpenContextAccount = { [weak self] in self?.onOpenProfile?(notification.account) }
        configuration.contextTarget = userTarget(for: notification.account, id: .notification(notification.id))
        return configuration
    }

    /// お気に入りやブーストなど、自分の投稿の再掲になる通知。誰が何をしたかの行を目立たせ、本文は控えめな色で短く切り、
    /// 添付ファイルは小さなサムネイルを1列だけ並べる。引用は囲みを出さず、引用のある投稿であることを示す1行にする。
    /// 再掲の縮めた形は通知のためのものなので、大きさと余白は「通知の見た目」で決める。注意書きのボックスや投票の部品は、投稿と同じ部品を使う。
    /// - Parameter showsPollResults: 投票を結果の形で足す。投票はできない形にし、選択肢は押下を受けない。
    private func quotedConfiguration(for notification: MastodonNotification, status: Status, showsPollResults: Bool, itemID: ItemID?, base: UIListContentConfiguration) -> NotificationContentConfiguration {
        typealias N = NotificationAppearanceCatalog
        let shown = status.displayed
        let typography = PostTypography(settings: settings)
        let bodyFont = typography.font(.notificationQuotedBody)
        var media = mediaContent(for: status)
        media?.arrangement = .strip(side: settings.value(of: N.quotedThumbnailSize))
        media?.spacing = settings.value(of: N.quotedThumbnailSpacing)
        var configuration = headerConfiguration(
            for: notification,
            body: PostBodyContent(
                spoiler: spoiler(of: status, base: base, color: .secondaryLabel, font: bodyFont),
                text: postContentBuilder.body(of: shown, base: base, color: .secondaryLabel, font: bodyFont),
                maximumLines: Int(settings.value(of: N.quotedBodyLines)),
                media: media,
                mediaSpacing: settings.value(of: N.quotedMediaSpacing),
                poll: showsPollResults ? pollContent(for: shown, allowsVoting: false, base: base) : nil,
                pollSpacing: settings.value(of: N.quotedPollSpacing),
                statusID: shown.id,
                hashtagAccount: shown.account,
                // 再掲では引用の囲みを出さず、引用のある投稿であることだけを、一番下の1行で示す。
                filterNote: shown.quote == nil ? nil : postContentBuilder.quoteNote(font: typography.font(.notificationQuotedNote)),
                filterNoteSpacing: settings.value(of: N.quotedNoteSpacing)
            ),
            bodySpacing: settings.value(of: N.quotedSpacing),
            base: base
        )
        configuration.bodyKind = .quotedPost
        configuration.reactionGlow = postContentBuilder.reactionGlow(for: shown)
        configuration.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination, shown) }
        configuration.onToggleSpoiler = { [weak self] in self?.toggleSpoiler(of: status, keeping: itemID) }
        if let media {
            configuration.onSelectMedia = { [weak self] index, grid in
                self?.openMedia(media.attachments, at: index, of: shown, from: grid)
            }
            configuration.onRevealMedia = { [weak self] in
                self?.revealMedia(of: shown)
            }
        }
        return configuration
    }

    /// フォローなど、誰が何をしたかの行だけの通知。誰からかが分かるよう、名前の下にハンドルを添える。
    /// ハンドルは誰が何をしたかの行の続きなので、再掲する投稿より詰めて置く。
    /// まとめた行では、並べたアイコンで誰からかが分かるため、ハンドルを添えない。
    private func headerOnlyConfiguration(for notification: MastodonNotification, base: UIListContentConfiguration) -> NotificationContentConfiguration {
        if notification.isGroup {
            return headerConfiguration(for: notification, body: PostBodyContent(text: NSAttributedString(), mediaSpacing: 0), bodySpacing: 0, base: base)
        }
        let acct = NSAttributedString(string: "@\(notification.account.acct)", attributes: [
            .font: PostTypography(settings: settings).font(.notificationAccount),
            .foregroundColor: UIColor.secondaryLabel,
        ])
        var configuration = headerConfiguration(
            for: notification,
            // ハンドルの下には添付ファイルを置かないため、本文と添付ファイルのあいだの余白は使われない。
            body: PostBodyContent(text: acct, mediaSpacing: 0),
            bodySpacing: settings.value(of: NotificationAppearanceCatalog.accountSpacing),
            base: base
        )
        configuration.bodyKind = .account
        return configuration
    }

    private func headerConfiguration(
        for notification: MastodonNotification,
        body: PostBodyContent,
        bodySpacing: CGFloat,
        base: UIListContentConfiguration
    ) -> NotificationContentConfiguration {
        typealias N = NotificationAppearanceCatalog
        let appearance = NotificationAppearance(notification.type)
        let font = PostTypography(settings: settings).font(.notificationHeader)
        let nameRenderer = RichTextRenderer(font: font, textColor: base.textProperties.color, emojiImages: emojiImages, language: settings.glyphLanguageIdentifier())
        // 言い回しはアプリの文言なので、言語を付けず、ウィンドウに付けたアプリの言語で描く。
        let phraseAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        let header = NSMutableAttributedString(string: appearance.phrase.before, attributes: phraseAttributes)
        if appearance.phrase.includesName {
            // まとめた行では、名前の前にアイコンを差し込まず、行の上にアイコンを並べる。
            if !notification.isGroup {
                header.append(avatarAttachment(of: notification.account, font: font))
            }
            header.append(nameRenderer.render(.plain(notification.account.displayNameOrUsername, emojis: notification.account.emojis)))
            if notification.isGroup {
                header.append(NSAttributedString(string: "と", attributes: phraseAttributes))
                var linkAttributes = phraseAttributes
                linkAttributes[.foregroundColor] = UIColor.tintColor
                linkAttributes[.groupAccountsLink] = true
                header.append(NSAttributedString(string: "ほか\((notification.notificationsCount - 1).formatted())人", attributes: linkAttributes))
            }
        }
        header.append(NSAttributedString(string: appearance.phrase.after, attributes: phraseAttributes))
        var configuration = NotificationContentConfiguration(
            symbolName: appearance.symbolName,
            symbolColor: appearance.color,
            header: header,
            body: body,
            metrics: NotificationContentConfiguration.Metrics(
                // 行の余白とアイコンの列は、同じ一覧に並ぶメンションなどの投稿の行と文字の列を揃えるため、「投稿の見た目」に従う。
                margins: settings.rowMargins,
                avatarSize: settings.value(of: AppearanceCatalog.avatarSize),
                headerFont: font,
                bodySpacing: bodySpacing,
                symbolSpacing: settings.value(of: N.symbolSpacing),
                avatarSpacing: settings.value(of: AppearanceCatalog.avatarSpacing),
                groupAvatarSize: settings.value(of: N.groupAvatarSize),
                groupAvatarSpacing: settings.value(of: N.groupAvatarSpacing),
                groupAvatarHeaderSpacing: settings.value(of: N.groupAvatarHeaderSpacing)
            ),
            mediaImages: mediaImages,
            avatarImages: avatarImages,
            emojiImages: settings.animatesCustomEmojis ? emojiImages : nil
        )
        if appearance.phrase.includesName {
            configuration.accountName = notification.account.displayNameOrUsername
            configuration.onOpenAccount = { [weak self] in self?.onOpenProfile?(notification.account) }
            configuration.accountTarget = userTarget(for: notification.account, id: .notification(notification.id))
        }
        if notification.isGroup {
            let accounts = notification.sampleAccounts
            configuration.groupAvatars = accounts.map(avatarContent(of:))
            configuration.groupAccountNames = accounts.map(\.displayNameOrUsername)
            configuration.onOpenGroupAccount = { [weak self] index in
                guard accounts.indices.contains(index) else { return }
                self?.onOpenProfile?(accounts[index])
            }
            configuration.onOpenGroupAccounts = { [weak self] in self?.onOpenGroupAccounts?(notification) }
            configuration.groupAccountTargets = accounts.map { userTarget(for: $0, id: .notification(notification.id)) }
        }
        return configuration
    }
}

extension TimelineViewController {
    /// 通知を送った人の名前の前に置くアイコン。行の上下の中央に置き、そうすると字面の下端より下に出る大きさなら、下端を字面の下端に揃えて上へ伸ばす。
    /// 下に続く本文は字面の下端から測って置くので、それより下へ出ると、余白が設定より狭くなったり重なったりするため。
    /// 届くまでは同じ大きさの灰色で場所を取っておく。
    /// サーバーがアイコンのURLを返さなかったときも、灰色のままにする。大きさを0にしたときは、アイコンもすき間も置かない。
    private func avatarAttachment(of account: Account, font: UIFont) -> NSAttributedString {
        let side = headerAvatarSide
        guard side > 0 else { return NSAttributedString() }
        let content = avatarContent(of: account)
        let image = notificationAvatarKey(of: account, side: side).flatMap(avatarImages.requestImage(for:))
        let attachment = NSTextAttachment()
        attachment.image = Self.shapedAvatar(image, side: side, shape: content.shape, cornerRatio: content.cornerRatio)
        attachment.bounds = CGRect(x: 0, y: max((font.ascender + font.descender - side) / 2, -font.pointSize * PostBodyView.emBoxDescent), width: side, height: side)
        let string = NSMutableAttributedString(attachment: attachment)
        // 画像の添付の文字には字送りが効かないので、後ろに空白を置き、空白の幅を差し引いた字送りで、すき間を設定の値にする。
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let spacing = settings.value(of: NotificationAppearanceCatalog.headerAvatarNameSpacing)
        string.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: spacing - spaceWidth]))
        return string
    }

    /// 名前の前に置くアイコンの一辺。
    private var headerAvatarSide: CGFloat {
        settings.value(of: NotificationAppearanceCatalog.headerAvatarSize)
    }

    /// 通知の組み方ごとに、`contentConfiguration(for:itemID:base:)`が描くアイコン。
    func avatarKeys(for notification: MastodonNotification) -> [AvatarImageKey] {
        // 投稿として組む通知は、投稿と同じアイコンを出し、誰が何をしたかの行にはアイコンを出さない。
        if case .post = notification.layout, let status = notification.status {
            return avatarKeys(for: status)
        }
        guard NotificationAppearance(notification.type).phrase.includesName else { return [] }
        if notification.isGroup {
            let side = settings.value(of: NotificationAppearanceCatalog.groupAvatarSize)
            guard side > 0 else { return [] }
            return notification.sampleAccounts.compactMap { account in
                let content = avatarContent(of: account)
                return content.url.map { AvatarView.key(url: $0, animates: content.animates, side: side, scale: traitCollection.displayScale) }
            }
        }
        let side = headerAvatarSide
        guard side > 0 else { return [] }
        return notificationAvatarKey(of: notification.account, side: side).map { [$0] } ?? []
    }

    /// 名前の前に差し込むアイコンの画像。文字に描き込むため、動くアイコンでも先頭のコマで止める。URLがなければnil。
    private func notificationAvatarKey(of account: Account, side: CGFloat) -> AvatarImageKey? {
        avatarContent(of: account).url.map { url in
            AvatarView.key(url: url, animates: false, side: side, scale: traitCollection.displayScale)
        }
    }

    private static func shapedAvatar(_ image: UIImage?, side: CGFloat, shape: AvatarShape, cornerRatio: CGFloat) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size).image { _ in
            let radius = switch shape {
            case .circle: side / 2
            case .roundedSquare: side * cornerRatio
            }
            UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
            if let image, image.size.width > 0, image.size.height > 0 {
                // 正方形でない画像は、短い辺に合わせて中央を切り抜く。
                let scale = side / min(image.size.width, image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            } else {
                UIColor.secondarySystemFill.setFill()
                UIRectFill(rect)
            }
        }
    }
}

extension NotificationAppearance {
    /// 通知の種類の記号の色。
    var color: UIColor {
        switch tint {
        case .accent: .tintColor
        case .green: .systemGreen
        case .orange: .systemOrange
        case .secondary: .secondaryLabel
        }
    }
}

import SciaCore
import UIKit

extension TimelineViewController {
    /// 通知のセルの中身。種類ごとの組み方は`MastodonNotification.Layout`で決める。
    func contentConfiguration(for notification: MastodonNotification, base: UIListContentConfiguration) -> any UIContentConfiguration {
        switch notification.layout {
        case .post:
            guard let status = notification.status else { return headerOnlyConfiguration(for: notification, base: base) }
            return postConfiguration(for: notification, status: status, base: base)
        case .quoted:
            // 投票の終了の通知（showsPollResults）では、投票の部品ができたら、ここで投票を結果の形で足す。
            guard let status = notification.status else { return headerOnlyConfiguration(for: notification, base: base) }
            return quotedConfiguration(for: notification, status: status, base: base)
        case .headerOnly:
            return headerOnlyConfiguration(for: notification, base: base)
        }
    }

    /// メンションなど、相手が書いた投稿を読む通知。ホームの投稿と同じ見た目にし、名前の上に誰が何をしたかの行を足す。
    /// 投稿した人は通知を送った人と同じで、下の名前の行にアイコンが出るため、上の行にはアイコンを出さない。
    private func postConfiguration(for notification: MastodonNotification, status: Status, base: UIListContentConfiguration) -> PostContentConfiguration {
        var configuration = contentConfiguration(for: status, base: base)
        let appearance = NotificationAppearance(notification.type)
        let renderer = RichTextRenderer(font: base.secondaryTextProperties.font, textColor: .secondaryLabel, emojiImages: emojiImages)
        let text = NSMutableAttributedString(attributedString: renderer.render(.plain(appearance.phrase.before, emojis: [])))
        if appearance.phrase.includesName {
            text.append(renderer.render(.plain(notification.account.displayNameOrUsername, emojis: notification.account.emojis)))
        }
        text.append(renderer.render(.plain(appearance.phrase.after, emojis: [])))
        configuration.context = PostContentConfiguration.Context(
            symbolName: appearance.symbolName,
            symbolColor: appearance.color,
            isNotificationSymbol: true,
            avatar: nil,
            text: text,
            accessibilityText: text.string
        )
        configuration.onOpenContextAccount = { [weak self] in self?.onOpenProfile?(notification.account) }
        return configuration
    }

    /// お気に入りやブーストなど、自分の投稿の再掲になる通知。誰が何をしたかの行を目立たせ、本文は控えめな色で短く切り、
    /// 添付ファイルは小さなサムネイルを1列だけ並べる。
    private func quotedConfiguration(for notification: MastodonNotification, status: Status, base: UIListContentConfiguration) -> NotificationContentConfiguration {
        let shown = status.displayed
        var media = mediaContent(for: shown)
        media?.arrangement = .strip(side: tuning.value(of: TuningCatalog.notificationQuotedThumbnailSize))
        var configuration = headerConfiguration(
            for: notification,
            body: PostBodyContent(
                text: body(of: shown, base: base, color: .secondaryLabel),
                maximumLines: Int(tuning.value(of: TuningCatalog.notificationQuotedBodyLines)),
                media: media
            ),
            bodySpacing: tuning.value(of: TuningCatalog.notificationQuotedSpacing),
            base: base
        )
        configuration.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination, shown) }
        if let media {
            configuration.onSelectMedia = { [weak self] index, grid in
                self?.openMedia(media.attachments, at: index, of: shown, from: grid)
            }
            configuration.onRevealMedia = { [weak self] in
                self?.revealMedia(of: shown.id)
            }
        }
        return configuration
    }

    /// フォローなど、誰が何をしたかの行だけの通知。誰からかが分かるよう、名前の下にアカウントを添える。
    /// アカウントは誰が何をしたかの行の続きなので、再掲する投稿より詰めて置く。
    private func headerOnlyConfiguration(for notification: MastodonNotification, base: UIListContentConfiguration) -> NotificationContentConfiguration {
        let acct = NSAttributedString(string: "@\(notification.account.acct)", attributes: [
            .font: base.secondaryTextProperties.font,
            .foregroundColor: UIColor.secondaryLabel,
        ])
        return headerConfiguration(for: notification, body: PostBodyContent(text: acct), bodySpacing: Self.headerDetailSpacing, base: base)
    }

    /// 誰が何をしたかの行と、その下に添えるアカウントのあいだの余白。投稿のセルの名前の行と本文のあいだと揃える。
    private static let headerDetailSpacing: CGFloat = 2

    private func headerConfiguration(
        for notification: MastodonNotification,
        body: PostBodyContent,
        bodySpacing: CGFloat,
        base: UIListContentConfiguration
    ) -> NotificationContentConfiguration {
        let appearance = NotificationAppearance(notification.type)
        let font = base.textProperties.font
        let nameRenderer = RichTextRenderer(font: font, textColor: base.textProperties.color, emojiImages: emojiImages)
        let phraseAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        let header = NSMutableAttributedString(string: appearance.phrase.before, attributes: phraseAttributes)
        if appearance.phrase.includesName {
            header.append(avatarAttachment(of: notification.account, font: font))
            header.append(nameRenderer.render(.plain(notification.account.displayNameOrUsername, emojis: notification.account.emojis)))
        }
        header.append(NSAttributedString(string: appearance.phrase.after, attributes: phraseAttributes))
        var configuration = NotificationContentConfiguration(
            symbolName: appearance.symbolName,
            symbolColor: appearance.color,
            header: header,
            body: body,
            metrics: NotificationContentConfiguration.Metrics(
                margins: base.directionalLayoutMargins,
                avatarSize: tuning.value(of: TuningCatalog.avatarSize),
                headerFont: font,
                bodySpacing: bodySpacing,
                symbolSpacing: tuning.value(of: TuningCatalog.contextSymbolSpacing)
            ),
            mediaImages: mediaImages
        )
        if appearance.phrase.includesName {
            configuration.onOpenAccount = { [weak self] in self?.onOpenProfile?(notification.account) }
        }
        return configuration
    }
}

extension TimelineViewController {
    /// 通知を送った人の名前の前に置く、文字と同じ高さのアイコン。届くまでは同じ大きさの灰色で場所を取っておく。
    /// サーバーがアイコンのURLを返さなかったときも、灰色のままにする。
    private func avatarAttachment(of account: Account, font: UIFont) -> NSAttributedString {
        let side = font.lineHeight
        let content = avatarContent(of: account)
        let image = content.url.flatMap { url in
            avatarImages.requestImage(for: AvatarImageStore.Key(url: url, maxPixelSize: Int((side * traitCollection.displayScale).rounded(.up)), animates: false))
        }
        let attachment = NSTextAttachment()
        attachment.image = Self.shapedAvatar(image, side: side, shape: content.shape)
        attachment.bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
        let string = NSMutableAttributedString(attachment: attachment)
        // アイコンと名前のあいだを空ける。
        string.append(NSAttributedString(string: " ", attributes: [.font: font]))
        return string
    }

    private static func shapedAvatar(_ image: UIImage?, side: CGFloat, shape: AvatarShape) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size).image { _ in
            let radius = switch shape {
            case .circle: side / 2
            case .roundedSquare: side * 0.2
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

/// 通知の種類ごとの見た目と文言。
private struct NotificationAppearance {
    /// 操作したアカウントの名前の前後に置く文言。
    struct Phrase {
        let before: String
        let after: String
        let includesName: Bool

        static func named(_ after: String) -> Phrase {
            named("", after)
        }

        static func named(_ before: String, _ after: String) -> Phrase {
            Phrase(before: before, after: after, includesName: true)
        }

        static func unnamed(_ text: String) -> Phrase {
            Phrase(before: text, after: "", includesName: false)
        }
    }

    let symbolName: String
    let color: UIColor
    let phrase: Phrase

    init(_ kind: MastodonNotification.Kind) {
        (symbolName, color, phrase) = switch kind {
        case .mention: ("at", .tintColor, .named("からのメンション"))
        case .status: ("bell.fill", .tintColor, .named("が投稿しました"))
        case .reblog: ("arrow.2.squarepath", .systemGreen, .named("がブーストしました"))
        case .favourite: ("star.fill", .systemOrange, .named("がお気に入りに登録しました"))
        case .follow: ("person.fill.badge.plus", .tintColor, .named("にフォローされました"))
        case .followRequest: ("person.badge.clock.fill", .tintColor, .named("からフォローリクエストが届きました"))
        case .poll: ("chart.bar.fill", .tintColor, .unnamed("投票が終了しました"))
        case .update: ("pencil", .secondaryLabel, .named("がブーストした投稿を編集しました"))
        case .quote: ("quote.bubble.fill", .tintColor, .named("が引用しました"))
        case .quotedUpdate: ("pencil", .secondaryLabel, .named("引用した投稿を", "が編集しました"))
        // 種類を知らない通知も、誰からかだけは分かるように出す。
        case .other(let rawValue): ("bell", .secondaryLabel, .named("からの通知（\(rawValue)）"))
        }
    }
}

import SciaCore
import UIKit

extension TimelineViewController {
    /// 通知のセル。種類のアイコン、誰が何をしたか、対象の投稿の本文を並べる。
    func contentConfiguration(for notification: MastodonNotification, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        let appearance = NotificationAppearance(notification.type)
        content.image = UIImage(systemName: appearance.symbolName)
        content.imageProperties.tintColor = appearance.color
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)

        let font = base.textProperties.font
        let nameRenderer = RichTextRenderer(font: font, textColor: base.textProperties.color, emojiImages: emojiImages)
        let phraseAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        let header = NSMutableAttributedString(string: appearance.phrase.before, attributes: phraseAttributes)
        if appearance.phrase.includesName {
            header.append(avatarAttachment(of: notification.account, font: font))
            header.append(nameRenderer.render(.plain(notification.account.displayNameOrUsername, emojis: notification.account.emojis)))
        }
        header.append(NSAttributedString(string: appearance.phrase.after, attributes: phraseAttributes))
        content.attributedText = header

        if let status = notification.status {
            // お気に入りやブーストの通知の本文は自分の投稿の再掲なので、控えめにして誰が何をしたかの行を目立たせる。
            content.secondaryAttributedText = body(of: status.displayed, base: base, color: notification.type.isConversation ? .label : .secondaryLabel)
        } else {
            content.secondaryAttributedText = NSAttributedString(string: "@\(notification.account.acct)", attributes: [
                .font: base.secondaryTextProperties.font,
                .foregroundColor: UIColor.secondaryLabel,
            ])
        }
        return content
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

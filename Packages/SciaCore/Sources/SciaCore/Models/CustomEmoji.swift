public import Foundation

/// https://docs.joinmastodon.org/entities/CustomEmoji/
public struct CustomEmoji: Codable, Hashable, Sendable {
    public let shortcode: String
    public let url: URL
    /// アニメーションしない版。
    public let staticUrl: URL

    public init(shortcode: String, url: URL, staticUrl: URL) {
        self.shortcode = shortcode
        self.url = url
        self.staticUrl = staticUrl
    }

    /// 絵文字の画像を、メディアのメニューとビューアで扱う添付ファイルとして表す。
    /// 元の画像はアニメーションすることがあるため、共有と保存ではそのまま渡し、アニメーションしない版を届くまでの下地にする。
    /// IDは添付ファイルのIDと混ざらないよう、画像のURLから作る。サーバーごとに同じショートコードで別の絵文字がありうるため、ショートコードでは作らない。
    public var attachment: MediaAttachment {
        MediaAttachment(id: "emoji:\(url.absoluteString)", type: .image, url: url, previewUrl: staticUrl)
    }
}

extension Status {
    /// 投稿の行に描くカスタム絵文字。本文、注意書き、投票の選択肢の絵文字に、投稿した人の表示名の絵文字を続ける。
    /// ブーストなら元の投稿のものに、ブーストした人の表示名の絵文字を続ける。同じ画像の絵文字は、先に出るほうで1度だけ数える。
    public var emojisInRow: [CustomEmoji] {
        var seen: Set<URL> = []
        let booster = reblog == nil ? [] : account.displayNameEmojis
        return (displayed.emojis + displayed.account.displayNameEmojis + booster).filter { seen.insert($0.url).inserted }
    }
}

extension Account {
    /// 表示名に描くカスタム絵文字を、出てくる順に並べる。`emojis`は自己紹介や補足情報の絵文字も含むため、表示名で使っているものに絞る。
    public var displayNameEmojis: [CustomEmoji] {
        RichText.plain(displayNameOrUsername, emojis: emojis).blocks.flatMap(\.inlines).compactMap { inline in
            if case .emoji(let emoji) = inline { emoji } else { nil }
        }
    }
}

extension MastodonNotification {
    /// 通知の行に描くカスタム絵文字。対象の投稿の絵文字に、通知した人の表示名の絵文字を続ける。同じ画像の絵文字は、先に出るほうで1度だけ数える。
    public var emojisInRow: [CustomEmoji] {
        var seen: Set<URL> = []
        return ((status?.emojisInRow ?? []) + account.displayNameEmojis).filter { seen.insert($0.url).inserted }
    }
}

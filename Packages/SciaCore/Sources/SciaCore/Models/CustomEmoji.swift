public import Foundation

/// https://docs.joinmastodon.org/entities/CustomEmoji/
public struct CustomEmoji: Codable, Hashable, Sendable {
    public let shortcode: String
    public let url: URL
    /// アニメーションしない版。
    public let staticUrl: URL
    /// 絵文字を持つサーバー。nilならログインしているサーバー。APIは返さないので、投稿やアカウントを読むときに、書いた人のサーバーを付ける。
    /// Mastodonは、本文や表示名の絵文字を、書いた人のサーバーの絵文字から付けるため（docs/animated-custom-emoji.mdの「絵文字ごとの描き方」）。
    /// 投稿やアカウントは、読むたびに付け直す。保存した絵文字（補完で選んだ人の表示名など）は、保存したサーバーを読み戻す。
    public internal(set) var domain: String?

    public init(shortcode: String, url: URL, staticUrl: URL, domain: String? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.staticUrl = staticUrl
        self.domain = domain
    }

    /// 画像のURLは、読み込む画像として受け付けるスキームでなければ、絵文字ごと読めないものとする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcode = try container.decode(String.self, forKey: .shortcode)
        url = try container.decodeRequiredURL(.media, forKey: .url)
        staticUrl = try container.decodeRequiredURL(.media, forKey: .staticUrl)
        domain = container.decodeLossyIfPresent(String.self, forKey: .domain)
    }

    /// 絵文字の画像を、メディアのメニューとビューアで扱う添付ファイルとして表す。
    /// 元の画像はアニメーションすることがあるため、共有と保存ではそのまま渡し、アニメーションしない版を届くまでの下地にする。
    /// IDは添付ファイルのIDと混ざらないよう、画像のURLから作る。サーバーごとに同じショートコードで別の絵文字がありうるため、ショートコードでは作らない。
    public var attachment: MediaAttachment {
        MediaAttachment(id: "emoji:\(url.absoluteString)", type: .image, url: url, previewUrl: staticUrl)
    }
}

extension [CustomEmoji] {
    /// `domain`のサーバーの絵文字として付け直したもの。
    func owned(by domain: String?) -> [CustomEmoji] {
        map { emoji in
            var emoji = emoji
            emoji.domain = domain
            return emoji
        }
    }
}

extension Account {
    /// この人が書いた本文や表示名の絵文字を持つサーバー。ログインしているサーバーの人ならnil。
    var emojiDomain: String? { Self.emojiDomain(ofAcct: acct) }

    static func emojiDomain(ofAcct acct: String) -> String? {
        let parts = acct.split(separator: "@", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : nil
    }
}

extension Status {
    /// 投稿の行に描くカスタム絵文字。本文、注意書き、投票の選択肢の絵文字に、投稿した人の表示名の絵文字を続ける。
    /// ブーストなら元の投稿のものに、ブーストした人の表示名の絵文字を続ける。同じ画像の絵文字は、先に出るほうで1度だけ数える。
    public var emojisInRow: [CustomEmoji] {
        var seen: Set<URL> = []
        let booster = reblog == nil ? [] : account.displayNameEmojis
        return (displayed.emojis + (displayed.poll?.emojis ?? []) + displayed.account.displayNameEmojis + booster).filter { seen.insert($0.url).inserted }
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

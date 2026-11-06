public import Foundation

/// サーバーで使えるカスタム絵文字のリストの1つ。投稿に付いて届く`CustomEmoji`と違い、絵文字の選択に出すかを持つ。
/// https://docs.joinmastodon.org/methods/custom_emojis/
public struct ServerEmoji: Decodable, Hashable, Sendable {
    public let shortcode: String
    public let url: URL
    public let staticUrl: URL
    /// 管理者がピッカーに出さないと決めた絵文字はfalse。web UIの絵文字の選択と同じく、補完の候補にも出さない。
    public let visibleInPicker: Bool
    public let category: String?
    /// 画像の縦横比（幅/高さ）。Fedibirdが`width`と`height`で返す。Mastodonは返さないのでnil。
    /// Mastodonでは、画像が届いたときに分かった縦横比を`CustomEmojiCache`が残し、パレットに渡すときに`withAspectRatio(_:)`で入れる。
    public let aspectRatio: Double?

    public init(shortcode: String, url: URL, staticUrl: URL, visibleInPicker: Bool = true, category: String? = nil, aspectRatio: Double? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.staticUrl = staticUrl
        self.visibleInPicker = visibleInPicker
        self.category = category
        self.aspectRatio = aspectRatio
    }

    private enum CodingKeys: String, CodingKey {
        case shortcode, url, staticUrl, visibleInPicker, category, width, height
    }

    /// 選択に出すかを返さないサーバーでは、出すものとして扱う。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcode = try container.decode(String.self, forKey: .shortcode)
        url = try container.decodeRequiredURL(.media, forKey: .url)
        staticUrl = try container.decodeRequiredURL(.media, forKey: .staticUrl)
        visibleInPicker = (try? container.decodeIfPresent(Bool.self, forKey: .visibleInPicker)) ?? true
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        // 幅か高さが0か、読めなければ、縦横比は分からないものとする。
        let width = (try? container.decodeCountIfPresent(forKey: .width)) ?? nil
        let height = (try? container.decodeCountIfPresent(forKey: .height)) ?? nil
        aspectRatio = if let width, let height, width > 0, height > 0 { Double(width) / Double(height) } else { nil }
    }

    /// 同じショートコードの絵文字のうち、後に来た1件だけを、その位置に残す。Mastodonのwebも、ショートコードをキーに応答の順で保存するので、後に来たものが残る。
    /// Mastodonはショートコードの重なりをアプリで止めているが、データベースの一意の索引は`domain`がNULLのサーバーの絵文字では効かず、同じショートコードを2件ずつ返すサーバーがあった。
    /// 投稿の本文の絵文字は、サーバーがどちらか1件を選んで投稿に付けるので、2件を並べても選び分けられない。
    public static func lastOfEachShortcode(_ emojis: [ServerEmoji]) -> [ServerEmoji] {
        var seen: Set<String> = []
        return emojis.reversed().filter { seen.insert($0.shortcode).inserted }.reversed()
    }

    /// 縦横比を`aspectRatio`にした絵文字。
    public func withAspectRatio(_ aspectRatio: Double?) -> ServerEmoji {
        ServerEmoji(shortcode: shortcode, url: url, staticUrl: staticUrl, visibleInPicker: visibleInPicker, category: category, aspectRatio: aspectRatio)
    }

    public var emoji: CustomEmoji {
        CustomEmoji(shortcode: shortcode, url: url, staticUrl: staticUrl)
    }
}

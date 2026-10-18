public import Foundation

/// サーバーで使えるカスタム絵文字の一覧の1つ。投稿に付いて届く`CustomEmoji`と違い、絵文字の選択に出すかを持つ。
/// https://docs.joinmastodon.org/methods/custom_emojis/
public struct ServerEmoji: Decodable, Hashable, Sendable {
    public let shortcode: String
    public let url: URL
    public let staticUrl: URL
    /// 管理者が一覧に出さないと決めた絵文字はfalse。web UIの絵文字の選択と同じく、補完の候補にも出さない。
    public let visibleInPicker: Bool
    public let category: String?

    public init(shortcode: String, url: URL, staticUrl: URL, visibleInPicker: Bool = true, category: String? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.staticUrl = staticUrl
        self.visibleInPicker = visibleInPicker
        self.category = category
    }

    private enum CodingKeys: String, CodingKey {
        case shortcode, url, staticUrl, visibleInPicker, category
    }

    /// 選択に出すかを返さないサーバーでは、出すものとして扱う。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcode = try container.decode(String.self, forKey: .shortcode)
        url = try container.decode(URL.self, forKey: .url)
        staticUrl = try container.decode(URL.self, forKey: .staticUrl)
        visibleInPicker = (try? container.decodeIfPresent(Bool.self, forKey: .visibleInPicker)) ?? true
        category = try? container.decodeIfPresent(String.self, forKey: .category)
    }

    public var emoji: CustomEmoji {
        CustomEmoji(shortcode: shortcode, url: url, staticUrl: staticUrl)
    }
}

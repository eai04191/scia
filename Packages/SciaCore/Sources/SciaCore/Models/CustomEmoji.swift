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
}

public import Foundation

/// 本文のリンク先から作ったカード。
/// https://docs.joinmastodon.org/entities/PreviewCard/
public struct PreviewCard: Codable, Hashable, Sendable {
    /// リンク先。
    public let url: URL
    public let title: String
    public let description: String
    public let type: Kind
    /// リンク先の作者。Mastodon 4.3で非推奨になり、いずれ返らなくなるため、無ければnil。
    public let authorName: String?
    /// リンク先のサイトの名前。
    public let providerName: String
    /// サムネイル。サーバーによって空で返るため、読めなければnil。
    public let image: URL?
    /// サムネイルの幅と高さ。Mastodonは分からないとき0を返す。
    public let width: Int
    public let height: Int
    /// ぼかした下地を描くための文字列。
    public let blurhash: String?

    public init(
        url: URL,
        title: String,
        description: String,
        type: Kind,
        authorName: String? = nil,
        providerName: String,
        image: URL? = nil,
        width: Int = 0,
        height: Int = 0,
        blurhash: String? = nil
    ) {
        self.url = url
        self.title = title
        self.description = description
        self.type = type
        self.authorName = authorName
        self.providerName = providerName
        self.image = image
        self.width = width
        self.height = height
        self.blurhash = blurhash
    }

    /// リンク先のURLは、開く先がなければカードとして使えないため、読めなければ、またはhttpとhttps以外ならカードごと読めないものとする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeRequiredURL(.destination, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        type = try container.decode(Kind.self, forKey: .type)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        providerName = try container.decode(String.self, forKey: .providerName)
        image = container.decodeURL(.media, forKey: .image)
        width = try container.decodeCount(forKey: .width)
        height = try container.decodeCount(forKey: .height)
        blurhash = try container.decodeIfPresent(String.self, forKey: .blurhash)
    }

    public enum Kind: Hashable, Sendable, Codable {
        case link
        case photo
        case video
        /// iframeで埋め込むもの。Mastodonは今は作らない。
        case rich
        /// このアプリが知らない種類。
        case unknown(String)

        public init(rawValue: String) {
            self = switch rawValue {
            case "link": .link
            case "photo": .photo
            case "video": .video
            case "rich": .rich
            default: .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .link: "link"
            case .photo: "photo"
            case .video: "video"
            case .rich: "rich"
            case .unknown(let rawValue): rawValue
            }
        }

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

extension PreviewCard {
    /// サムネイルを、ビューアで開く添付ファイルとして表す。サムネイルがなければnil。
    /// IDは添付ファイルのIDと混ざらないよう、カードのリンク先から作る。大きさはMastodonが分からないとき0を返すため、そのときは持たせない。
    public var imageAttachment: MediaAttachment? {
        guard let image else { return nil }
        let size = width > 0 && height > 0 ? MediaAttachment.Size(width: width, height: height) : nil
        return MediaAttachment(
            id: "card:\(url.absoluteString)",
            type: .image,
            url: image,
            previewUrl: image,
            meta: size.map { MediaAttachment.Meta(original: $0) },
            blurhash: blurhash
        )
    }
}

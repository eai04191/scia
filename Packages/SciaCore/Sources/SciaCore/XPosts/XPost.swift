public import Foundation

/// Xの投稿。リンクカードの代わりに、引用のような囲みで、作者、本文、添付ファイルを出すために読む。
///
/// サーバーのカードは、Xの投稿には画像を1枚しか付けず、動画のURLも2枚目以降の画像もないため、fxtwitterのAPIから読む。
/// https://github.com/FxEmbed/FxEmbed
public struct XPost: Hashable, Sendable {
    public let id: String
    public let url: URL
    public let authorName: String
    public let authorScreenName: String
    public let authorAvatar: URL?
    /// 本文。URL、ハッシュタグ、メンションはリンクにしてある。
    public let text: RichText
    public let createdAt: Date?
    /// 添付ファイル。ビューアで開けるよう、Mastodonの添付ファイルの形にしてある。
    public let media: [MediaAttachment]

    public init(
        id: String,
        url: URL,
        authorName: String,
        authorScreenName: String,
        authorAvatar: URL? = nil,
        text: RichText,
        createdAt: Date? = nil,
        media: [MediaAttachment] = []
    ) {
        self.id = id
        self.url = url
        self.authorName = authorName
        self.authorScreenName = authorScreenName
        self.authorAvatar = authorAvatar
        self.text = text
        self.createdAt = createdAt
        self.media = media
    }
}

/// Xの投稿へのリンク。
public enum XPostLink {
    /// Xの投稿のホスト。fxtwitterなどの埋め込み用のドメインに書き換えたリンクも、同じ投稿として扱う。
    static let hosts: Set<String> = [
        "x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com",
        "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com",
    ]

    /// `status`に出すリンクカードが、Xの投稿へのリンクなら、その投稿のID。ブーストなら、ブーストされた投稿を渡す。
    public static func postID(of status: Status) -> String? {
        LinkCard(status: status).flatMap { postID(in: $0.url) }
    }

    /// `url`がXの投稿へのリンクなら、その投稿のID。`/<名前>/status/<ID>`と`/i/web/status/<ID>`の形を読む。
    public static func postID(in url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased()
        else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        guard hosts.contains(host) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let index = components.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              index > 0, components.indices.contains(index + 1)
        else { return nil }
        let id = components[index + 1]
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
        return id
    }
}

/// fxtwitterのAPIの応答。使うものだけを読む。
struct FxTwitterResponse: Decodable {
    let code: Int
    let tweet: Tweet?

    struct Tweet: Decodable {
        let id: String
        let url: URL
        let rawText: RawText
        let createdTimestamp: Double?
        let author: Author
        let media: Media?
    }

    /// Xの本文と、リンクの位置。`text`はXの元の本文で、`&`、`<`、`>`は文字参照のまま入っている。
    struct RawText: Decodable {
        let text: String
        /// Xで本文として見せる範囲。末尾の添付ファイルのt.coのURLを除く。
        let displayTextRange: [Int]?
        let facets: [Facet]
    }

    struct Facet: Decodable {
        /// `url`、`hashtag`、`mention`、`media`、`symbol`、長い投稿の`bold`など。
        let type: String
        /// `text`の中の位置。Unicodeのスカラー値で数える。
        let indices: [Int]
        /// URLならt.coのURL、ハッシュタグなら`#`を除いた名前、メンションなら`@`を除いたユーザー名。
        let original: String?
        /// URLの、t.coを展開した先。
        let replacement: String?
        /// URLの、本文に見せる短い形。
        let display: String?
    }

    struct Author: Decodable {
        let name: String
        let screenName: String
        let avatarUrl: URL?
    }

    struct Media: Decodable {
        let all: [Item]?
    }

    struct Item: Decodable {
        let id: String?
        let type: String
        let url: URL
        let thumbnailUrl: URL?
        let width: Int?
        let height: Int?
        let altText: String?
    }
}

extension XPost {
    init(_ tweet: FxTwitterResponse.Tweet) {
        self.init(
            id: tweet.id,
            url: tweet.url,
            authorName: tweet.author.name,
            authorScreenName: tweet.author.screenName,
            authorAvatar: tweet.author.avatarUrl.flatMap(ServerURLKind.media.accepting),
            text: RichText(xPost: tweet.rawText),
            createdAt: tweet.createdTimestamp.map { Date(timeIntervalSince1970: $0) },
            media: (tweet.media?.all ?? []).enumerated().compactMap { index, item in
                MediaAttachment(item, postID: tweet.id, index: index)
            }
        )
    }
}

extension MediaAttachment {
    /// fxtwitterの添付ファイル。知らない種類は出さない。
    /// IDは一覧とビューアの中で添付ファイルを見分けるのに使うため、Mastodonの添付ファイルと重ならないよう、`x:`を付ける。
    init?(_ item: FxTwitterResponse.Item, postID: String, index: Int) {
        // fxtwitterの応答もサーバーから来る値なので、Mastodonの添付ファイルと同じく、読み込むURLのスキームを確かめる。
        guard ServerURLKind.media.accepts(item.url) else { return nil }
        let kind: Kind
        let preview: URL?
        let size = Size(width: item.width, height: item.height)
        // 一覧が元の画像を読むかを決めるのに使うため、プレビュー画像の実際の大きさを入れる。動画とGIFの静止画は元の大きさで返る。
        let previewSize: Size
        switch item.type {
        case "photo":
            kind = .image
            preview = Self.smallPhotoURL(item.url)
            previewSize = Self.smallPhotoSize(of: size)
        case "video":
            kind = .video
            preview = item.thumbnailUrl.flatMap(ServerURLKind.media.accepting)
            previewSize = size
        case "gif":
            kind = .gifv
            preview = item.thumbnailUrl.flatMap(ServerURLKind.media.accepting)
            previewSize = size
        default:
            return nil
        }
        self.init(
            id: "x:\(postID):\(item.id ?? String(index))",
            type: kind,
            url: item.url,
            previewUrl: preview,
            description: item.altText,
            meta: Meta(original: size, small: previewSize)
        )
    }

    /// Xの`name=small`の画像の、長い辺の上限。
    static let smallPhotoMaxSide = 680.0

    /// `name=small`の画像の大きさ。長い辺を`smallPhotoMaxSide`に収め、元の画像より大きくはしない。大きさが分からなければ分からないまま返す。
    private static func smallPhotoSize(of size: Size) -> Size {
        guard let width = size.width, let height = size.height, width > 0, height > 0 else { return size }
        let scale = min(smallPhotoMaxSide / Double(max(width, height)), 1)
        return Size(width: Int((Double(width) * scale).rounded()), height: Int((Double(height) * scale).rounded()))
    }

    /// Xの画像は、`name`で縮小した版を選べる。fxtwitterは元の大きさ（`orig`）のURLを返すため、一覧には縮小した版を使う。
    private static func smallPhotoURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "name" }
        items.append(URLQueryItem(name: "name", value: "small"))
        components.queryItems = items
        return components.url ?? url
    }
}

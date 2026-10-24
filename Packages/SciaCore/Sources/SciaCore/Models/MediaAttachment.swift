public import Foundation

/// 投稿の添付ファイル。
/// https://docs.joinmastodon.org/entities/MediaAttachment/
public struct MediaAttachment: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let type: Kind
    /// 元の大きさのファイル。サーバーが処理中のときはnil。
    public let url: URL?
    /// 縮小したプレビュー画像。動画とGIFでは静止画になる。
    public let previewUrl: URL?
    /// 他のサーバーの投稿で、元のファイルがあるURL。
    public let remoteUrl: URL?
    /// 他のサーバーの投稿で、作者が付けたサムネイルの元のURL。作者が付けていなければnil。
    /// 送る側のMastodonは、付けたときだけ添付に`icon`を付けて送り、受け取る側はそれをここに入れる。
    public let previewRemoteUrl: URL?
    /// 代替テキスト。
    public let description: String?
    public let meta: Meta?
    /// ぼかした下地を描くための文字列。読み込む前や、閲覧注意でぼかしている間に使う。
    public let blurhash: String?

    public init(
        id: String,
        type: Kind,
        url: URL?,
        previewUrl: URL?,
        remoteUrl: URL? = nil,
        previewRemoteUrl: URL? = nil,
        description: String? = nil,
        meta: Meta? = nil,
        blurhash: String? = nil
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.previewUrl = previewUrl
        self.remoteUrl = remoteUrl
        self.previewRemoteUrl = previewRemoteUrl
        self.description = description
        self.meta = meta
        self.blurhash = blurhash
    }

    /// 幅を高さで割った値。大きさの分からない添付ファイル（音声など）ではnil。
    /// URLはサーバーによって空で返るため、読めなければnilにする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(Kind.self, forKey: .type)
        url = container.decodeDisplayURL(forKey: .url)
        previewUrl = container.decodeDisplayURL(forKey: .previewUrl)
        remoteUrl = container.decodeDisplayURL(forKey: .remoteUrl)
        previewRemoteUrl = container.decodeDisplayURL(forKey: .previewRemoteUrl)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        blurhash = try container.decodeIfPresent(String.self, forKey: .blurhash)
    }

    /// 代替テキストだけを差し替えたもの。
    public func replacingDescription(_ description: String?) -> MediaAttachment {
        MediaAttachment(id: id, type: type, url: url, previewUrl: previewUrl, remoteUrl: remoteUrl, previewRemoteUrl: previewRemoteUrl, description: description, meta: meta, blurhash: blurhash)
    }

    public var aspectRatio: Double? {
        for size in [meta?.original, meta?.small] {
            if let width = size?.width, let height = size?.height, width > 0, height > 0 {
                return Double(width) / Double(height)
            }
        }
        return nil
    }

    public enum Kind: Hashable, Sendable, Codable {
        case image
        /// 音のないループ動画。GIFを変換したもの。
        case gifv
        case video
        case audio
        /// サーバーが扱えない種類、またはこのアプリが知らない種類。
        case unknown(String)

        public init(rawValue: String) {
            self = switch rawValue {
            case "image": .image
            case "gifv": .gifv
            case "video": .video
            case "audio": .audio
            default: .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .image: "image"
            case .gifv: "gifv"
            case .video: "video"
            case .audio: "audio"
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

    /// ファイルの大きさなど。サーバーやファイルの種類によって含まれる項目が違うため、使うものだけを読む。
    public struct Meta: Codable, Hashable, Sendable {
        public let original: Size?
        public let small: Size?
        /// 投稿者が付けた焦点。付けていなければnil。
        public let focus: MediaFocus?

        public init(original: Size? = nil, small: Size? = nil, focus: MediaFocus? = nil) {
            self.original = original
            self.small = small
            self.focus = focus
        }
    }

    /// 音声には幅と高さがない。フレームレート、長さ、ビットレートは、動画、GIF、音声の`original`にだけ付く。
    public struct Size: Codable, Hashable, Sendable {
        public let width: Int?
        public let height: Int?
        /// `"6159375/249269"`のような分数か、整数の文字列。
        public let frameRate: String?
        /// 秒数。
        public let duration: Double?
        /// ビット毎秒。
        public let bitrate: Int?

        public init(width: Int?, height: Int?, frameRate: String? = nil, duration: Double? = nil, bitrate: Int? = nil) {
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.duration = duration
            self.bitrate = bitrate
        }

        /// フレームレート、長さ、ビットレートは、メディアのメニューで情報として見せるだけなので、型が違っていても添付ファイルごと読めなくせず、nilにする。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decodeIfPresent(Int.self, forKey: .width)
            height = try container.decodeIfPresent(Int.self, forKey: .height)
            frameRate = try? container.decodeIfPresent(String.self, forKey: .frameRate)
            duration = try? container.decodeIfPresent(Double.self, forKey: .duration)
            bitrate = try? container.decodeIfPresent(Int.self, forKey: .bitrate)
        }
    }
}

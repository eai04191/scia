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
    /// 代替テキスト。
    public let description: String?
    public let meta: Meta?

    public init(
        id: String,
        type: Kind,
        url: URL?,
        previewUrl: URL?,
        remoteUrl: URL? = nil,
        description: String? = nil,
        meta: Meta? = nil
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.previewUrl = previewUrl
        self.remoteUrl = remoteUrl
        self.description = description
        self.meta = meta
    }

    /// 幅を高さで割った値。大きさの分からない添付ファイル（音声など）ではnil。
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

        public init(original: Size? = nil, small: Size? = nil) {
            self.original = original
            self.small = small
        }
    }

    /// 音声には幅と高さがない。
    public struct Size: Codable, Hashable, Sendable {
        public let width: Int?
        public let height: Int?

        public init(width: Int?, height: Int?) {
            self.width = width
            self.height = height
        }
    }
}

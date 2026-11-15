public import Foundation

/// 設定のストレージの「絵文字」の中に並べる行。
public struct EmojiStorageRow: Sendable, Equatable {
    public enum Kind: Sendable, Hashable {
        /// ログインしているサーバー（端末に`api/v1/custom_emojis`の応答を残しているサーバー）。ホスト名。
        case server(String)
        /// Unicodeの絵文字の画像。
        case unicode
        /// どのサーバーの応答にもURLが載っていない画像（ほかのサーバーの人の絵文字の画像と、差し替える前の画像）。
        case otherServers
    }

    public let kind: Kind
    public let bytes: Int64

    public init(kind: Kind, bytes: Int64) {
        self.kind = kind
        self.bytes = bytes
    }
}

/// 「絵文字」の中の行の大きさを数えるための素材。
public struct EmojiStorageSources: Sendable {
    public var lists: [StoredEmojiList]
    /// AとBに置いた画像の大きさを、フォルダーの名前（`MediaFileCache.folderName(for:)`）で引く。
    public var listedSizes: [String: Int]
    public var othersSizes: [String: Int]
    /// 絵文字ピッカーの小さい静止画の、URLごとの大きさ。
    public var thumbnailSizes: [URL: Int]
    /// 大きすぎて動かせない元の画像の記録の、URLとファイルの大きさ。
    public var oversizedURLs: Set<URL>
    public var oversizedBytes: Int64
    public var unicodeBytes: Int64

    public init(
        lists: [StoredEmojiList],
        listedSizes: [String: Int],
        othersSizes: [String: Int],
        thumbnailSizes: [URL: Int],
        oversizedURLs: Set<URL>,
        oversizedBytes: Int64,
        unicodeBytes: Int64
    ) {
        self.lists = lists
        self.listedSizes = listedSizes
        self.othersSizes = othersSizes
        self.thumbnailSizes = thumbnailSizes
        self.oversizedURLs = oversizedURLs
        self.oversizedBytes = oversizedBytes
        self.unicodeBytes = unicodeBytes
    }
}

extension EmojiStorageRow.Kind {
    /// 行の名前。「Unicodeの絵文字」は、ライセンスの画面の説明の書き方に合わせる。親の項目が「絵文字」なので、「絵文字」とだけ書くと見分けられないため。
    public var title: String {
        switch self {
        case .server(let server): server
        case .unicode: "Unicodeの絵文字"
        case .otherServers: "ほかのサーバーの絵文字"
        }
    }
}

extension EmojiStorageRow {
    /// 行を数える。行は、置き場所（AかBか）ではなく、URLで決める（docs/animated-custom-emoji.mdの「設定のストレージでの出し方」）。
    /// 空き容量が足りない端末では自分のサーバーの絵文字の画像をBに置くが、それもサーバーの行に数える。置き場所で決めると、
    /// 自分のサーバーの絵文字が「ほかのサーバーの絵文字」の行に出て、名前と合わないため。
    /// 2つのサーバーの応答に同じURLが載っていれば、どちらの行にも数える。各行が「そのサーバーの絵文字が使っている量」のまま正しい値になるため。
    public static func rows(_ sources: EmojiStorageSources) -> [EmojiStorageRow] {
        var listedAnywhere = Set<URL>()
        var rows: [EmojiStorageRow] = sources.lists.map { list in
            let urls = Set(list.emojis.flatMap { [$0.url, $0.staticUrl] })
            listedAnywhere.formUnion(urls)
            var bytes = list.fileBytes
            for url in urls {
                let name = MediaFileCache.folderName(for: url)
                bytes += Int64((sources.listedSizes[name] ?? 0) + (sources.othersSizes[name] ?? 0) + (sources.thumbnailSizes[url] ?? 0))
            }
            // 記録は数KBの1つのファイルなので、載っている絵文字の記録があるサーバーの行に、ファイルごと数える。
            if !urls.isDisjoint(with: sources.oversizedURLs) {
                bytes += sources.oversizedBytes
            }
            return EmojiStorageRow(kind: .server(list.server), bytes: bytes)
        }
        rows.append(EmojiStorageRow(kind: .unicode, bytes: sources.unicodeBytes))
        let listedNames = Set(listedAnywhere.map(MediaFileCache.folderName(for:)))
        let others = sources.othersSizes.reduce(Int64(0)) { $0 + (listedNames.contains($1.key) ? 0 : Int64($1.value)) }
        rows.append(EmojiStorageRow(kind: .otherServers, bytes: others))
        return rows
    }
}

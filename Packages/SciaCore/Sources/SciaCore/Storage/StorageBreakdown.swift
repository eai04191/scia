public import Foundation

/// アプリが端末で使っている大きさの内訳。設定の「iPhoneストレージ」の「書類とデータ」を、置き場所ごとに分けたもの。
public struct StorageBreakdown: Sendable, Equatable {
    public enum Category: Sendable, Hashable, CaseIterable {
        /// 添付ファイルの元のファイルのキャッシュ。
        case mediaFiles
        /// ビューアで開く画像をプリフェッチした置き場。開いていない画像なので、メディアのキャッシュとは分ける。
        case mediaPrefetch
        /// カスタム絵文字とUnicodeの絵文字の画像と、サーバーごとのカスタム絵文字のリスト。
        case emojis
        /// 通信の応答のキャッシュ（URLCache）。
        case networkCache
        /// 一時ファイル。投稿欄の添付、共有や保存に渡すコピー、ダウンロードの途中のファイル。
        case temporaryFiles
        /// アプリ内のSafari（SFSafariViewController）が持つ、サイトのキャッシュやCookie。
        case inAppSafari
        case discomfortReports
        case settings
        /// 共有拡張からアプリへ渡す途中のメディア（App Groupのコンテナ）。
        case sharedMedia
        /// ほかに数えたもののどれにも当たらない残り。
        case other
    }

    public struct Item: Sendable, Equatable {
        public let category: Category
        /// 大きさ。アプリから中を読めず測れないときはnil。
        public let bytes: Int64?
        /// そのうち、いま消してよい大きさ。測れないときはnil。
        public let removableBytes: Int64?

        public init(category: Category, bytes: Int64?, removableBytes: Int64? = 0) {
            self.category = category
            self.bytes = bytes
            self.removableBytes = removableBytes
        }
    }

    public let items: [Item]
    /// 「絵文字」の中に並べる行。
    public let emojiRows: [EmojiStorageRow]
    /// アプリ本体（バンドル）の大きさ。
    public let appBytes: Int64

    public init(items: [Item], emojiRows: [EmojiStorageRow] = [], appBytes: Int64) {
        self.items = items
        self.emojiRows = emojiRows
        self.appBytes = appBytes
    }

    /// 書類とデータの合計。測れない項目は入れない。
    public var dataBytes: Int64 {
        items.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    /// 測れない項目がある。合計は、iPhoneの設定の「書類とデータ」より小さくなる。
    public var hasUnmeasuredItems: Bool {
        items.contains { $0.bytes == nil }
    }

    public func item(_ category: Category) -> Item? {
        items.first { $0.category == category }
    }
}

/// 内訳を測る置き場所。
public struct StorageLocations: Sendable {
    /// アプリのデータのコンテナ（ホームディレクトリ）。
    public var container: URL
    public var mediaFiles: URL
    public var mediaPrefetch: URL
    public var temporary: URL
    public var discomfortReports: URL
    public var preferences: URL
    /// 絵文字の画像と、カスタム絵文字のリストを置く場所。
    public var emojis: [URL]
    /// 絵文字のうち、「キャッシュを消去」で消すもの（ほかのサーバーの絵文字の画像を置くB）の場所。
    public var removableEmojis: URL
    /// 通信の応答のキャッシュ（URLCache）のファイル。
    public var networkCache: [URL]
    /// アプリ内のSafariのデータを置く場所。
    public var inAppSafari: URL
    /// 共有拡張からアプリへ渡す途中のメディアを置く、App Groupのコンテナの中のフォルダー。App Groupを使えないときはnil。
    public var sharedContainer: URL?
    public var appBundle: URL

    public init(container: URL, mediaFiles: URL, mediaPrefetch: URL, temporary: URL, discomfortReports: URL, preferences: URL, emojis: [URL], removableEmojis: URL, networkCache: [URL], inAppSafari: URL, sharedContainer: URL?, appBundle: URL) {
        self.container = container
        self.mediaFiles = mediaFiles
        self.mediaPrefetch = mediaPrefetch
        self.temporary = temporary
        self.discomfortReports = discomfortReports
        self.preferences = preferences
        self.emojis = emojis
        self.removableEmojis = removableEmojis
        self.networkCache = networkCache
        self.inAppSafari = inAppSafari
        self.sharedContainer = sharedContainer
        self.appBundle = appBundle
    }
}

extension StorageBreakdown {
    /// 置き場所ごとの大きさを測る。ファイルを1つずつたどるので、メインスレッドでは呼ばない。
    /// - Parameters:
    ///   - launchDate: このプロセスを起動した日時。一時ファイルは、これより前に置いたものだけを消してよいものとして数える。
    ///     下書きの添付やダウンロードの途中のファイルはどれもこのプロセスが作るもので、起動より前のものはどこからも使っていないため。nilなら一時ファイルを消さない。
    /// - Parameter emojiRows: 「絵文字」の中に並べる行。
    public static func measure(_ locations: StorageLocations, launchDate: Date?, emojiRows: [EmojiStorageRow] = []) -> StorageBreakdown {
        let media = StorageUsage.allocatedSize(of: locations.mediaFiles)
        let prefetch = StorageUsage.allocatedSize(of: locations.mediaPrefetch)
        let temporary = StorageUsage.allocatedSize(of: locations.temporary)
        let leftovers = launchDate.map { StorageUsage.allocatedSize(in: locations.temporary, addedBefore: $0) } ?? 0
        let reports = StorageUsage.allocatedSize(of: locations.discomfortReports)
        let settings = StorageUsage.allocatedSize(of: locations.preferences)
        // 実機では、アプリ内のSafariのデータはSafariのサービスの持ち物で、アプリからは中を読めない（iOS 27のiPhone SE 3で確かめた）。
        // 0と出すと、何もないように見えて消すボタンも無効になるため、測れないものとして出す。
        let safari = StorageUsage.allocatedSizeIfReadable(of: locations.inAppSafari)
        let emojis = locations.emojis.map { ($0, StorageUsage.allocatedSize(of: $0)) }
        let emojiBytes = emojis.reduce(0) { $0 + $1.1 }
        let removableEmojiBytes = StorageUsage.allocatedSize(of: locations.removableEmojis)
        let networkCache = locations.networkCache.map { ($0, StorageUsage.allocatedSize(of: $0)) }
        let networkCacheBytes = networkCache.reduce(0) { $0 + $1.1 }
        // 残りは、コンテナの合計から、コンテナの中にある項目を引いて出す。Macでは一時ファイルがコンテナの外にあるため、中にあるかを確かめてから引く。
        let inside: [(URL, Int64)] = [
            (locations.mediaFiles, media),
            (locations.mediaPrefetch, prefetch),
            (locations.temporary, temporary),
            (locations.discomfortReports, reports),
            (locations.preferences, settings),
            (locations.inAppSafari, safari ?? 0),
        ] + emojis + networkCache
        let counted = inside.filter { isInside($0.0, locations.container) }.reduce(0) { $0 + $1.1 }
        let other = max(0, StorageUsage.allocatedSize(of: locations.container) - counted)
        return StorageBreakdown(
            items: [
                Item(category: .mediaFiles, bytes: media, removableBytes: media),
                Item(category: .mediaPrefetch, bytes: prefetch, removableBytes: prefetch),
                Item(category: .emojis, bytes: emojiBytes, removableBytes: removableEmojiBytes),
                Item(category: .networkCache, bytes: networkCacheBytes, removableBytes: networkCacheBytes),
                Item(category: .temporaryFiles, bytes: temporary, removableBytes: leftovers),
                Item(category: .inAppSafari, bytes: safari, removableBytes: safari),
                Item(category: .discomfortReports, bytes: reports, removableBytes: reports),
                Item(category: .settings, bytes: settings),
                Item(category: .sharedMedia, bytes: locations.sharedContainer.map(StorageUsage.allocatedSize(of:)) ?? 0),
                Item(category: .other, bytes: other),
            ],
            emojiRows: emojiRows,
            appBytes: StorageUsage.allocatedSize(of: locations.appBundle)
        )
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return path.starts(with: folder)
    }
}

/// ストレージの画面の消すボタン。空き容量を増やすためのボタンなので、消してもまた見れば再読み込みするものは、1つのボタンでまとめて消す。
/// 消せない項目は、使う人のデータか、なくなるとアプリが動かないもの。
public enum StorageRemoveTarget: CaseIterable, Hashable, Sendable {
    /// 消しても、また見れば再読み込みするもの。
    case caches
    /// 消すとサイトからログアウトするので、キャッシュと分ける。
    case inAppSafari
    /// 開発のための仕組みで、消すと戻らないので、キャッシュと分ける。
    case discomfortReports

    public var categories: [StorageBreakdown.Category] {
        switch self {
        case .caches: [.mediaFiles, .mediaPrefetch, .emojis, .networkCache, .temporaryFiles]
        case .inAppSafari: [.inAppSafari]
        case .discomfortReports: [.discomfortReports]
        }
    }

    public var name: String {
        switch self {
        case .caches: "キャッシュ"
        case .inAppSafari: StorageBreakdown.Category.inAppSafari.title
        case .discomfortReports: StorageBreakdown.Category.discomfortReports.title
        }
    }

    /// 消すボタンの名前。
    public var removeTitle: String { "\(name)を消去" }

    /// 消す前に確かめるときの題。
    public var confirmationTitle: String { "\(name)を消去しますか？" }

    /// 消す前に確かめるときの説明。確かめずに消すボタンではnil。
    public var confirmationMessage: String? {
        switch self {
        case .caches: nil
        case .inAppSafari: "ウェブサイトからはログアウトされます。"
        case .discomfortReports: "この操作は取り消せません。"
        }
    }

    /// 消せる大きさ。測れない項目が1つでもあればnilにして、消せるものがあるかもしれないので有効のままにする。
    public func removableBytes(in breakdown: StorageBreakdown) -> Int64? {
        categories.reduce(Int64(0)) { sum, category in
            guard let sum, let bytes = breakdown.item(category).map(\.removableBytes) ?? 0 else { return nil }
            return sum + bytes
        }
    }

    /// `breakdown`の画面に出すボタン。出さない項目（`StorageBreakdown.Category.isShown`）だけを消すボタンは出さない。
    public static func shown(in breakdown: StorageBreakdown) -> [StorageRemoveTarget] {
        allCases.filter { target in target.categories.allSatisfy { $0.isShown(bytes: breakdown.item($0)?.bytes) } }
    }
}

extension StorageBreakdown {
    /// 内訳のセクションの見出し。
    public static let dataHeader = "書類とデータ"
    /// 内訳の合計の行の名前。
    public static let totalTitle = "合計"
    /// 測れなかった項目があるときに、内訳のセクションの下に出す説明。
    public static let unmeasuredFooter = "“不明”の項目は合計に入っていません。"
    /// 測れなかった大きさの値。
    public static let unmeasuredValue = "不明"
    /// 表示済みとプリフェッチを合わせた、メディアのキャッシュの名前。合計の行の下に、表示済みとプリフェッチの2段に分けて並べる（docs/image-loading.md）。
    public static let mediaCacheTitle = "メディアのキャッシュ"
    /// アプリ本体の大きさの行の名前。
    public static let appTitle = "アプリ本体"
}

extension StorageBreakdown.Category {
    /// 内訳と消すボタンに出すか。違和感レポートは開発のための仕組みなので、残っているときだけ出す。測れなかったときは、残っているかもしれないので出す。
    public func isShown(bytes: Int64?) -> Bool {
        self != .discomfortReports || bytes != 0
    }

    /// この項目の中身を並べる画面で、中身がないときに出す文。
    public var emptyTitle: String { "\(title)はありません" }

    /// 項目の名前。
    public var title: String {
        switch self {
        case .mediaFiles: "表示済みのメディア"
        case .mediaPrefetch: "先読みしたメディア"
        case .emojis: "絵文字"
        case .networkCache: "通信のキャッシュ"
        case .temporaryFiles: "一時ファイル"
        case .inAppSafari: "アプリ内のSafariのデータ"
        case .discomfortReports: "違和感レポート"
        case .settings: "設定"
        case .sharedMedia: "共有から受け取り中のメディア"
        case .other: "その他"
        }
    }
}

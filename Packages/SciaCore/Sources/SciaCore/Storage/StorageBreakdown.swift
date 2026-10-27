public import Foundation

/// アプリが端末で使っている大きさの内訳。設定の「iPhoneストレージ」の「書類とデータ」を、置き場所ごとに分けたもの。
public struct StorageBreakdown: Sendable, Equatable {
    public enum Category: Sendable, Hashable, CaseIterable {
        /// 添付ファイルの元のファイルのキャッシュ。
        case mediaFiles
        /// ビューアで開く画像を先読みした置き場。開いていない画像なので、メディアのキャッシュとは分ける。
        case mediaPrefetch
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
    /// アプリ本体（バンドル）の大きさ。
    public let appBytes: Int64

    public init(items: [Item], appBytes: Int64) {
        self.items = items
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
    /// 通信の応答のキャッシュ（URLCache）のファイル。
    public var networkCache: [URL]
    /// アプリ内のSafariのデータを置く場所。
    public var inAppSafari: URL
    /// 共有拡張からアプリへ渡す途中のメディアを置く、App Groupのコンテナの中のフォルダー。App Groupを使えないときはnil。
    public var sharedContainer: URL?
    public var appBundle: URL

    public init(container: URL, mediaFiles: URL, mediaPrefetch: URL, temporary: URL, discomfortReports: URL, preferences: URL, networkCache: [URL], inAppSafari: URL, sharedContainer: URL?, appBundle: URL) {
        self.container = container
        self.mediaFiles = mediaFiles
        self.mediaPrefetch = mediaPrefetch
        self.temporary = temporary
        self.discomfortReports = discomfortReports
        self.preferences = preferences
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
    public static func measure(_ locations: StorageLocations, launchDate: Date?) -> StorageBreakdown {
        let media = StorageUsage.allocatedSize(of: locations.mediaFiles)
        let prefetch = StorageUsage.allocatedSize(of: locations.mediaPrefetch)
        let temporary = StorageUsage.allocatedSize(of: locations.temporary)
        let leftovers = launchDate.map { StorageUsage.allocatedSize(in: locations.temporary, addedBefore: $0) } ?? 0
        let reports = StorageUsage.allocatedSize(of: locations.discomfortReports)
        let settings = StorageUsage.allocatedSize(of: locations.preferences)
        // 実機では、アプリ内のSafariのデータはSafariのサービスの持ち物で、アプリからは中を読めない（iOS 27のiPhone SE 3で確かめた）。
        // 0と出すと、何もないように見えて消すボタンも押せなくなるため、測れないものとして出す。
        let safari = StorageUsage.allocatedSizeIfReadable(of: locations.inAppSafari)
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
        ] + networkCache
        let counted = inside.filter { isInside($0.0, locations.container) }.reduce(0) { $0 + $1.1 }
        let other = max(0, StorageUsage.allocatedSize(of: locations.container) - counted)
        return StorageBreakdown(
            items: [
                Item(category: .mediaFiles, bytes: media, removableBytes: media),
                Item(category: .mediaPrefetch, bytes: prefetch, removableBytes: prefetch),
                Item(category: .networkCache, bytes: networkCacheBytes, removableBytes: networkCacheBytes),
                Item(category: .temporaryFiles, bytes: temporary, removableBytes: leftovers),
                Item(category: .inAppSafari, bytes: safari, removableBytes: safari),
                Item(category: .discomfortReports, bytes: reports, removableBytes: reports),
                Item(category: .settings, bytes: settings),
                Item(category: .sharedMedia, bytes: locations.sharedContainer.map(StorageUsage.allocatedSize(of:)) ?? 0),
                Item(category: .other, bytes: other),
            ],
            appBytes: StorageUsage.allocatedSize(of: locations.appBundle)
        )
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return path.starts(with: folder)
    }
}

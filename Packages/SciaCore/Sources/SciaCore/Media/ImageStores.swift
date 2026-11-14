public import Foundation

/// アカウントのアイコン、添付ファイル、カスタム絵文字の画像のストアを、置き場所、読み方、読み直しの間隔とともに組み立てる。アプリで1つ作り、どのアカウントでも共有する。
///
/// - アイコンは、APIの外の画像として読む（`RemoteFetch`）
/// - 添付ファイルは、範囲を指定して読めるところは範囲で読み（`MediaRangeDownload`）、ビューアで開いた画像の元のファイルは`mediaFiles`に、
///   開く前に先読みした画像は`mediaPrefetchFiles`に分けて置く。先読みした画像で、開いた画像を押し出したり、ストレージの画面に並べたりしないため
/// - カスタム絵文字は、APIの外の画像として読む。画像を読めたら元の大きさを`customEmojis`へ渡し、サーバーが縦横比を返さない絵文字の縦横比をリストに残す
/// - 読めなかった画像を読み直す間隔は、`TuningCatalog.imageRetry(in:)`で読むたびに決める
///
/// サムネイルにどの画像を読むかの条件は、`NetworkConditionsMonitor.thumbnailPolicy(settings:tuning:)`で作る。
@MainActor
public final class ImageStores<Image: AnyObject & Sendable> {
    public let avatars: AvatarImageStore<Image>
    /// 添付ファイルの元のファイルを置くディスクキャッシュ。ビューアで開いた画像の元のファイルと、共有や保存のために落とした動画などを置く。
    public let mediaFiles: MediaFileCache
    /// ビューアで開く画像を先読みして置く場所。
    public let mediaPrefetchFiles: MediaFileCache
    public let media: MediaImageStore<Image>
    /// 本文、名前、リアクション、絵文字のパレットに出すカスタム絵文字の画像。
    public let emojis: EmojiImageStore<Image>
    /// サーバーごとのカスタム絵文字のリスト。端末に残し、絵文字のパレットを開いたときに読み込み中を挟まずに並べる。
    public let customEmojis: CustomEmojiCaches

    /// 先読みした画像の置き場所の上限。
    static var prefetchSizeLimit: Int { 100 * 1_024 * 1_024 }

    /// - Parameters:
    ///   - network: 回線の見張り。小さく読んだ絵文字を、大きい画像に読み直してよい回線かを決める。
    ///   - maker: 読んだ画像から、描くための画像の型を作る。
    ///   - localData: 通信せずに返せる画像（端末で作った見本の画像など）。返せなければnil。範囲を指定して読むときは使わない。
    ///   - mediaFiles: 添付ファイルの元のファイルの置き場所。省略すると`MediaFileCache`の既定の置き場所。テストでは一時フォルダーを渡す。
    ///   - mediaPrefetchFiles: 先読みした画像の置き場所。省略するとキャッシュのフォルダーの`MediaPrefetch`。
    ///   - customEmojis: カスタム絵文字のリストの置き場所。省略すると`CustomEmojiCaches`の既定の置き場所。
    public init(
        http: HTTPClient,
        tuning: TuningStore,
        network: NetworkConditionsMonitor,
        settings: AppSettings,
        maker: PlatformImageMaker<Image>,
        clock: any Clock<Duration> = SystemTime.clock,
        localData: @escaping @Sendable (URL) async -> Data? = { _ in nil },
        mediaFiles: MediaFileCache? = nil,
        mediaPrefetchFiles: MediaFileCache? = nil,
        customEmojis: CustomEmojiCaches? = nil
    ) {
        let mediaFiles = mediaFiles ?? MediaFileCache()
        let mediaPrefetchFiles = mediaPrefetchFiles ?? MediaFileCache(
            directory: .cachesDirectory.appending(path: "MediaPrefetch"),
            sharingDirectory: .temporaryDirectory.appending(path: "MediaPrefetchSharing"),
            sizeLimit: Self.prefetchSizeLimit
        )
        let remoteFetch = RemoteFetch(client: http)
        let retryPolicy: @MainActor () -> RetrySchedule.Policy = { TuningCatalog.imageRetry(in: tuning) }
        avatars = AvatarImageStore(clock: clock, retryPolicy: retryPolicy, maker: maker) { url in
            if let data = await localData(url) {
                return data
            }
            return try await remoteFetch.data(from: url)
        }
        self.mediaFiles = mediaFiles
        self.mediaPrefetchFiles = mediaPrefetchFiles
        media = MediaImageStore(files: mediaFiles, prefetchedFiles: mediaPrefetchFiles, clock: clock, retryPolicy: retryPolicy, maker: maker) { url, range in
            if range == nil, let data = await localData(url) {
                return data
            }
            return try await MediaRangeDownload.data(from: url, range: range, remoteFetch: remoteFetch, http: http)
        }
        let customEmojis = customEmojis ?? CustomEmojiCaches(clock: clock)
        self.customEmojis = customEmojis
        emojis = EmojiImageStore(clock: clock, retryPolicy: retryPolicy, maker: maker, upgradePurpose: { network.usePolicy(settings: settings).enhancement }) { url in
            if let data = await localData(url) {
                return data
            }
            return try await remoteFetch.data(from: url)
        }
        emojis.onSourceSize = { [customEmojis] url, width, height in customEmojis.learn(url, width: width, height: height) }
    }
}

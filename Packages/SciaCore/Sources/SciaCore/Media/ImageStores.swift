public import Foundation

/// アカウントのアイコンと添付ファイルの画像のストアを、置き場所、読み方、読み直しの間隔とともに組み立てる。アプリで1つ作り、どのアカウントでも共有する。
///
/// - アイコンは、APIの外の画像として読む（`RemoteFetch`）
/// - 添付ファイルは、範囲を指定して読めるところは範囲で読み（`MediaRangeDownload`）、ビューアで開いた画像の元のファイルは`mediaFiles`に、
///   開く前に先読みした画像は`mediaPrefetchFiles`に分けて置く。先読みした画像で、開いた画像を押し出したり、ストレージの画面に並べたりしないため
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

    /// 先読みした画像の置き場所の上限。
    static var prefetchSizeLimit: Int { 100 * 1_024 * 1_024 }

    /// - Parameters:
    ///   - maker: 読んだ画像から、描くための画像の型を作る。
    ///   - localData: 通信せずに返せる画像（端末で作った見本の画像など）。返せなければnil。範囲を指定して読むときは使わない。
    ///   - mediaFiles: 添付ファイルの元のファイルの置き場所。省略すると`MediaFileCache`の既定の置き場所。テストでは一時フォルダーを渡す。
    ///   - mediaPrefetchFiles: 先読みした画像の置き場所。省略するとキャッシュのフォルダーの`MediaPrefetch`。
    public init(
        http: HTTPClient,
        tuning: TuningStore,
        maker: PlatformImageMaker<Image>,
        clock: any Clock<Duration> = SystemTime.clock,
        localData: @escaping @Sendable (URL) async -> Data? = { _ in nil },
        mediaFiles: MediaFileCache? = nil,
        mediaPrefetchFiles: MediaFileCache? = nil
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
    }
}

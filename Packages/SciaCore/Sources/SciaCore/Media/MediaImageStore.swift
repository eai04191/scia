import AVFoundation
public import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// 添付ファイルの画像を読み込み、メモリに持つ。`Image`は描く側の画像の型で、iOSでは`UIImage`にする。
///
/// 絵文字と違って1枚が大きく、スクロールし続けると際限なく増えるため、上限のあるキャッシュに入れる。
/// 描画のたびにメインスレッドで展開しないよう、表示する大きさまで縮めて展開したものを持つ。
@MainActor
public final class MediaImageStore<Image: Sendable> {
    /// URLのファイルを読む。範囲を渡したら、その部分だけを読む（ファイルの終わりを越えた分は返さない）。
    public typealias Fetch = @Sendable (URL, Range<Int>?) async throws -> Data

    private let fetch: Fetch
    private let maker: PlatformImageMaker<Image>
    /// 同じURLでも縮める大きさごとに分けて持つ。サーバーによってはプレビューと元の画像が同じURLのため。
    private let cache = NSCache<NSString, Entry>()
    private var inFlight: [Key: Task<Loaded, any Error>] = [:]
    /// 元のファイルを置くディスクキャッシュ。共有や保存で縮めずに元の形式のまま渡すために残し、ビューアで開き直すときは通信せずにここから読む。
    private let files: MediaFileCache
    /// 先読みした元の画像の置き場。ビューアで開いたら`files`へ移す。nilなら先読みしない。
    private let prefetchedFiles: MediaFileCache?
    /// 先頭から最初のフレームを作れなかった動画。サーバーのプレビューを出し、読み直さない。通信の失敗や429、5xxは、待てば作れるため含めない。
    private var failedVideoFrames: Set<URL> = []
    /// 読めなかった画像と動画の最初のフレームを、一覧に描いたときにいつ読み直すか。
    private var retry: RetrySchedule
    private let logger = SciaLog.logger(category: "media")

    public init(
        files: MediaFileCache,
        prefetchedFiles: MediaFileCache?,
        clock: any Clock<Duration>,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy,
        maker: PlatformImageMaker<Image>,
        fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        self.maker = maker
        self.files = files
        self.prefetchedFiles = prefetchedFiles
        retry = RetrySchedule(policy: retryPolicy, clock: clock)
        // 4096px四方の画像が4枚ほど入る大きさ。
        cache.totalCostLimit = 256 * 1_024 * 1_024
    }

    /// キャッシュに入れる値。`NSCache`はクラスしか持てないため包む。
    private final class Entry {
        let image: Image

        init(_ image: Image) {
            self.image = image
        }
    }

    /// 展開した画像と、それが使うメモリのバイト数。
    private struct Decoded: Sendable {
        let image: Image
        let cost: Int
    }

    private struct Loaded: Sendable {
        let decoded: Decoded
        let keptOriginal: Bool

        var image: Image { decoded.image }
    }

    private struct Key: Hashable {
        let url: URL
        let maxPixelSize: Int
        /// 動画の先頭から作った最初のフレーム。
        var isVideoFrame = false
        /// 送ってよい回線。キャッシュの鍵には含めず、読み込みの待ち合わせだけを分ける。
        /// Wi-Fiで始めた元の画像の読み込みにモバイル通信でOSが断ると、同じURLをプレビューとして読む処理までその失敗を受けてしまうため。
        /// 違う回線の読み込みも`joinRestricted(of:)`で待つが、OSが断ったときは失敗を引き継がない。
        var networkAccess = RequestPurpose.display.networkAccess

        var cacheKey: NSString { "\(isVideoFrame ? "frame " : "")\(maxPixelSize) \(url.absoluteString)" as NSString }
    }

    public func cachedImage(for url: URL, maxPixelSize: Int) -> Image? {
        cache.object(forKey: Key(url: url, maxPixelSize: maxPixelSize).cacheKey)?.image
    }

    /// 一覧のサムネイルを、読み込み済みならすぐ返す。
    public func cachedThumbnail(for request: MediaThumbnailRequest) -> Image? {
        switch request.source {
        case .image:
            return cachedImage(for: request.url, maxPixelSize: request.maxPixelSize)
        case .videoFrame(let fallback):
            let key = Key(url: request.url, maxPixelSize: request.maxPixelSize, isVideoFrame: true)
            if let frame = cache.object(forKey: key.cacheKey)?.image {
                return frame
            }
            return failedVideoFrames.contains(request.url) ? cachedImage(for: fallback, maxPixelSize: request.maxPixelSize) : nil
        }
    }

    /// ビューアで開く元の画像を、展開せずに先読みの置き場へ落とす。置いてあるもの、ビューアで開いたもの、前に読めなかったものは読まない。
    /// 展開しないのは、1枚で数十MBのメモリを使うため。展開はビューアで開いたときに行う。
    /// 先読みの途中にビューアで同じ画像を開くと、ビューアは先読みを待たずに自分で読み、同じ画像を2回読む。Wi-Fiでだけ起き、
    /// 待ち合わせのために先読みの置き場とビューアの読み込みを結ぶ手間に見合わないため、そのままにしている（docs/image-loading.md）。
    /// Wi-Fiでは一覧のサムネイルにも元の画像を読むことがあるので、同じ画像をサムネイルとして読んでいる途中なら、それを待つ。
    /// サムネイルで読んだ元の画像も先読みの置き場に置くため、同じファイルを2回読まずに済む。
    public func prefetchOriginal(_ url: URL, purpose: RequestPurpose) async {
        guard let prefetchedFiles else { return }
        for task in inFlight.filter({ $0.key.url == url && !$0.key.isVideoFrame }).values {
            _ = try? await task.value
        }
        guard retry.allowsAutomaticLoad(of: url), !retry.hasFailed(url),
              await !files.contains(url), await !prefetchedFiles.contains(url)
        else { return }
        let generation = await prefetchedFiles.generation
        let fetch = fetch
        do {
            let data = try await RequestPurpose.$current.withValue(purpose) {
                try await fetch(url, nil)
            }
            guard let name = await Self.originalFileName(of: data, for: url) else {
                throw DecodeError()
            }
            _ = try await prefetchedFiles.store(data, named: name, for: url, generation: generation)
            logger.debug("media prefetched host=\(SciaLog.host(of: url), privacy: .public) bytes=\(data.count, privacy: .public)")
        } catch {
            guard HTTPFailure(error) != nil else { return }
            logger.info("media prefetch failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
            retry.recordFailure(error, for: url)
        }
    }

    /// 一覧のサムネイルを読み込む。動画の最初のフレームを作れなければ、サーバーのプレビューを読む。
    /// 前に読めなかったものは、読み直してよくなるまで読まない（`image(for:maxPixelSize:keepsOriginal:retriesNow:)`）。
    public func thumbnail(for request: MediaThumbnailRequest) async throws -> Image {
        switch request.source {
        case .image:
            return try await image(for: request.url, maxPixelSize: request.maxPixelSize, purpose: request.purpose, sharesWithPrefetch: request.isOriginal)
        case .videoFrame(let fallback):
            // 通信の失敗で作れなかった間は、読み直してよくなるまでサーバーのプレビューで描く。先読みでは、前に読めなかったものを読まない。
            if !failedVideoFrames.contains(request.url), retry.allowsAutomaticLoad(of: request.url),
               request.purpose != .prefetch || !retry.hasFailed(request.url) {
                do {
                    let frame = try await videoFrame(for: request.url, maxPixelSize: request.maxPixelSize, purpose: request.purpose)
                    retry.recordSuccess(for: request.url)
                    return frame
                } catch {
                    // 通信の失敗やサーバーの一時的な障害は、待てば作れるため、間隔をおいて作り直す。
                    // 範囲に応えないサーバーや、先頭から作れない動画は、作り直しても同じなので覚える。
                    // 回線で控えたものは、回線が変わって描き直したときに選び直すので覚えない。
                    switch HTTPFailure(error) {
                    case .temporary: retry.recordFailure(error, for: request.url)
                    case .permanent, .unauthorized: failedVideoFrames.insert(request.url)
                    case nil, .unavailableOnNetwork: break
                    }
                }
            }
            // ぼかしている間の先読みなら、代わりのプレビューも先読みとして読み、モバイル通信や低データモードでは読まない。
            return try await image(for: fallback, maxPixelSize: request.maxPixelSize, purpose: request.purpose == .prefetch ? .prefetch : .display)
        }
    }

    /// 動画の先頭だけを読み、最初のフレームを作る。読む長さは`VideoFirstFrame`が動画の目次から決める。
    private func videoFrame(for url: URL, maxPixelSize: Int, purpose: RequestPurpose) async throws -> Image {
        let key = Key(url: url, maxPixelSize: maxPixelSize, isVideoFrame: true, networkAccess: purpose.networkAccess)
        if let image = cache.object(forKey: key.cacheKey)?.image {
            return image
        }
        if let task = inFlight[key] {
            return try await task.value.image
        }
        if let image = try await joinRestricted(of: key) {
            return image
        }
        // 待っている間に、同じ目的のほかの呼び出しが読み始めたり読み終えたりしていれば、それを使う。
        if let image = cache.object(forKey: key.cacheKey)?.image {
            return image
        }
        if let task = inFlight[key] {
            return try await task.value.image
        }
        let fetch = fetch
        let maker = maker
        // 一覧に描くための読み込みなので、呼び出し側の目的（質を上げる通信）で送り、止められている間と、その回線では送らない（docs/network.md）。
        let task = RequestPurpose.$current.withValue(purpose) {
            Task<Loaded, any Error> {
                let prefix = try await VideoFirstFrame.readPrefix { range in try await fetch(url, range) }
                return Loaded(decoded: try await Self.makeVideoFrame(from: prefix, maxPixelSize: maxPixelSize, maker: maker), keptOriginal: false)
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let loaded = try await task.value
            cache.setObject(Entry(loaded.image), forKey: key.cacheKey, cost: loaded.decoded.cost)
            return loaded.image
        } catch {
            logger.info("video frame failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
            throw error
        }
    }

    /// 同じものを、回線の制限の違う目的で読んでいる途中なら、その結果を待つ。ぼかしている間に先読みしていた画像を、外したときに読み直さないため。
    /// 制限の厳しい読み込みにOSが断ったら、その失敗は引き継がずにnilを返し、呼び出し側が自分の目的で読む。
    private func joinRestricted(of key: Key) async throws -> Image? {
        guard let task = inFlight.first(where: {
            $0.key.url == key.url && $0.key.maxPixelSize == key.maxPixelSize && $0.key.isVideoFrame == key.isVideoFrame
        })?.value else { return nil }
        do {
            return try await task.value.image
        } catch {
            guard HTTPFailure(error) == .unavailableOnNetwork else { throw error }
            return nil
        }
    }

    /// キャッシュに置いた元のファイルの場所。置いていなければnil。メディアの情報で、ファイルの中身を読むのに使う。
    public func originalFile(for url: URL) async -> URL? {
        await files.file(for: url)
    }

    /// 元のファイルをキャッシュに置いてあるか。`keepsOriginal`を付けて読み込み終えるまでと、整理で消えたあとはfalse。
    public func hasOriginal(for url: URL) async -> Bool {
        await files.contains(url)
    }

    /// 画像を読み込む。同じURLを読み込んでいる途中なら、その結果を待つ。
    /// 呼び出し側のタスクを取り消しても、読み込みは止めずにキャッシュへ入れる。同じ画像がすぐまた求められることが多いため。
    /// - Parameter keepsOriginal: 元のファイルをキャッシュに置き、`hasOriginal(for:)`で確かめられるようにする。
    ///   同じURLを残さずに読み込んでいる途中だった場合は、その結果を待つため残らない。元のファイルを求めるのはビューアだけで、
    ///   ビューアは常に残すよう求めるため、この組み合わせは起きない。
    /// 前に読めなかった画像は、読み直してよくなるまで`ImageLoadDeferred`を投げる。
    /// - Parameter retriesNow: 使う人が自分で見に行った操作（ビューアを開く、長押しするなど）で、間隔を待たずに読み直す。
    /// - Parameter purpose: `retriesNow`でないときに送る目的。一覧のサムネイルの元の画像は、質を上げる通信として送る。
    /// - Parameter sharesWithPrefetch: ビューアで開くのと同じ元の画像を、一覧のサムネイルとして読む。読んだファイルを先読みの置き場にも置く。
    public func image(
        for url: URL,
        maxPixelSize: Int,
        keepsOriginal: Bool = false,
        retriesNow: Bool = false,
        purpose: RequestPurpose = .display,
        sharesWithPrefetch: Bool = false
    ) async throws -> Image {
        let purpose = retriesNow ? .action : purpose
        let key = Key(url: url, maxPixelSize: maxPixelSize, networkAccess: purpose.networkAccess)
        if let image = cache.object(forKey: key.cacheKey)?.image {
            if !keepsOriginal {
                return image
            }
            if await files.contains(url) {
                return image
            }
        }
        if let task = inFlight[key] {
            return try await task.value.image
        }
        // 元のファイルを残す読み込みは、残さない読み込みの結果では済まないので待ち合わせない。
        if !keepsOriginal {
            if let image = try await joinRestricted(of: key) {
                return image
            }
            // 待っている間に、同じ目的のほかの呼び出しが読み始めたり読み終えたりしていれば、それを使う。
            if let image = cache.object(forKey: key.cacheKey)?.image {
                return image
            }
            if let task = inFlight[key] {
                return try await task.value.image
            }
        }
        guard retriesNow || retry.allowsAutomaticLoad(of: url) else {
            throw ImageLoadDeferred()
        }
        // 先読みでは、前に読めなかった画像を読まない（docs/image-loading.md）。
        if purpose == .prefetch, retry.hasFailed(url) {
            throw ImageLoadDeferred()
        }
        let fetch = fetch
        let maker = maker
        let files = keepsOriginal ? files : nil
        let prefetchedForViewer = keepsOriginal ? prefetchedFiles : nil
        // サムネイルに読んだ元の画像は、ビューアで開く画像と同じなので、先読みの置き場にも置く。先読みで同じファイルを読み直さないため。
        let prefetchedFromThumbnail = sharesWithPrefetch && !keepsOriginal ? prefetchedFiles : nil
        // 一覧に描くための読み込みは自動の通信として送り、止められている間は送らない（docs/network.md）。
        let task = RequestPurpose.$current.withValue(purpose) { Task<Loaded, any Error> {
            let generation = await files?.generation
            let thumbnailGeneration = await prefetchedFromThumbnail?.generation
            // ビューアで開く画像は、元のファイルがキャッシュにあれば通信せずに使う。壊れていて展開できなければ、通信で取り直して置き直す。
            if let files, let cached = await files.data(for: url), let image = await Self.decode(cached, maxPixelSize: maxPixelSize, maker: maker) {
                return Loaded(decoded: image, keptOriginal: true)
            }
            // 先読みしてあれば通信せずに使い、メディアのキャッシュへ移す。開いていない画像と開いた画像の置き場を分けているため（docs/image-loading.md）。
            if let files, let generation, let prefetchedFiles = prefetchedForViewer, let prefetched = await prefetchedFiles.data(for: url),
               let image = await Self.decode(prefetched, maxPixelSize: maxPixelSize, maker: maker) {
                var keptOriginal = false
                if let name = await Self.originalFileName(of: prefetched, for: url) {
                    keptOriginal = (try? await files.store(prefetched, named: name, for: url, generation: generation)) != nil
                }
                await prefetchedFiles.remove(url)
                return Loaded(decoded: image, keptOriginal: keptOriginal)
            }
            let data = try await fetch(url, nil)
            guard let image = await Self.decode(data, maxPixelSize: maxPixelSize, maker: maker) else {
                throw DecodeError()
            }
            // 置けなくても画像は見せる。共有と保存だけが選べなくなる。
            var keptOriginal = false
            if let files, let generation, let name = await Self.originalFileName(of: data, for: url) {
                keptOriginal = (try? await files.store(data, named: name, for: url, generation: generation)) != nil
            }
            if let prefetchedFromThumbnail, let thumbnailGeneration, let name = await Self.originalFileName(of: data, for: url) {
                _ = try? await prefetchedFromThumbnail.store(data, named: name, for: url, generation: thumbnailGeneration)
            }
            return Loaded(decoded: image, keptOriginal: keptOriginal)
        } }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let loaded = try await task.value
            cache.setObject(Entry(loaded.image), forKey: key.cacheKey, cost: loaded.decoded.cost)
            retry.recordSuccess(for: url)
            if keepsOriginal, !loaded.keptOriginal {
                logger.error("media original write failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash))")
            }
            return loaded.image
        } catch {
            logger.error("media load failed host=\(SciaLog.host(of: url), privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
            retry.recordFailure(error, for: url)
            throw error
        }
    }

    /// blurhashを、`aspectRatio`（幅÷高さ）の小さな画像に展開する。表示するときに拡大してぼかしとして見せるため、
    /// 長い辺を32ピクセルにする。文字列が仕様どおりでなければnil。
    public func placeholder(for blurhash: String, aspectRatio: Double?) -> Image? {
        let longSide = 32
        let ratio = aspectRatio ?? 1
        let width = ratio >= 1 ? longSide : max(Int((Double(longSide) * ratio).rounded()), 1)
        let height = ratio >= 1 ? max(Int((Double(longSide) / ratio).rounded()), 1) : longSide
        let key = "blurhash \(width)x\(height) \(blurhash)" as NSString
        if let image = cache.object(forKey: key)?.image {
            return image
        }
        guard let image = BlurHash(blurhash).flatMap({ Self.makeImage(rgba: $0.rgba(width: width, height: height), width: width, height: height) }) else {
            logger.error("blurhash decode failed hash=\(blurhash, privacy: .private(mask: .hash))")
            return nil
        }
        let made = maker.still(image)
        cache.setObject(Entry(made), forKey: key, cost: PlatformImageMaker<Image>.cost(of: image))
        return made
    }

    private static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }
        return image
    }

    public struct DecodeError: Error {}

    /// `maxPixelSize`まで縮め、描画できる状態まで展開する。重い処理のため、メインスレッドの外で行う。
    /// HDRの写真は、ゲインマップを使ってHDRのまま展開する。指定しないとSDRに展開され、HDRで描く設定にしても明るくならない。
    /// どれくらいの明るさで描くかは、画面ごとのtraitで決める（`MediaDynamicRangeTraits`）。そのため、設定を選び直しても読み込み直さずに済む。
    @concurrent
    private static func decode(_ data: Data, maxPixelSize: Int, maker: PlatformImageMaker<Image>) async -> Decoded? {
        ImageDecoder.thumbnail(of: data, maxPixelSize: maxPixelSize, dynamicRange: .high).map { Decoded(image: maker.still($0), cost: PlatformImageMaker<Image>.cost(of: $0)) }
    }

    /// 動画の先頭の部分から、0秒目のフレームを`maxPixelSize`まで縮めて作る。AVFoundationはファイルから読むため、一時ファイルに書く。
    @concurrent
    private static func makeVideoFrame(from prefix: Data, maxPixelSize: Int, maker: PlatformImageMaker<Image>) async throws -> Decoded {
        let file = URL.temporaryDirectory.appending(path: "VideoFrame-\(UUID().uuidString).mp4")
        try prefix.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        // 既定ではSDRに変換される。HDRの動画のコマもHDRのまま作り、描く明るさは画面ごとのtraitで決める。
        generator.dynamicRangePolicy = .matchSource
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // 先頭にあるのは最初のキーフレームだけなので、0秒より後ろのフレームも受け取る。
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let frame = try await generator.image(at: .zero).image
        return Decoded(image: maker.still(frame), cost: PlatformImageMaker<Image>.cost(of: frame))
    }

    /// 元のファイルの名前。共有先でファイル名として見えるため、URLの名前を残し、拡張子は中身の形式に合わせる。
    /// URLの拡張子は付いていなかったり実際の形式と違ったりするため使わない。画像でなければnil。
    @concurrent
    private static func originalFileName(of data: Data, for url: URL) async -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { MediaOriginalFileName.name(of: $0, for: url) }
    }
}

/// ビューアで拡大して見る画像の大きさ。
public enum MediaImagePixelSize {
    /// 展開する最大の辺の長さ（ピクセル）。これより大きい画像は縮めて持つ。
    public static let full = 4_096
}

/// 添付ファイルの元のファイルに付ける名前。
public enum MediaOriginalFileName {
    /// 落としたファイルが画像なら、`MediaImageStore`が元のファイルを置くときと同じく、中身の形式に合わせた名前。整理で消えた元のファイルを落とし直したときに使う。
    @concurrent
    public static func name(ofFileAt file: URL, for url: URL) async -> String? {
        CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { name(of: $0, for: url) }
    }

    static func name(of source: CGImageSource, for url: URL) -> String? {
        guard let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              let pathExtension = type.preferredFilenameExtension
        else { return nil }
        return URL(filePath: url.deletingPathExtension().lastPathComponent).appendingPathExtension(pathExtension).lastPathComponent
    }
}

/// 添付ファイルを、範囲を指定して読む。`MediaImageStore`の読み込みに渡す。
public enum MediaRangeDownload {
    /// 範囲に応えないサーバー。
    public struct RangeNotSupported: Error {}

    /// URLのファイルを読む。範囲を渡したら、その部分だけを読む。
    @concurrent
    public static func data(from url: URL, range: Range<Int>?, remoteFetch: RemoteFetch, http: HTTPClient) async throws -> Data {
        guard let range else {
            return try await remoteFetch.data(from: url)
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        // 2xx以外は、429や5xxを待てば作れる失敗として、`HTTPStatusError`で返る。
        let (body, response) = try await http.open(request, limit: range.count, scope: .host)
        // 範囲に応えないサーバーはファイル全体を返すため、読み始める前に止める。本文を読まずに手放すと、通信も止まる。
        guard response.statusCode == 206 else {
            throw RangeNotSupported()
        }
        var data = Data()
        data.reserveCapacity(range.count)
        for try await chunk in body {
            data.append(chunk)
            if data.count >= range.count {
                break
            }
        }
        // 取り消されると、列は失敗せずに終わる。途中までの先頭から、最初のフレームを作らない。
        try Task.checkCancellation()
        return Data(data.prefix(range.count))
    }
}

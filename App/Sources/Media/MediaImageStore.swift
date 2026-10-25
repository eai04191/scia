import AVFoundation
import Foundation
import ImageIO
import os
import SciaCore
import UIKit
import UniformTypeIdentifiers

/// 添付ファイルの画像を読み込み、メモリに持つ。
///
/// 絵文字と違って1枚が大きく、スクロールし続けると際限なく増えるため、上限のあるキャッシュに入れる。
/// 描画のたびにメインスレッドで展開しないよう、表示する大きさまで縮めて展開したものを持つ。
@MainActor
final class MediaImageStore {
    /// URLのファイルを読む。範囲を渡したら、その部分だけを読む（ファイルの終わりを越えた分は返さない）。
    typealias Fetch = @Sendable (URL, Range<Int>?) async throws -> Data

    /// ビューアで拡大して見る画像を展開する最大の辺の長さ（ピクセル）。これより大きい画像は縮めて持つ。
    static let fullPixelSize = 4_096

    private let fetch: Fetch
    /// 同じURLでも縮める大きさごとに分けて持つ。サーバーによってはプレビューと元の画像が同じURLのため。
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [Key: Task<Loaded, any Error>] = [:]
    /// 元のファイルを置くディスクキャッシュ。共有や保存で縮めずに元の形式のまま渡すために残し、ビューアで開き直すときは通信せずにここから読む。
    private let files: MediaFileCache
    /// 先頭から最初のフレームを作れなかった動画。サーバーのプレビューを出し、読み直さない。通信の失敗は、つながれば作れるため含めない。
    private var failedVideoFrames: Set<URL> = []
    /// 読めなかった画像と動画の最初のフレームを、一覧に描いたときにいつ読み直すか。
    private var retry: ImageRetrySchedule
    private let logger = SciaLog.logger(category: "media")

    init(
        files: MediaFileCache,
        clock: any Clock<Duration> = AppDependencies.clock,
        retryPolicy: @escaping @MainActor () -> ImageRetrySchedule.Policy = { TuningCatalog.imageRetry(in: AppDependencies.tuning) },
        fetch: @escaping Fetch
    ) {
        self.fetch = fetch
        self.files = files
        retry = ImageRetrySchedule(policy: retryPolicy, clock: clock)
        // 4096px四方の画像が4枚ほど入る大きさ。
        cache.totalCostLimit = 256 * 1_024 * 1_024
    }

    private struct Loaded: Sendable {
        let image: UIImage
        let keptOriginal: Bool
    }

    private struct Key: Hashable {
        let url: URL
        let maxPixelSize: Int
        /// 動画の先頭から作った最初のフレーム。
        var isVideoFrame = false

        var cacheKey: NSString { "\(isVideoFrame ? "frame " : "")\(maxPixelSize) \(url.absoluteString)" as NSString }
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: Key(url: url, maxPixelSize: maxPixelSize).cacheKey)
    }

    /// 一覧のサムネイルを、読み込み済みならすぐ返す。
    func cachedThumbnail(for request: MediaThumbnailRequest) -> UIImage? {
        switch request.source {
        case .image:
            return cachedImage(for: request.url, maxPixelSize: request.maxPixelSize)
        case .videoFrame(let fallback):
            let key = Key(url: request.url, maxPixelSize: request.maxPixelSize, isVideoFrame: true)
            if let frame = cache.object(forKey: key.cacheKey) {
                return frame
            }
            return failedVideoFrames.contains(request.url) ? cachedImage(for: fallback, maxPixelSize: request.maxPixelSize) : nil
        }
    }

    /// 一覧のサムネイルを読み込む。動画の最初のフレームを作れなければ、サーバーのプレビューを読む。
    /// 前に読めなかったものは、読み直してよくなるまで読まない（`image(for:maxPixelSize:keepsOriginal:retriesNow:)`）。
    func thumbnail(for request: MediaThumbnailRequest) async throws -> UIImage {
        switch request.source {
        case .image:
            return try await image(for: request.url, maxPixelSize: request.maxPixelSize)
        case .videoFrame(let fallback):
            // 通信の失敗で作れなかった間は、読み直してよくなるまでサーバーのプレビューで描く。
            if !failedVideoFrames.contains(request.url), retry.allowsAutomaticLoad(of: request.url) {
                do {
                    let frame = try await videoFrame(for: request.url, maxPixelSize: request.maxPixelSize)
                    retry.recordSuccess(for: request.url)
                    return frame
                } catch let error as URLError {
                    // 通信の失敗は、つながれば作れるため、間隔をおいて作り直す。
                    retry.recordFailure(error, for: request.url)
                } catch {
                    failedVideoFrames.insert(request.url)
                }
            }
            return try await image(for: fallback, maxPixelSize: request.maxPixelSize)
        }
    }

    /// 動画の先頭だけを読み、最初のフレームを作る。読む長さは`VideoFirstFrame`が動画の目次から決める。
    private func videoFrame(for url: URL, maxPixelSize: Int) async throws -> UIImage {
        let key = Key(url: url, maxPixelSize: maxPixelSize, isVideoFrame: true)
        if let image = cache.object(forKey: key.cacheKey) {
            return image
        }
        if let task = inFlight[key] {
            return try await task.value.image
        }
        let fetch = fetch
        let task = Task<Loaded, any Error> {
            let prefix = try await VideoFirstFrame.readPrefix { range in try await fetch(url, range) }
            return Loaded(image: try await Self.makeVideoFrame(from: prefix, maxPixelSize: maxPixelSize), keptOriginal: false)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let loaded = try await task.value
            cache.setObject(loaded.image, forKey: key.cacheKey, cost: Self.cost(of: loaded.image))
            return loaded.image
        } catch {
            logger.info("video frame failed url=\(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// キャッシュに置いた元のファイルの場所。置いていなければnil。メディアの情報で、ファイルの中身を読むのに使う。
    func originalFile(for url: URL) async -> URL? {
        await files.file(for: url)
    }

    /// 元のファイルをキャッシュに置いてあるか。`keepsOriginal`を付けて読み込み終えるまでと、整理で消えたあとはfalse。
    func hasOriginal(for url: URL) async -> Bool {
        await files.contains(url)
    }

    /// 画像を読み込む。同じURLを読み込んでいる途中なら、その結果を待つ。
    /// 呼び出し側のタスクを取り消しても、読み込みは止めずにキャッシュへ入れる。同じ画像がすぐまた求められることが多いため。
    /// - Parameter keepsOriginal: 元のファイルをキャッシュに置き、`hasOriginal(for:)`で確かめられるようにする。
    ///   同じURLを残さずに読み込んでいる途中だった場合は、その結果を待つため残らない。元のファイルを求めるのはビューアだけで、
    ///   ビューアは常に残すよう求めるため、この組み合わせは起きない。
    /// 前に読めなかった画像は、読み直してよくなるまで`ImageLoadDeferred`を投げる。
    /// - Parameter retriesNow: 使う人が自分で見に行った操作（ビューアを開く、長押しするなど）で、間隔を待たずに読み直す。
    func image(for url: URL, maxPixelSize: Int, keepsOriginal: Bool = false, retriesNow: Bool = false) async throws -> UIImage {
        let key = Key(url: url, maxPixelSize: maxPixelSize)
        if let image = cache.object(forKey: key.cacheKey) {
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
        guard retriesNow || retry.allowsAutomaticLoad(of: url) else {
            throw ImageLoadDeferred()
        }
        let fetch = fetch
        let files = keepsOriginal ? files : nil
        let task = Task<Loaded, any Error> {
            // ビューアで開く画像は、元のファイルがキャッシュにあれば通信せずに使う。壊れていて展開できなければ、通信で取り直して置き直す。
            if let files, let cached = await files.data(for: url), let image = await Self.decode(cached, maxPixelSize: maxPixelSize) {
                return Loaded(image: image, keptOriginal: true)
            }
            let data = try await fetch(url, nil)
            guard let image = await Self.decode(data, maxPixelSize: maxPixelSize) else {
                throw DecodeError()
            }
            // 置けなくても画像は見せる。共有と保存だけが選べなくなる。
            var keptOriginal = false
            if let files, let name = await Self.originalFileName(of: data, for: url) {
                keptOriginal = (try? await files.store(data, named: name, for: url)) != nil
            }
            return Loaded(image: image, keptOriginal: keptOriginal)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let loaded = try await task.value
            cache.setObject(loaded.image, forKey: key.cacheKey, cost: Self.cost(of: loaded.image))
            retry.recordSuccess(for: url)
            if keepsOriginal, !loaded.keptOriginal {
                logger.error("media original write failed url=\(url.absoluteString, privacy: .public)")
            }
            return loaded.image
        } catch {
            logger.error("media load failed url=\(url.absoluteString, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
            retry.recordFailure(error, for: url)
            throw error
        }
    }

    /// blurhashを、`aspectRatio`（幅÷高さ）の小さな画像に展開する。表示するときに拡大してぼかしとして見せるため、
    /// 長い辺を32ピクセルにする。文字列が仕様どおりでなければnil。
    func placeholder(for blurhash: String, aspectRatio: Double?) -> UIImage? {
        let longSide = 32
        let ratio = aspectRatio ?? 1
        let width = ratio >= 1 ? longSide : max(Int((Double(longSide) * ratio).rounded()), 1)
        let height = ratio >= 1 ? max(Int((Double(longSide) / ratio).rounded()), 1) : longSide
        let key = "blurhash \(width)x\(height) \(blurhash)" as NSString
        if let image = cache.object(forKey: key) {
            return image
        }
        guard let image = BlurHash(blurhash).flatMap({ Self.makeImage(rgba: $0.rgba(width: width, height: height), width: width, height: height) }) else {
            logger.error("blurhash decode failed hash=\(blurhash, privacy: .public)")
            return nil
        }
        cache.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    private static func makeImage(rgba: [UInt8], width: Int, height: Int) -> UIImage? {
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
        return UIImage(cgImage: image)
    }

    struct DecodeError: Error {}

    /// `maxPixelSize`まで縮め、描画できる状態まで展開する。重い処理のため、メインスレッドの外で行う。
    /// HDRの写真は、ゲインマップを使ってHDRのまま展開する。指定しないとSDRに展開され、HDRで描く設定にしても明るくならない。
    /// どれくらいの明るさで描くかは、画面ごとのtraitで決める（`MediaDynamicRangeTraits`）。そのため、設定を選び直しても読み込み直さずに済む。
    @concurrent
    private static func decode(_ data: Data, maxPixelSize: Int) async -> UIImage? {
        ImageDecoder.thumbnail(of: data, maxPixelSize: maxPixelSize, dynamicRange: .high).map { UIImage(cgImage: $0) }
    }

    /// 動画の先頭の部分から、0秒目のフレームを`maxPixelSize`まで縮めて作る。AVFoundationはファイルから読むため、一時ファイルに書く。
    @concurrent
    private static func makeVideoFrame(from prefix: Data, maxPixelSize: Int) async throws -> UIImage {
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
        return UIImage(cgImage: try await generator.image(at: .zero).image)
    }

    /// 範囲に応えないサーバー。
    struct RangeNotSupported: Error {}

    /// URLのファイルを読む。範囲を渡したら、その部分だけを読む。
    @concurrent
    nonisolated static func download(_ url: URL, range: Range<Int>?) async throws -> Data {
        guard let range else {
            return try await AppDependencies.remoteFetch.data(from: url)
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        // 範囲に応えないサーバーはファイル全体を返すため、読み始める前に止める。
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            bytes.task.cancel()
            throw RangeNotSupported()
        }
        var data = Data()
        data.reserveCapacity(range.count)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= range.count {
                break
            }
        }
        return data
    }

    /// 元のファイルの名前。共有先でファイル名として見えるため、URLの名前を残し、拡張子は中身の形式に合わせる。
    /// URLの拡張子は付いていなかったり実際の形式と違ったりするため使わない。画像でなければnil。
    @concurrent
    private static func originalFileName(of data: Data, for url: URL) async -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { originalFileName(of: $0, for: url) }
    }

    /// 落としたファイルが画像なら、`originalFileName(of:for:)`と同じく中身の形式に合わせた名前。整理で消えた元のファイルを落とし直したときに使う。
    @concurrent
    nonisolated static func originalFileName(ofFileAt file: URL, for url: URL) async -> String? {
        CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { originalFileName(of: $0, for: url) }
    }

    private nonisolated static func originalFileName(of source: CGImageSource, for url: URL) -> String? {
        guard let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              let pathExtension = type.preferredFilenameExtension
        else { return nil }
        return URL(filePath: url.deletingPathExtension().lastPathComponent).appendingPathExtension(pathExtension).lastPathComponent
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

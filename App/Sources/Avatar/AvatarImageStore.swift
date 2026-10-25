import Foundation
import ImageIO
import os
import SciaCore
import UIKit

/// アイコンの画像を読み込み、メモリに持つ。
///
/// 絵文字と違って、スクロールし続けるとアカウントの数だけ増えるため、上限のあるキャッシュに入れる。
/// 描画のたびにメインスレッドで展開しないよう、表示する大きさまで縮めて展開したものを持つ。
@MainActor
final class AvatarImageStore {
    typealias Fetch = @Sendable (URL) async throws -> Data

    /// アニメーションするアイコンで、展開するコマ数の上限。これより長いものは動かさず、先頭のコマで止める。
    /// 1コマ120ピクセル四方で60KBほどのため、上限まで展開しても1つ数MBに収まる。
    nonisolated static let maxFrameCount = 100

    private let fetch: Fetch
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [Key: Task<UIImage, any Error>] = [:]
    /// 読めなかった画像。先読みと新着の挿入前の待ちでは読み直さず、読めないアイコンのために通信を増やしたり挿入を遅らせたりしない。
    /// 行に描くときは、間隔をおいてから読み直す。読めたら忘れる。
    private var retry: RetrySchedule
    private var listeners: [Listener] = []
    private let logger = SciaLog.logger(category: "avatar")
    /// 読み込みを待つ期限の時計。テストでは手で進める時計に替える。
    let clock: any Clock<Duration>

    init(
        clock: any Clock<Duration> = AppDependencies.clock,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy = { TuningCatalog.imageRetry(in: AppDependencies.tuning) },
        fetch: @escaping Fetch
    ) {
        self.clock = clock
        self.fetch = fetch
        retry = RetrySchedule(policy: retryPolicy, clock: clock)
        // 120ピクセル四方の止まった画像なら500枚ほど入る大きさ。
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    struct Key: Hashable {
        let url: URL
        let maxPixelSize: Int
        /// コマを全部展開するか。オフなら先頭のコマだけにする。
        let animates: Bool

        var cacheKey: NSString { "\(maxPixelSize) \(animates) \(url.absoluteString)" as NSString }
    }

    private struct Listener {
        weak var owner: AnyObject?
        let onLoad: @MainActor (Key) -> Void
    }

    func cachedImage(for key: Key) -> UIImage? {
        cache.object(forKey: key.cacheKey)
    }

    /// 読み込み済みなら画像を返す。まだなら読み込みを始めてnilを返し、届いたら`addListener(owner:onLoad:)`で知らせる。
    /// 文字に差し込むアイコンのように、届いたときに描き直す側が画像を受け取れない場合に使う。
    func requestImage(for key: Key) -> UIImage? {
        if let image = cachedImage(for: key) {
            return image
        }
        if retry.allowsAutomaticLoad(of: key.url) {
            Task { _ = try? await image(for: key) }
        }
        return nil
    }

    /// 行を出す前に読み込みを始める。読み込み済みと、前に読めなかった画像は読まない。
    func prefetch(_ keys: some Sequence<Key>) {
        for key in keys where cachedImage(for: key) == nil && !retry.hasFailed(key.url) {
            Task { _ = try? await image(for: key) }
        }
    }

    /// 画像を読み込み終える（読めなかった場合も含む）か、`timeout`が過ぎるまで待つ。まだ読み込んでいなければ読み込みを始める。
    /// 前に読めなかった画像は、読み直さず待たない。`timeout`で戻っても、読み込みは止めずにキャッシュへ入れる。
    func load(_ keys: Set<Key>, within timeout: Duration) async {
        let missing = keys.filter { cachedImage(for: $0) == nil && !retry.hasFailed($0.url) }
        guard !missing.isEmpty, timeout > .zero else { return }
        let clock = clock
        // 待つ処理が動き出すまでに遅れても、呼ばれた時点から`timeout`で戻るよう、呼ばれた時点から測る。
        let elapsed = stopwatch(on: clock)
        let loads = missing.map { key in Task { _ = try? await image(for: key) } }
        // 読み込みのTaskの結果を待つ（`value`）と、待っている側を取り消しても読み込みが終わるまで戻らないため、
        // 先に終わった方が続きを再開させる。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = Resumer(continuation)
            let timer = Task {
                let remaining = timeout - elapsed()
                if remaining > .zero {
                    try? await clock.sleep(for: remaining)
                }
                resumer.resume()
            }
            Task {
                for load in loads {
                    await load.value
                }
                timer.cancel()
                resumer.resume()
            }
        }
    }

    /// 続きを一度だけ再開させる。
    private final class Resumer {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// 画像が届いたときに呼ぶ処理を登録する。`owner`が解放されると呼ばれなくなる。
    func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Key) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    /// 画像を読み込む。同じ画像を読み込んでいる途中なら、その結果を待つ。
    /// 呼び出し側のタスクを取り消しても、読み込みは止めずにキャッシュへ入れる。同じアカウントの投稿が続けて並ぶことが多いため。
    /// 前に読めなかった画像は、読み直してよくなるまで`ImageLoadDeferred`を投げる。
    /// - Parameter retriesNow: 使う人が自分で見に行った操作（投稿のメニューを開くなど）で、間隔を待たずに読み直す。
    func image(for key: Key, retriesNow: Bool = false) async throws -> UIImage {
        if let image = cache.object(forKey: key.cacheKey) {
            return image
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        guard retriesNow || retry.allowsAutomaticLoad(of: key.url) else {
            throw ImageLoadDeferred()
        }
        let fetch = fetch
        // 行に描いたときの読み込みは自動の通信として送り、止められている間は送らない（docs/network.md）。
        let task = RequestOrigin.$current.withValue(retriesNow ? .user : .automatic) {
            Task<UIImage, any Error> {
                let data = try await fetch(key.url)
                guard let image = await Self.decode(data, maxPixelSize: key.maxPixelSize, animates: key.animates) else {
                    throw DecodeError()
                }
                return image
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let image = try await task.value
            cache.setObject(image, forKey: key.cacheKey, cost: Self.cost(of: image))
            retry.recordSuccess(for: key.url)
            listeners.removeAll { $0.owner == nil }
            for listener in listeners {
                listener.onLoad(key)
            }
            return image
        } catch {
            logger.error("avatar load failed host=\(SciaLog.host(of: key.url), privacy: .public) url=\(key.url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
            retry.recordFailure(error, for: key.url)
            throw error
        }
    }

    struct DecodeError: Error {}

    /// `maxPixelSize`まで縮めて展開する。`animates`なら、GIF・APNG・WebPのコマを、それぞれの表示時間に合わせて並べる。
    @concurrent
    private static func decode(_ data: Data, maxPixelSize: Int, animates: Bool) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // HDRの画像はHDRのまま展開し、描く明るさは画面ごとのtraitで決める。`MediaImageStore`と同じ。
        let frame = { (index: Int) in ImageDecoder.thumbnail(of: source, at: index, maxPixelSize: maxPixelSize, dynamicRange: .high) }
        let count = CGImageSourceGetCount(source)
        guard animates, count > 1, count <= maxFrameCount else {
            return frame(0).map { UIImage(cgImage: $0) }
        }
        // UIImage.animatedImageはコマを均等な間隔で流すため、表示時間の最大公約数を1コマの長さにして、長いコマを繰り返して並べる。
        let centiseconds = (0..<count).map { max(Int((frameDuration(of: source, at: $0) * 100).rounded()), 1) }
        let unit = centiseconds.reduce(0, gcd)
        let repeats = centiseconds.map { $0 / unit }
        guard repeats.reduce(0, +) <= maxExpandedFrameCount else {
            return frame(0).map { UIImage(cgImage: $0) }
        }
        var frames: [UIImage] = []
        for index in 0..<count {
            guard let frame = frame(index) else { return nil }
            frames += Array(repeating: UIImage(cgImage: frame), count: repeats[index])
        }
        return UIImage.animatedImage(with: frames, duration: TimeInterval(centiseconds.reduce(0, +)) / 100)
    }

    /// 表示時間を揃えるためにコマを繰り返したあとの、並べるコマ数の上限。同じ画像を指すため、メモリは増えない。
    /// これより多くなる組み合わせ（表示時間が細かく不揃いなもの）は、動かさずに先頭のコマで止める。
    nonisolated static let maxExpandedFrameCount = 1_000

    private nonisolated static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }

    /// 1コマの表示時間。0や極端に短い値は、ブラウザと同じく0.1秒として扱う。
    private nonisolated static func frameDuration(of source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in dictionaries {
            guard let dictionary = properties?[dictionaryKey] as? [CFString: Any] else { continue }
            let delay = (dictionary[unclampedKey] as? Double) ?? (dictionary[clampedKey] as? Double) ?? 0
            return delay < 0.02 ? 0.1 : delay
        }
        return 0.1
    }

    private static func cost(of image: UIImage) -> Int {
        let frames = image.images ?? [image]
        return frames.reduce(0) { total, frame in
            guard let cgImage = frame.cgImage else { return total }
            return total + cgImage.bytesPerRow * cgImage.height
        }
    }
}

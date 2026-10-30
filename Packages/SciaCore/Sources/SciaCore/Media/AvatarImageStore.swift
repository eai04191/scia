public import Foundation
import ImageIO
import os

/// アイコンの画像を読み込み、メモリに持つ。`Image`は描く側の画像の型で、iOSでは`UIImage`にする。
///
/// 絵文字と違って、スクロールし続けるとアカウントの数だけ増えるため、上限のあるキャッシュに入れる。
/// 描画のたびにメインスレッドで展開しないよう、表示する大きさまで縮めて展開したものを持つ。
@MainActor
public final class AvatarImageStore<Image: Sendable> {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// アニメーションするアイコンで、展開するコマ数の上限。これより長いものは動かさず、先頭のコマで止める。
    /// 1コマ120ピクセル四方で60KBほどのため、上限まで展開しても1つ数MBに収まる。
    public nonisolated static var maxFrameCount: Int { 100 }

    private let fetch: Fetch
    private let maker: PlatformImageMaker<Image>
    private let cache = NSCache<NSString, Entry>()
    private var inFlight: [AvatarImageKey: Task<Decoded, any Error>] = [:]
    /// 読めなかった画像。先読みと新着の挿入前の待ちでは読み直さず、読めないアイコンのために通信を増やしたり挿入を遅らせたりしない。
    /// 行に描くときは、間隔をおいてから読み直す。読めたら忘れる。
    private var retry: RetrySchedule
    private var listeners: [Listener] = []
    private let logger = SciaLog.logger(category: "avatar")
    /// 読み込みを待つ期限の時計。テストでは手で進める時計に替える。
    public let clock: any Clock<Duration>

    public init(
        clock: any Clock<Duration>,
        retryPolicy: @escaping @MainActor () -> RetrySchedule.Policy,
        maker: PlatformImageMaker<Image>,
        fetch: @escaping Fetch
    ) {
        self.clock = clock
        self.fetch = fetch
        self.maker = maker
        retry = RetrySchedule(policy: retryPolicy, clock: clock)
        // 120ピクセル四方の止まった画像なら500枚ほど入る大きさ。
        cache.totalCostLimit = 32 * 1_024 * 1_024
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

    private struct Listener {
        weak var owner: AnyObject?
        let onLoad: @MainActor (AvatarImageKey) -> Void
    }

    public func cachedImage(for key: AvatarImageKey) -> Image? {
        cache.object(forKey: key.cacheKey)?.image
    }

    /// 読み込み済みなら画像を返す。まだなら読み込みを始めてnilを返し、届いたら`addListener(owner:onLoad:)`で知らせる。
    /// 文字に差し込むアイコンのように、届いたときに描き直す側が画像を受け取れない場合に使う。
    public func requestImage(for key: AvatarImageKey) -> Image? {
        if let image = cachedImage(for: key) {
            return image
        }
        if retry.allowsAutomaticLoad(of: key.url) {
            Task { _ = try? await image(for: key) }
        }
        return nil
    }

    /// 行を出す前に読み込みを始める。読み込み済みと、前に読めなかった画像は読まない。
    public func prefetch(_ keys: some Sequence<AvatarImageKey>) {
        for key in keys where cachedImage(for: key) == nil && !retry.hasFailed(key.url) {
            Task { _ = try? await image(for: key) }
        }
    }

    /// 画像を読み込み終える（読めなかった場合も含む）か、`timeout`が過ぎるまで待つ。まだ読み込んでいなければ読み込みを始める。
    /// 前に読めなかった画像は、読み直さず待たない。`timeout`で戻っても、読み込みは止めずにキャッシュへ入れる。
    public func load(_ keys: Set<AvatarImageKey>, within timeout: Duration) async {
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
    public func addListener(owner: AnyObject, onLoad: @escaping @MainActor (AvatarImageKey) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    /// 画像を読み込む。同じ画像を読み込んでいる途中なら、その結果を待つ。
    /// 呼び出し側のタスクを取り消しても、読み込みは止めずにキャッシュへ入れる。同じアカウントの投稿が続けて並ぶことが多いため。
    /// 前に読めなかった画像は、読み直してよくなるまで`ImageLoadDeferred`を投げる。
    /// - Parameter retriesNow: 使う人が自分で見に行った操作（投稿のメニューを開くなど）で、間隔を待たずに読み直す。
    public func image(for key: AvatarImageKey, retriesNow: Bool = false) async throws -> Image {
        if let image = cachedImage(for: key) {
            return image
        }
        if let task = inFlight[key] {
            return try await task.value.image
        }
        guard retriesNow || retry.allowsAutomaticLoad(of: key.url) else {
            throw ImageLoadDeferred()
        }
        let fetch = fetch
        let maker = maker
        // 行に描いたときの読み込みは自動の通信として送り、止められている間は送らない（docs/network.md）。
        let task = RequestPurpose.$current.withValue(retriesNow ? .action : .display) {
            Task<Decoded, any Error> {
                let data = try await fetch(key.url)
                guard let decoded = await Self.decode(data, maxPixelSize: key.maxPixelSize, animates: key.animates, maker: maker) else {
                    throw DecodeError()
                }
                return decoded
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let decoded = try await task.value
            cache.setObject(Entry(decoded.image), forKey: key.cacheKey, cost: decoded.cost)
            retry.recordSuccess(for: key.url)
            listeners.removeAll { $0.owner == nil }
            for listener in listeners {
                listener.onLoad(key)
            }
            return decoded.image
        } catch {
            logger.error("avatar load failed host=\(SciaLog.host(of: key.url), privacy: .public) url=\(key.url.absoluteString, privacy: .private(mask: .hash)): \(SciaLog.describe(error), privacy: .public)")
            retry.recordFailure(error, for: key.url)
            throw error
        }
    }

    public struct DecodeError: Error {}

    /// `maxPixelSize`まで縮めて展開する。`animates`なら、GIF・APNG・WebPのコマを、それぞれの表示時間に合わせて並べる。
    @concurrent
    private static func decode(_ data: Data, maxPixelSize: Int, animates: Bool, maker: PlatformImageMaker<Image>) async -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // HDRの画像はHDRのまま展開し、描く明るさは画面ごとのtraitで決める。`MediaImageStore`と同じ。
        let frame = { (index: Int) in ImageDecoder.thumbnail(of: source, at: index, maxPixelSize: maxPixelSize, dynamicRange: .high) }
        let still = { (index: Int) in frame(index).map { Decoded(image: maker.still($0), cost: PlatformImageMaker<Image>.cost(of: $0)) } }
        let count = CGImageSourceGetCount(source)
        guard animates, count > 1, count <= maxFrameCount else {
            return still(0)
        }
        // 描く側の動く画像はコマを均等な間隔で流すため、表示時間の最大公約数を1コマの長さにして、長いコマを繰り返して並べる。
        let centiseconds = (0..<count).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            return max(Int((AnimatedImage.frameDuration(properties) * 100).rounded()), 1)
        }
        let unit = centiseconds.reduce(0, gcd)
        let repeats = centiseconds.map { $0 / unit }
        guard repeats.reduce(0, +) <= maxExpandedFrameCount else {
            return still(0)
        }
        var frames: [CGImage] = []
        for index in 0..<count {
            guard let frame = frame(index) else { return nil }
            frames += Array(repeating: frame, count: repeats[index])
        }
        let cost = frames.reduce(0) { $0 + PlatformImageMaker<Image>.cost(of: $1) }
        return maker.animated(frames, TimeInterval(centiseconds.reduce(0, +)) / 100).map { Decoded(image: $0, cost: cost) }
    }

    /// 表示時間を揃えるためにコマを繰り返したあとの、並べるコマ数の上限。同じ画像を指すため、メモリは増えない。
    /// これより多くなる組み合わせ（表示時間が細かく不揃いなもの）は、動かさずに先頭のコマで止める。
    public nonisolated static var maxExpandedFrameCount: Int { 1_000 }

    private nonisolated static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}

/// アイコンを読み込んで持つときの区別。同じURLでも、縮める大きさと動かすかごとに分けて持つ。
public struct AvatarImageKey: Hashable, Sendable {
    public let url: URL
    public let maxPixelSize: Int
    /// コマを全部展開するか。オフなら先頭のコマだけにする。
    public let animates: Bool

    public init(url: URL, maxPixelSize: Int, animates: Bool) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.animates = animates
    }

    var cacheKey: NSString { "\(maxPixelSize) \(animates) \(url.absoluteString)" as NSString }
}

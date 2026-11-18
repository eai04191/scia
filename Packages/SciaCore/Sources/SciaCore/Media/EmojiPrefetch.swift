public import Foundation
import os

/// `api/v1/custom_emojis`の応答を読んだあと、自分のサーバーの絵文字の画像を、先読み（`prefetch`）として裏で取得する
/// （docs/animated-custom-emoji.mdの「自分のサーバーの絵文字の先読み」）。
/// 初めて起動したあと、絵文字ピッカーを初めて流すときから、枠を空けないため。
///
/// 取得するのは、元の画像がAにない絵文字のうち、次のもの。
/// - 絵文字ピッカーの小さい静止画がないもの。取得した画像から小さい静止画を作る。
/// - 小さい静止画はあるが、必須でない用途の空き容量が足りるもの。足りないときは、持たずに捨てる元の画像を応答を読むたびに取得し直さないよう、取得しない。
/// 元の画像は、必須でない用途の空きが、残りの取得量の見積もりに足りるときだけAとして持ち、足りなければ小さい静止画を作ったあと捨てる。
public struct EmojiPrefetch: Sendable {
    /// 取得する前に見積もる、画像1つの大きさ。fedibird.comの絵文字の元の画像の、150個の抜き取りの平均（約20KB）。取得したあとは、取得した画像の平均を使う。
    static let estimatedImageSize = 20 * 1_024

    /// 先読みを送れない（回線、低データモード、レート制限）。残りは取得せずに終える。送らなかった分は、その絵文字を描くときに取得する。
    public struct NotAllowed: Error, Sendable {
        public init() {}
    }

    /// この画像は先読みしない（前に読めなかった、読み直しを待っている）。数えずに次へ進む。
    public struct Skipped: Error, Sendable {
        public init() {}
    }

    /// 終えたときの数。
    public struct Result: Equatable, Sendable {
        public var fetched = 0
        public var keptOriginals = 0
        public var failed = 0
        /// 送れずに、残りを取得せずに終えたか。
        public var stopped = false
    }

    private let files: EmojiImageFiles
    private let fetch: @Sendable (URL) async throws -> Data
    private let hasThumbnail: @Sendable (URL) -> Bool
    private let makeThumbnail: @Sendable (URL, Data) async -> Void
    private let logger = SciaLog.logger(category: "emoji")

    /// - Parameters:
    ///   - fetch: 先読みとして取得する。送れなければ`NotAllowed`か`AutomaticRequestsPaused`を、この画像を先読みしないなら`Skipped`を投げる。
    ///   - hasThumbnail: 絵文字ピッカーの小さい静止画があるか。
    ///   - makeThumbnail: 取得した画像から、小さい静止画を作って足す。
    public init(
        files: EmojiImageFiles,
        fetch: @escaping @Sendable (URL) async throws -> Data,
        hasThumbnail: @escaping @Sendable (URL) -> Bool,
        makeThumbnail: @escaping @Sendable (URL, Data) async -> Void
    ) {
        self.files = files
        self.fetch = fetch
        self.hasThumbnail = hasThumbnail
        self.makeThumbnail = makeThumbnail
    }

    /// `urls`（絵文字ピッカーで描く画像のURL）を取得する。止められたら（`Task.isCancelled`）、途中で終える。
    public func run(_ urls: [URL]) async -> Result {
        var withoutThumbnail: [URL] = []
        var withThumbnail: [URL] = []
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard await !files.containsListed(url) else { continue }
            if hasThumbnail(url) {
                withThumbnail.append(url)
            } else {
                withoutThumbnail.append(url)
            }
        }
        var result = Result()
        guard !withoutThumbnail.isEmpty || !withThumbnail.isEmpty else { return result }
        var fetchedBytes = 0
        func remaining(_ count: Int) -> Int {
            count * (result.fetched > 0 ? fetchedBytes / result.fetched : Self.estimatedImageSize)
        }
        // 空白を防ぐ小さい静止画のない分を先に取得する。
        var keepsOriginals = await files.hasRoom(for: remaining(withoutThumbnail.count + withThumbnail.count), rereading: true)
        var queue = withoutThumbnail + (keepsOriginals ? withThumbnail : [])
        var index = 0
        while index < queue.count, !result.stopped {
            guard !Task.isCancelled else { break }
            let batch = Array(queue[index..<min(index + Self.concurrentFetches, queue.count)])
            index += batch.count
            let fetched = await fetchAll(batch)
            for (url, outcome) in zip(batch, fetched) {
                let data: Data
                switch outcome {
                case .success(let fetchedData):
                    data = fetchedData
                case .failure(let error) where error is Skipped:
                    continue
                case .failure(let error) where error is NotAllowed || error is AutomaticRequestsPaused || error is CancellationError:
                    result.stopped = true
                    continue
                case .failure(let error):
                    result.failed += 1
                    logger.error("emoji prefetch failed: \(SciaLog.describe(error), privacy: .public)")
                    continue
                }
                result.fetched += 1
                fetchedBytes += data.count
                if !hasThumbnail(url) {
                    await makeThumbnail(url, data)
                }
                guard keepsOriginals else { continue }
                do {
                    if try await files.storeListed(data, named: url.lastPathComponent, for: url, remaining: remaining(queue.count - index + 1)) {
                        result.keptOriginals += 1
                    } else {
                        // 足りなくなったら、それ以降の元の画像は持たない。小さい静止画があって、元の画像のためだけに取得するものは取得しない。
                        keepsOriginals = false
                        let rest = queue[index...].filter { !hasThumbnail($0) }
                        queue = Array(queue[..<index]) + rest
                    }
                } catch {
                    logger.error("emoji prefetch store failed: \(SciaLog.describe(error), privacy: .public)")
                }
            }
        }
        logger.info("emoji prefetch fetched=\(result.fetched, privacy: .public) kept=\(result.keptOriginals, privacy: .public) failed=\(result.failed, privacy: .public) stopped=\(result.stopped, privacy: .public)")
        return result
    }

    /// 同時に取得する数。1つずつでは、fedibird.comの6000個ほどを取得し終えるまで、1つの往復の長さの6000倍かかるため。
    static let concurrentFetches = 4

    /// `urls`を同時に取得し、結果を`urls`の順に返す。`urls`に同じURLは入れない。
    /// 子のタスクは、結果を`Result`にまとめてから組にして返す。`do { return (key, .success(try await …)) } catch { return (key, .failure(error)) }`の形で返すと、
    /// Swift 6.4.2の最適化したビルドでは、成功したときに組の1つ目が書き込まれない（swiftlang/swift#92698）。
    /// 並びの番号を1つ目にしていたとき、取得した画像がどれも先頭のURLの結果になり、先頭のURLの画像として別の絵文字の画像を端末に置いていた。
    /// 1つ目が書き込まれなくても別のURLの結果にならないよう、結果は取得したURLで引く。
    private func fetchAll(_ urls: [URL]) async -> [Swift.Result<Data, any Error>] {
        await withTaskGroup(of: (URL, Swift.Result<Data, any Error>).self) { group in
            for url in urls {
                group.addTask { [fetch] in (url, await Swift.Result { try await fetch(url) }) }
            }
            var results: [URL: Swift.Result<Data, any Error>] = [:]
            for await (url, result) in group {
                results[url] = result
            }
            return urls.map { results[$0] ?? .failure(CancellationError()) }
        }
    }
}

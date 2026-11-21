import os
import SciaCore
import UIKit

/// 端末に残した`api/v1/custom_emojis`の応答が変わったら、端末に置く絵文字の画像を分け直し、自分のサーバーの絵文字の画像を先読みする
/// （docs/animated-custom-emoji.mdの「自分のサーバーの絵文字の先読み」）。取得し終えたら、絵文字ピッカーの小さい静止画をまとめて作る処理を始める。
@MainActor
final class EmojiPrefetcher {
    private var task: Task<Void, Never>?
    /// 始めた作業ごとに進める。止めた作業が終わったときに、あとで始めた作業の控え（`task`）を消さないため。
    private var taskGeneration = 0
    private let run: @Sendable (_ prefetches: Bool) async -> Void
    private let didFinish: @MainActor () -> Void

    /// - Parameters:
    ///   - run: 分け直し、`prefetches`なら先読みする。止められたら（`Task.isCancelled`）、途中で終える。テストでは差し替える。
    ///   - didFinish: 先読みし終えたときに呼ぶ。
    init(run: (@Sendable (Bool) async -> Void)? = nil, didFinish: (@MainActor () -> Void)? = nil) {
        self.run = run ?? Self.makeRun()
        self.didFinish = didFinish ?? { AppDependencies.emojiThumbnailBuilder.start() }
    }

    /// 起動したときに呼ぶ。端末に残した応答で分け直すだけで、取得はしない。取得するのは、応答を読んだときだけにする。
    func start() {
        begin(prefetches: false)
    }

    /// 応答を読んで書き出したときと、ログアウトして応答を消したときに呼ぶ。途中の作業は止めて、初めからやり直す。
    func listsChanged() {
        begin(prefetches: true)
    }

    private func begin(prefetches: Bool) {
        task?.cancel()
        taskGeneration += 1
        let generation = taskGeneration
        let run = run
        task = Task(.withoutRequests, priority: .utility) { [weak self] in
            await run(prefetches)
            guard let self, taskGeneration == generation else { return }
            task = nil
            if prefetches {
                didFinish()
            }
        }
    }

    /// 作っている途中か。テストで、終えたことを確かめるのに使う。
    var isRunning: Bool { task != nil }

    private static func makeRun() -> @Sendable (Bool) async -> Void {
        let files = AppDependencies.emojiImageFiles
        let customEmojis = AppDependencies.customEmojis
        let thumbnails = AppDependencies.emojiThumbnails
        let emojiImages = AppDependencies.emojiImages
        let choice = emojiImages.choice(animates: true)
        let oversized = AppDependencies.oversizedEmojis
        let network = AppDependencies.network
        let settings = AppDependencies.settings
        let remoteFetch = AppDependencies.remoteFetch
        let prefetch = EmojiPrefetch(
            files: files,
            fetch: { url in
                // 前に読めなかった画像は先読みせず、先読みで読めなかったら、表示の読み込みと同じく覚える（docs/image-loading.md）。
                guard await emojiImages.allowsPrefetch(of: url) else { throw EmojiPrefetch.Skipped() }
                guard let purpose = await network.usePolicy(settings: settings).prefetch else { throw EmojiPrefetch.NotAllowed() }
                do {
                    return try await RequestPurpose.$current.withValue(purpose) { try await remoteFetch.data(from: url) }
                } catch {
                    await emojiImages.recordPrefetchFailure(error, for: url)
                    throw error
                }
            },
            hasThumbnail: { thumbnails.contains($0) },
            makeThumbnail: { url, data in
                let maxPixelSize = ImageDecoder.maxPixelSize(forHeight: thumbnails.pixelHeight, of: data)
                guard let image = await ImageDecoder.thumbnail(of: data, maxPixelSize: maxPixelSize, dynamicRange: .standard) else { return }
                thumbnails.add(url, image: image)
            }
        )
        return { prefetches in
            let emojis = await customEmojis.storedEmojis()
            await files.updateListed(Set(emojis.flatMap { [$0.url, $0.staticUrl] }))
            if prefetches, !Task.isCancelled {
                thumbnails.load()
                // 絵文字ピッカーに出る絵文字だけを、絵文字ピッカーと同じく、元の画像か、起動したときに大きすぎると分かっていた元の画像なら動かない版で取得する。
                // この起動のうちに大きすぎると分かった元の画像も、置き直さないよう、動かない版を取得する。
                _ = await prefetch.run(emojis.filter(\.visibleInPicker).map { oversized.contains($0.url) ? $0.staticUrl : choice.url(of: $0) })
            }
            await files.refreshStats()
        }
    }
}

import os
import SciaCore
import UIKit

/// 絵文字のパレットの小さい静止画（`EmojiThumbnails`）を、パレットを閉じている間に、端末に置いた画像から作る。
/// 一度も表示していない絵文字も、初めて流したときから枠が空かないようにするため（docs/animated-custom-emoji.mdの「絵文字ピッカーの小さい静止画」）。
/// パレットが開いている間は作らない。作る処理がCPUを使い、パレットの絵文字の読み込みを待たせるため。
/// 通信はしない。端末に置いていない画像の分は、表示して画像を読んだときに作る。
@MainActor
final class EmojiThumbnailBuilder {
    private var shownPalettes = 0
    private var task: Task<Void, Never>?
    /// 始めた作業ごとに進める。止めた作業が終わったときに、あとで始めた作業の控え（`task`）を消さないため。
    private var taskGeneration = 0
    private let build: @Sendable () async -> Void

    /// - Parameter build: 作る処理。止められたら（`Task.isCancelled`）、途中で終える。テストでは差し替える。
    init(build: (@Sendable () async -> Void)? = nil) {
        self.build = build ?? Self.makeBuild()
    }

    /// パレットが画面に出たら、作るのを止める。
    func paletteDidAppear() {
        shownPalettes += 1
        task?.cancel()
        task = nil
    }

    /// パレットが全部閉じたら、作り始める。
    func paletteDidDisappear() {
        shownPalettes = max(shownPalettes - 1, 0)
        start()
    }

    /// パレットが開いていなければ、作り始める。作っている途中なら何もしない。
    func start() {
        guard shownPalettes == 0, task == nil else { return }
        taskGeneration += 1
        let generation = taskGeneration
        let build = build
        task = Task(.withoutRequests, priority: .background) { [weak self] in
            await build()
            guard let self else { return }
            finishedCount += 1
            guard taskGeneration == generation else { return }
            task = nil
        }
    }

    /// 終えた作業の数。止めた作業も数える。テストで、止めた作業が終わるのを待つのに使う。
    private(set) var finishedCount = 0

    /// 作っている途中か。テストで、止めたことを確かめるのに使う。
    var isBuilding: Bool { task != nil }

    private static func makeBuild() -> @Sendable () async -> Void {
        let thumbnails = AppDependencies.emojiThumbnails
        let customEmojis = AppDependencies.customEmojis
        let files = AppDependencies.emojiImageFiles
        let choice = AppDependencies.emojiImages.choice(animates: true)
        let logger = SciaLog.logger(category: "emoji")
        return { await build(thumbnails: thumbnails, customEmojis: customEmojis, files: files, choice: choice, logger: logger) }
    }

    @concurrent
    private static func build(thumbnails: EmojiThumbnails, customEmojis: CustomEmojiCaches, files: MediaFileCache, choice: EmojiImageChoice, logger: Logger) async {
        thumbnails.load()
        let emojis = await customEmojis.storedEmojis()
        // パレットと同じく、元の画像か、起動したときに大きすぎると分かっていた元の画像なら動かない版で作る。
        await thumbnails.prune(keeping: Set(emojis.map { choice.url(of: $0) }))
        var made = 0
        for emoji in emojis {
            guard !Task.isCancelled else { break }
            let url = choice.url(of: emoji)
            // 読んでいる間に、使う人が設定のストレージで消したら、作った画像を足さない。
            let generation = thumbnails.generation
            guard !thumbnails.contains(url), let data = await files.data(for: url, touching: false) else { continue }
            let maxPixelSize = ImageDecoder.maxPixelSize(forHeight: thumbnails.pixelHeight, of: data)
            guard let image = await ImageDecoder.thumbnail(of: data, maxPixelSize: maxPixelSize, dynamicRange: .standard) else { continue }
            thumbnails.add(url, image: image, generation: generation)
            made += 1
        }
        logger.info("emoji thumbnails built made=\(made, privacy: .public) total=\(thumbnails.count, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
    }
}

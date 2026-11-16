import os
import SciaCore
import UIKit

/// 絵文字ピッカーの小さい静止画（`EmojiThumbnails`）と、Unicodeの絵文字の画像（`EmojiGlyphArchive`）を、裏で作る。
/// 一度も表示していない絵文字も、初めて流したときから枠が空かないようにするため（docs/animated-custom-emoji.mdの「絵文字ピッカーの小さい静止画」）。
/// 絵文字ピッカーが開いている間は、Unicodeの絵文字の小さい画像だけを作り、ほかは閉じるまで待つ。作る処理がCPUを使い、絵文字ピッカーの絵文字の読み込みを待たせるため。
/// Unicodeの絵文字の小さい画像だけは、作り終える前に初めて開いたときも枠を空けないよう、開いている間も作る。
/// 通信はしない。端末に置いていない画像の分は、表示して画像を読んだときに作る。
@MainActor
final class EmojiThumbnailBuilder {
    private var shownPalettes = 0
    private var task: Task<Void, Never>?
    /// 絵文字ピッカーが開いている間の作業。
    private var shownTask: Task<Void, Never>?
    /// 始めた作業ごとに進める。止めた作業が終わったときに、あとで始めた作業の控え（`task`）を消さないため。
    private var taskGeneration = 0
    private let build: @Sendable () async -> Void
    private let buildWhileShown: @Sendable () async -> Void

    /// - Parameters:
    ///   - build: 閉じている間に作る処理。止められたら（`Task.isCancelled`）、途中で終える。テストでは差し替える。
    ///   - buildWhileShown: 開いている間に作る処理（Unicodeの絵文字の小さい画像）。
    init(build: (@Sendable () async -> Void)? = nil, buildWhileShown: (@Sendable () async -> Void)? = nil) {
        self.build = build ?? Self.makeBuild()
        self.buildWhileShown = buildWhileShown ?? Self.makeGlyphBuild(includesFull: false)
    }

    /// 絵文字ピッカーが画面に出たら、閉じている間の作業を止め、開いている間の作業を始める。
    func paletteDidAppear() {
        shownPalettes += 1
        task?.cancel()
        task = nil
        guard shownTask == nil else { return }
        let buildWhileShown = buildWhileShown
        shownTask = Task(.withoutRequests, priority: .background) { await buildWhileShown() }
    }

    /// 絵文字ピッカーが全部閉じたら、開いている間の作業を止め、閉じている間の作業を始める。
    func paletteDidDisappear() {
        shownPalettes = max(shownPalettes - 1, 0)
        if shownPalettes == 0 {
            shownTask?.cancel()
            shownTask = nil
        }
        start()
    }

    /// 絵文字ピッカーが開いていなければ、作り始める。作っている途中なら何もしない。
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

    /// 開いている間の作業をしているか。テストで確かめるのに使う。
    var isBuildingWhileShown: Bool { shownTask != nil }

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
        let glyphBuild = makeGlyphBuild(includesFull: true)
        return {
            await build(thumbnails: thumbnails, customEmojis: customEmojis, files: files, choice: choice, logger: logger)
            guard !Task.isCancelled else { return }
            await glyphBuild()
        }
    }

    /// Unicodeの絵文字の画像を作る処理（docs/animated-custom-emoji.mdの「Unicodeの絵文字の画像」）。
    /// 描く大きさは、絵文字ピッカーが記録したものがあればそれを使い、なければ絵文字ピッカーのマスの大きさ（チューニング）と画面の倍率から決める。
    /// 絵文字ピッカーを一度も並べていなくても、初めて開く前に作れるようにするため。
    private static func makeGlyphBuild(includesFull: Bool) -> @Sendable () async -> Void {
        let glyphs = AppDependencies.emojiGlyphArchive
        let settings = AppDependencies.settings
        let tuning = AppDependencies.tuning
        return {
            let (style, texts, geometry) = await MainActor.run {
                let style = settings.appearance.emojiStyle
                let side = tuning.value(of: TuningCatalog.composeEmojiPaletteCellSize)
                let geometry = displayScale().map { EmojiPaletteCell.glyphGeometry(cellSize: CGSize(width: side, height: side), scale: $0, style: style) }
                // 絵文字ピッカーは既定の肌の色で並べるので、その色の画像を作る。
                return (style, StandardEmojiAvailability.groups(for: style, skinTone: settings.emojiSkinTone).flatMap { $0.emojis.map(\.emoji) }, geometry)
            }
            // 絵文字ピッカーが記録した大きさがあれば、それを使う。なければ計算した大きさで作る。
            if !glyphs.loadStoredGeometry(style: style), let geometry {
                glyphs.use(geometry)
            }
            await glyphs.build(texts, includesFull: includesFull)
        }
    }

    /// 画面の倍率。シーンがまだつながっていなければnilで、前に記録した大きさで作る。
    private static func displayScale() -> CGFloat? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.traitCollection.displayScale }.first { $0 > 0 }
    }

    @concurrent
    private static func build(thumbnails: EmojiThumbnails, customEmojis: CustomEmojiCaches, files: EmojiImageFiles, choice: EmojiImageChoice, logger: Logger) async {
        thumbnails.load()
        let emojis = await customEmojis.storedEmojis()
        // パレットと同じく、元の画像か、起動したときに大きすぎると分かっていた元の画像なら動かない版で作る。
        await thumbnails.prune(keeping: Set(emojis.map { choice.url(of: $0) }))
        var made = 0
        for emoji in emojis {
            guard !Task.isCancelled else { break }
            let url = choice.url(of: emoji)
            guard !thumbnails.contains(url), let data = await files.data(for: url, touching: false) else { continue }
            let maxPixelSize = ImageDecoder.maxPixelSize(forHeight: thumbnails.pixelHeight, of: data)
            guard let image = await ImageDecoder.thumbnail(of: data, maxPixelSize: maxPixelSize, dynamicRange: .standard) else { continue }
            thumbnails.add(url, image: image)
            made += 1
        }
        logger.info("emoji thumbnails built made=\(made, privacy: .public) total=\(thumbnails.count, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
    }
}

import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct CustomEmojiCacheTests {
    private let directory = TestScratch.url("CustomEmojiCacheTests")
    private let clock = TestClock()
    private let instance = URL(string: "https://example.social")!
    private let files = URL(string: "https://files.example.social")!

    private func makeCaches() -> CustomEmojiCaches {
        CustomEmojiCaches(directory: directory, clock: clock)
    }

    private func emoji(_ shortcode: String, version: Int = 1, aspectRatio: Double? = nil) -> ServerEmoji {
        ServerEmoji(
            shortcode: shortcode,
            url: files.appending(path: "original/\(shortcode)-\(version).gif"),
            staticUrl: files.appending(path: "static/\(shortcode)-\(version).png"),
            aspectRatio: aspectRatio
        )
    }

    private var file: URL { directory.appending(path: "example.social.json") }

    /// 端末に書き出したファイルを読み直したキャッシュが、書き出した中身を持つまで待つ。
    private func restored(_ caches: CustomEmojiCaches) async throws -> CustomEmojiCache.Snapshot {
        let cache = caches.cache(for: instance)
        try await waitUntil { cache.snapshot.emojis != nil }
        return cache.snapshot
    }

    /// 書き出したリストと、画像から分かった縦横比は、起動し直しても残る。残したリストは読み直すものとして渡す。
    @Test func keepsEmojisAndLearnedAspectRatiosAcrossLaunches() async throws {
        let cache = makeCaches().cache(for: instance)
        cache.remember([emoji("wide"), emoji("square")], loadStartedAt: cache.generation)
        cache.learn(emoji("wide").staticUrl, width: 400, height: 100)
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: CustomEmojiCache.saveDelay)
        try await waitUntil {
            (try? JSONDecoder().decode(StoredCustomEmojis.self, from: Data(contentsOf: file)))?.emojis.first?.aspectRatio == 4
        }

        let snapshot = try await restored(makeCaches())

        #expect(snapshot.emojis?.map(\.shortcode) == ["wide", "square"])
        #expect(!snapshot.isFresh)
        #expect(snapshot.learnedAspectRatios == [emoji("wide").staticUrl: 4])
    }

    /// アニメーション版の画像が届いても、静止画のURLで縦横比を残す。投稿の本文で動かして描いた絵文字も、パレットで使えるようにするため。
    /// リストにない絵文字（ほかのサーバーの絵文字）と、サーバーが縦横比を返した絵文字は残さない。
    @Test func learnsOnlyEmojisInListWithoutServerAspectRatio() {
        let cache = makeCaches().cache(for: instance)
        cache.remember([emoji("wide"), emoji("fedibird", aspectRatio: 2)], loadStartedAt: cache.generation)

        cache.learn(emoji("wide").url, width: 300, height: 100)
        cache.learn(emoji("fedibird").staticUrl, width: 100, height: 100)
        cache.learn(emoji("elsewhere").staticUrl, width: 500, height: 100)

        #expect(cache.snapshot.learnedAspectRatios == [emoji("wide").staticUrl: 3])
    }

    /// 読み直したリストでは、静止画のURLが同じ絵文字だけ縦横比を引き継ぐ。リストから消えた絵文字と、画像を差し替えた絵文字の分は捨てる。
    @Test func carriesOverAspectRatiosOnlyForSameImage() {
        let cache = makeCaches().cache(for: instance)
        cache.remember([emoji("kept"), emoji("replaced"), emoji("removed")], loadStartedAt: cache.generation)
        for shortcode in ["kept", "replaced", "removed"] {
            cache.learn(emoji(shortcode).staticUrl, width: 200, height: 100)
        }

        cache.remember([emoji("kept"), emoji("replaced", version: 2)], loadStartedAt: cache.generation)

        #expect(cache.snapshot.learnedAspectRatios == [emoji("kept").staticUrl: 2])
        #expect(cache.snapshot.isFresh == true)
    }

    /// 消すと、メモリのリストもファイルも消える。消したあとに分かった縦横比で、消したリストを書き戻さない。
    @Test func removeAllForgetsMemoryAndFile() async throws {
        let caches = makeCaches()
        let cache = caches.cache(for: instance)
        cache.remember([emoji("wide")], loadStartedAt: cache.generation)
        try await waitUntil { FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) }

        await caches.removeAll()
        cache.learn(emoji("wide").staticUrl, width: 400, height: 100)
        clock.advance(by: CustomEmojiCache.saveDelay)

        #expect(cache.snapshot.emojis == nil)
        #expect(clock.sleeperCount == 0, "リストがないので、書き出しを予約しない")
        let reopened = makeCaches().cache(for: instance)
        await reopened.restoreTask?.value
        #expect(reopened.snapshot.emojis == nil)
    }

    /// 端末に残したリストで補完を始め、読み直す間もそのリストを出す。パレットには、画像から分かった縦横比を入れて渡す。
    @Test func completionStartsWithCachedEmojisAndReloads() async throws {
        let cache = makeCaches().cache(for: instance)
        cache.remember([emoji("wide")], loadStartedAt: cache.generation)
        cache.learn(emoji("wide").staticUrl, width: 400, height: 100)
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: CustomEmojiCache.saveDelay)
        try await waitUntil {
            (try? JSONDecoder().decode(StoredCustomEmojis.self, from: Data(contentsOf: file)))?.emojis.first?.aspectRatio == 4
        }
        let restored = makeCaches().cache(for: instance)
        try await waitUntil { restored.snapshot.emojis != nil }
        let loads = Mutex(0)
        let gate = Gate()
        let sources = ComposeCompletion.Sources(searchAccounts: { _, _ in [] }, searchHashtags: { _, _ in [] }, customEmojis: { [emoji = emoji("wide"), added = emoji("added")] in
            loads.withLock { $0 += 1 }
            try await gate.wait()
            return [emoji, added]
        }).remembering(customEmojisIn: restored)

        let completion = ComposeCompletion(sources: sources, settings: ComposeCompletion.Settings(debounce: .milliseconds(30), limit: 5))
        #expect(completion.emojisForPalette()?.map(\.aspectRatio) == [4])
        completion.loadEmojisIfNeeded()
        try await waitUntil { loads.withLock { $0 } == 1 }
        #expect(completion.emojis?.map(\.shortcode) == ["wide"], "読み直す間も、残したリストを出す")
        gate.open()
        try await waitUntil { completion.emojis?.count == 2 }
        #expect(completion.emojisForPalette()?.map(\.aspectRatio) == [4, nil])

        let next = ComposeCompletion(sources: sources, settings: ComposeCompletion.Settings(debounce: .milliseconds(30), limit: 5))
        next.loadEmojisIfNeeded()
        #expect(next.emojis?.count == 2, "この起動で読めたリストは、読み直さずに渡す")
        #expect(loads.withLock { $0 } == 1)
    }

    /// リストがまだないときに届いた画像の縦横比も、リストが届いたら、リストにある絵文字の分を残す。
    /// リストより先に投稿の本文で読んだ画像は、メモリに残っている間は読み直さず、大きさをもう一度知る機会がないため。
    @Test func adoptsAspectRatiosLearnedBeforeList() {
        let cache = makeCaches().cache(for: instance)
        cache.learn(emoji("wide").url, width: 400, height: 100)
        cache.learn(emoji("elsewhere").staticUrl, width: 500, height: 100)

        cache.remember([emoji("wide")], loadStartedAt: cache.generation)

        #expect(cache.snapshot.learnedAspectRatios == [emoji("wide").staticUrl: 4])
    }

    /// 消す前に読み始めたリストと、消す前に予約した書き出しで、消したあとにファイルを作り直さない。
    /// そのサーバーのアカウントを全部ログアウトしたあとに、リストが残らないようにするため。
    @Test func doesNotRecreateFileAfterRemoval() async throws {
        let caches = makeCaches()
        let cache = caches.cache(for: instance)
        let startedBeforeRemoval = cache.generation
        cache.remember([emoji("wide")], loadStartedAt: cache.generation)
        await caches.remove(instance: instance)
        cache.remember([emoji("wide")], loadStartedAt: startedBeforeRemoval)

        let reopened = makeCaches().cache(for: instance)
        await reopened.restoreTask?.value
        #expect(reopened.snapshot.emojis == nil)
        #expect(cache.snapshot.emojis == nil)
    }

    /// 設定のストレージで消したら、リストを持っている補完も、次にパレットを開いたときに読み直す。
    /// 持ったままにすると、消したリストを出し続け、縦横比も残らなくなるため。
    @Test func completionReloadsAfterCacheIsCleared() async throws {
        let caches = makeCaches()
        let cache = caches.cache(for: instance)
        let loads = Mutex(0)
        let sources = ComposeCompletion.Sources(searchAccounts: { _, _ in [] }, searchHashtags: { _, _ in [] }, customEmojis: { [emoji = emoji("wide")] in
            loads.withLock { $0 += 1 }
            return [emoji]
        }).remembering(customEmojisIn: cache)
        let completion = ComposeCompletion(sources: sources, settings: ComposeCompletion.Settings(debounce: .milliseconds(30), limit: 5))
        completion.loadEmojisIfNeeded()
        try await waitUntil { cache.snapshot.emojis != nil }

        await caches.removeAll()
        completion.loadEmojisIfNeeded()

        #expect(completion.emojis == nil, "消したリストは出さない")
        try await waitUntil { completion.emojis != nil && cache.snapshot.emojis != nil }
        #expect(loads.withLock { $0 } == 2)
    }
}

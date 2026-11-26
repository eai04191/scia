import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@Suite(.scratch)
struct EmojiPrefetchTests {
    private let root = TestScratch.url("EmojiPrefetchTests")

    private final class World: Sendable {
        let capacity = Mutex<Int?>(Int.max)
        let thumbnails = Mutex<Set<URL>>([])
        let fetched = Mutex<[URL]>([])
        /// この数を取得したら、プリフェッチを送れなくする。
        let allowedFetches = Mutex(Int.max)
        let imageSize = 1_024

        func fetch(_ url: URL) throws -> Data {
            try allowedFetches.withLock {
                guard $0 > 0 else { throw EmojiPrefetch.NotAllowed() }
                $0 -= 1
            }
            fetched.withLock { $0.append(url) }
            return Data(repeating: 2, count: imageSize)
        }
    }

    private func make(_ world: World) -> (EmojiPrefetch, EmojiImageFiles) {
        let files = EmojiImageFiles(directory: root.appending(path: "images"), sharingDirectory: root.appending(path: "sharing")) { world.capacity.withLock { $0 } }
        let prefetch = EmojiPrefetch(
            files: files,
            fetch: { try world.fetch($0) },
            hasThumbnail: { url in world.thumbnails.withLock { $0.contains(url) } },
            makeThumbnail: { url, _ in _ = world.thumbnails.withLock { $0.insert(url) } }
        )
        return (prefetch, files)
    }

    private func urls(_ count: Int) throws -> [URL] {
        try (0..<count).map { try #require(URL(string: "https://files.example.social/custom_emojis/\($0).png")) }
    }

    /// 空きが足りれば、どれも取得し、サムネイルを作り、元の画像をAとして持つ。
    @Test func fetchesAndKeepsOriginalsWithRoom() async throws {
        let world = World()
        let (prefetch, files) = make(world)
        let urls = try urls(3)
        await files.updateListed(Set(urls))

        let result = await prefetch.run(urls)

        #expect(result == EmojiPrefetch.Result(fetched: 3, keptOriginals: 3, failed: 0, stopped: false))
        #expect(world.thumbnails.withLock { $0 } == Set(urls))
        for url in urls {
            #expect(await files.containsListed(url))
        }
    }

    /// 同時に取得した画像を、届いた順によらず、取得したURLの画像として置き、サムネイルを作る。
    /// 先頭のURLが先に届き、ほかがあとから届く順にする。Release構成で、最後に届いた画像を先頭のURLのものとして置いていたため。
    @Test func keepsEachImageUnderItsOwnURL() async throws {
        let urls = try urls(4)
        let files = EmojiImageFiles(directory: root.appending(path: "images"), sharingDirectory: root.appending(path: "sharing")) { Int.max }
        await files.updateListed(Set(urls))
        let firstArrived = Gate()
        let thumbnails = Mutex<[URL: Data]>([:])
        let prefetch = EmojiPrefetch(
            files: files,
            fetch: { url in
                if url == urls[0] {
                    firstArrived.open()
                } else {
                    try await firstArrived.wait()
                }
                return Data(url.absoluteString.utf8)
            },
            hasThumbnail: { url in thumbnails.withLock { $0[url] != nil } },
            makeThumbnail: { url, data in thumbnails.withLock { $0[url] = data } }
        )

        let result = await prefetch.run(urls)

        #expect(result == EmojiPrefetch.Result(fetched: 4, keptOriginals: 4, failed: 0, stopped: false))
        for url in urls {
            let expected = Data(url.absoluteString.utf8)
            #expect(await files.data(for: url) == expected)
            #expect(thumbnails.withLock { $0[url] } == expected)
        }
    }

    /// 空きが足りなければ、サムネイルのない絵文字だけ取得して作り、元の画像は持たない。サムネイルのある絵文字は取得しない。
    @Test func fetchesOnlyForThumbnailsWithoutRoom() async throws {
        let world = World()
        world.capacity.withLock { $0 = 0 }
        let (prefetch, files) = make(world)
        let urls = try urls(4)
        world.thumbnails.withLock { $0 = [urls[0], urls[1]] }
        await files.updateListed(Set(urls))

        let result = await prefetch.run(urls)

        #expect(Set(world.fetched.withLock { $0 }) == [urls[2], urls[3]])
        #expect(result.keptOriginals == 0)
        #expect(world.thumbnails.withLock { $0 } == Set(urls))
        for url in urls {
            #expect(await files.data(for: url) == nil, "Bにも置かない")
        }
    }

    /// 元の画像がAにある絵文字は、取得しない。
    @Test func skipsListedOriginals() async throws {
        let world = World()
        let (prefetch, files) = make(world)
        let urls = try urls(2)
        await files.updateListed(Set(urls))
        _ = try await files.store(Data(repeating: 1, count: 8), named: "0.png", for: urls[0], generation: 0)

        _ = await prefetch.run(urls)

        #expect(world.fetched.withLock { $0 } == [urls[1]])
    }

    /// 前に読んだときは足りても、取得を始める前に再読み込みして足りなければ、元の画像は持たず、元の画像のためだけには取得しない。
    @Test func rereadsCapacityBeforeEachRun() async throws {
        let world = World()
        world.capacity.withLock { $0 = 100 * 1_024 }
        let (prefetch, files) = make(world)
        let urls = try urls(3)
        world.thumbnails.withLock { $0 = [urls[2]] }
        await files.updateListed(Set(urls))
        let first = await prefetch.run([urls[0]])
        #expect(first.keptOriginals == 1)

        world.capacity.withLock { $0 = 0 }
        let result = await prefetch.run(urls)

        #expect(result.keptOriginals == 0)
        #expect(Set(world.fetched.withLock { $0 }) == [urls[0], urls[1]], "小さい静止画のある3つ目は、元の画像のためだけには取得しない")
    }

    /// プリフェッチしない画像（前に読めなかった画像）は、失敗に数えずに飛ばし、残りは取得する。
    @Test func skipsWithoutCountingFailure() async throws {
        let world = World()
        let urls = try urls(3)
        let files = EmojiImageFiles(directory: root.appending(path: "images"), sharingDirectory: root.appending(path: "sharing")) { Int.max }
        let prefetch = EmojiPrefetch(
            files: files,
            fetch: { url in
                if url == urls[1] { throw EmojiPrefetch.Skipped() }
                return try world.fetch(url)
            },
            hasThumbnail: { url in world.thumbnails.withLock { $0.contains(url) } },
            makeThumbnail: { url, _ in _ = world.thumbnails.withLock { $0.insert(url) } }
        )
        await files.updateListed(Set(urls))

        let result = await prefetch.run(urls)

        #expect(result.fetched == 2)
        #expect(result.failed == 0)
        #expect(result.stopped == false)
    }

    /// プリフェッチを送れなくなったら（回線、低データモード、レート制限）、残りは取得せずに終える。
    @Test func stopsWhenPrefetchIsNotAllowed() async throws {
        let world = World()
        world.allowedFetches.withLock { $0 = 1 }
        let (prefetch, files) = make(world)
        let urls = try urls(EmojiPrefetch.concurrentFetches * 3)
        await files.updateListed(Set(urls))

        let result = await prefetch.run(urls)

        #expect(result.fetched == 1)
        #expect(result.stopped)
        #expect(world.thumbnails.withLock { $0 }.count == 1)
    }
}

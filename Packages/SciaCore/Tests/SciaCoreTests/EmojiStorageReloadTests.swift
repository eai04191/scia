import CoreGraphics
import Foundation
import Synchronization
import Testing
import SciaTesting
@testable import SciaCore

/// 読み直しの通信を送れないとき（低データモード）に、端末に置いた元の画像から、通信せずに描く高さで作り直す（docs/network.md）。
@MainActor
struct EmojiStorageReloadTests {
    private let url = URL(string: "https://example.com/emoji.png")!

    /// 端末と通信の状態を、テストの途中で変えられるようにしたもの。
    private final class World: Sendable {
        /// 端末に置いてある元の画像。nilなら置いていない。
        let stored = Mutex<Data?>(nil)
        let storedReads = Mutex(0)
        let writes = Mutex(0)
        let fetches = Mutex(0)
        let fetchedPurposes = Mutex<[RequestPurpose?]>([])
        /// 読み直しの通信を送れるか。nilなら送れない回線（低データモード）。
        let upgradePurpose = Mutex<RequestPurpose?>(nil)
    }

    private func makeStore(fetched data: Data, world: World) -> EmojiImageStore<CGImage> {
        EmojiImageStore(
            clock: TestClock(),
            retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) },
            maker: PlatformImageMaker(still: { $0 }, animated: { _, _ in nil }),
            upgradePurpose: { world.upgradePurpose.withLock { $0 } },
            storedData: { _ in
                world.storedReads.withLock { $0 += 1 }
                return world.stored.withLock { $0 }
            },
            storedWriteCount: { world.writes.withLock { $0 } }
        ) { _ in
            world.fetches.withLock { $0 += 1 }
            world.fetchedPurposes.withLock { $0.append(RequestPurpose.current) }
            return data
        }
    }

    /// 96ピクセルで読み終えたストア。
    private func loadedStore(_ data: Data, world: World) async throws -> EmojiImageStore<CGImage> {
        let store = makeStore(fetched: data, world: world)
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        return store
    }

    /// 端末になかったら覚え、描くたびに端末を読みに行かない。
    @Test func remembersMissWithoutRereading() async throws {
        let world = World()
        let store = try await loadedStore(try EmojiImageStoreTests.png(width: 400, height: 400), world: world)

        _ = store.image(for: url, pixelHeight: 200)
        try await waitUntil { world.storedReads.withLock { $0 } >= 1 }
        try await waitUntil { store.reloadingStillCount == 0 }
        _ = store.image(for: url, pixelHeight: 200)

        #expect(store.reloadingStillCount == 0)
        #expect(world.storedReads.withLock { $0 } == 1)
        #expect(store.image(for: url, pixelHeight: 200)?.height == 96)
    }

    /// なかったと覚えたあとに、先読みなど別の経路で端末に置かれたら、見直して作り直す。
    @Test func rechecksAfterAnotherPathStores() async throws {
        let world = World()
        let data = try EmojiImageStoreTests.png(width: 400, height: 400)
        let store = try await loadedStore(data, world: world)
        _ = store.image(for: url, pixelHeight: 200)
        try await waitUntil { world.storedReads.withLock { $0 } >= 1 }
        try await waitUntil { store.reloadingStillCount == 0 }

        world.stored.withLock { $0 = data }
        world.writes.withLock { $0 += 1 }
        _ = store.image(for: url, pixelHeight: 200)

        try await waitUntil { store.image(for: url, pixelHeight: 200)?.height == 200 }
        #expect(world.fetches.withLock { $0 } == 1)
    }

    /// 端末を見ている間に届いた操作の要求（`retriesNow`）は、読み込み中として見送らず、通信して読む。
    @Test func explicitRetryWhileCheckingStorageIsNotLost() async throws {
        let world = World()
        let store = try await loadedStore(try EmojiImageStoreTests.png(width: 400, height: 400), world: world)

        _ = store.image(for: url, pixelHeight: 200)
        _ = store.image(for: url, pixelHeight: 200, retriesNow: true)

        try await waitUntil { store.image(for: url, pixelHeight: 200)?.height == 200 }
        #expect(world.fetchedPurposes.withLock { $0 }.contains(.action))
    }

    /// 端末の画像が壊れていて読めなければ、何か置かれるまで読み直さない。描き直しのたびに読み続けないため。
    @Test func corruptStoredDataIsNotReadRepeatedly() async throws {
        let world = World()
        world.stored.withLock { $0 = Data("not an image".utf8) }
        let store = try await loadedStore(try EmojiImageStoreTests.png(width: 400, height: 400), world: world)

        _ = store.image(for: url, pixelHeight: 200)
        try await waitUntil { world.storedReads.withLock { $0 } >= 1 }
        try await waitUntil { store.reloadingStillCount == 0 }
        _ = store.image(for: url, pixelHeight: 200)

        #expect(world.storedReads.withLock { $0 } == 1)
        #expect(store.image(for: url, pixelHeight: 200)?.height == 96)
    }

    /// 動く絵文字も、端末に元の画像があれば、通信せずに描く高さで作り直す。
    @Test func reloadsAnimationFromStorage() async throws {
        let world = World()
        let gif = try EmojiImageStoreTests.gif(size: 256, frameCount: 2)
        let store = makeStore(fetched: gif, world: world)
        _ = store.animation(for: url)
        try await waitUntil { store.animation(for: url) != nil }
        #expect(store.animation(for: url)?.image.frameHeight == 96)
        world.stored.withLock { $0 = gif }

        _ = store.animation(for: url, pixelHeight: 200)

        try await waitUntil { store.animation(for: url, pixelHeight: 200)?.image.frameHeight == 200 }
        #expect(world.fetches.withLock { $0 } == 1)
    }
}

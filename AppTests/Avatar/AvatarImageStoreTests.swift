import Foundation
import ImageIO
import Synchronization
import SciaCore
import SciaTesting
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Scia

@MainActor
struct AvatarImageStoreTests {
    /// 1コマずつ`delays`秒表示するGIF。
    private func gif(delays: [Double]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, delays.count, nil))
        for (index, delay) in delays.enumerated() {
            let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                (index.isMultiple(of: 2) ? UIColor.red : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.cgImage)
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// UIImage.animatedImageはコマを均等に流すため、長いコマを繰り返して元の表示時間を保つ。
    @Test func animatedAvatarKeepsEachFrameDuration() async throws {
        let data = try gif(delays: [0.1, 0.3])
        let store = AvatarImageStore { _ in data }
        let url = try #require(URL(string: "https://example.social/avatar.gif"))

        let image = try await store.image(for: AvatarImageStore.Key(url: url, maxPixelSize: 8, animates: true))

        #expect(image.images?.count == 4)
        #expect(abs(image.duration - 0.4) < 0.001)
    }

    @Test func staticAvatarHasSingleFrame() async throws {
        let data = try gif(delays: [0.1, 0.3])
        let store = AvatarImageStore { _ in data }
        let url = try #require(URL(string: "https://example.social/avatar.gif"))

        let image = try await store.image(for: AvatarImageStore.Key(url: url, maxPixelSize: 8, animates: false))

        #expect(image.images == nil)
    }

    /// 読めなかったアイコンは、行に描いたときは間隔をおいてから読み直し、使う人がメニューを開いたときはすぐ読み直す。
    @Test func failedAvatarIsRetriedAfterTheDelayOrWhenTheUserAsks() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        let reads = Mutex(0)
        let clock = TestClock()
        let store = AvatarImageStore(clock: clock, retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _ in
            let read = reads.withLock { reads in
                defer { reads += 1 }
                return reads
            }
            if read < 2 { throw URLError(.timedOut) }
            return png
        }
        let key = AvatarImageStore.Key(url: try #require(URL(string: "https://example.social/avatar.png")), maxPixelSize: 8, animates: false)

        await #expect(throws: URLError.self) { try await store.image(for: key) }
        await #expect(throws: ImageLoadDeferred.self) { try await store.image(for: key) }
        #expect(store.requestImage(for: key) == nil)
        #expect(reads.withLock { $0 } == 1)

        clock.advance(by: .seconds(5))
        await #expect(throws: URLError.self) { try await store.image(for: key) }
        #expect(reads.withLock { $0 } == 2)

        _ = try await store.image(for: key, retriesNow: true)
        #expect(reads.withLock { $0 } == 3)
    }

    /// 読めなかったアイコンは、新着の挿入前に待つたびに読み直さない。読めないアイコンのために通信が増え、挿入が上限まで遅れるため。
    @Test func loadDoesNotRefetchKeysThatFailed() async throws {
        let fetchCount = Mutex(0)
        // 5秒の期限が来ないよう、進めない時計を渡す。
        let store = AvatarImageStore(clock: TestClock()) { _ in
            fetchCount.withLock { $0 += 1 }
            throw URLError(.fileDoesNotExist)
        }
        let url = try #require(URL(string: "https://example.social/missing.png"))
        let key = AvatarImageStore.Key(url: url, maxPixelSize: 8, animates: false)

        await store.load([key], within: .seconds(5))
        await store.load([key], within: .seconds(5))

        #expect(fetchCount.withLock { $0 } == 1)
    }

    /// 読み込みが終わらなくても、期限で戻る。戻ったあとも読み込みは続け、届いたらキャッシュに入れる。
    @Test func loadReturnsAtDeadlineAndKeepsLoading() async throws {
        let data = try gif(delays: [0.1])
        let arrival = Gate()
        let clock = TestClock()
        let store = AvatarImageStore(clock: clock) { _ in
            try await arrival.wait()
            return data
        }
        let url = try #require(URL(string: "https://example.social/slow.gif"))
        let key = AvatarImageStore.Key(url: url, maxPixelSize: 8, animates: false)

        let loading = Task { await store.load([key], within: .milliseconds(50)) }
        try await waitUntil { clock.sleeperCount == 1 && arrival.waiterCount == 1 }
        clock.advance(by: .milliseconds(50))
        await loading.value

        #expect(store.cachedImage(for: key) == nil)
        arrival.open()
        try await waitUntil { store.cachedImage(for: key) != nil }
    }

    /// 行に描いたときの読み込みは自動の通信として送り、止められている間は送らない。使う人がメニューを開いたときは、使う人の通信として送る。
    @Test func loadsAreSentWithTheirOrigin() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        let origins = Mutex<[RequestPurpose]>([])
        let store = AvatarImageStore { _ in
            origins.withLock { $0.append(RequestPurpose.current) }
            return png
        }
        let first = AvatarImageStore.Key(url: try #require(URL(string: "https://example.social/1.png")), maxPixelSize: 8, animates: false)
        let second = AvatarImageStore.Key(url: try #require(URL(string: "https://example.social/2.png")), maxPixelSize: 8, animates: false)

        _ = try await store.image(for: first)
        _ = try await store.image(for: second, retriesNow: true)

        #expect(origins.withLock { $0 } == [.display, .action])
    }
}

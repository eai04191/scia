import Foundation
import ImageIO
import Synchronization
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

    /// 読めなかったアイコンは、新着の挿入前に待つたびに読み直さない。読めないアイコンのために通信が増え、挿入が上限まで遅れるため。
    @Test func loadDoesNotRefetchKeysThatFailed() async throws {
        let fetchCount = Mutex(0)
        let store = AvatarImageStore { _ in
            fetchCount.withLock { $0 += 1 }
            throw URLError(.fileDoesNotExist)
        }
        let url = try #require(URL(string: "https://example.social/missing.png"))
        let key = AvatarImageStore.Key(url: url, maxPixelSize: 8, animates: false)

        await store.load([key], until: .now + .seconds(5))
        await store.load([key], until: .now + .seconds(5))

        #expect(fetchCount.withLock { $0 } == 1)
    }

    /// 読み込みが終わらなくても、期限で戻る。戻ったあとも読み込みは続け、届いたらキャッシュに入れる。
    @Test func loadReturnsAtDeadlineAndKeepsLoading() async throws {
        let data = try gif(delays: [0.1])
        let store = AvatarImageStore { _ in
            try await Task.sleep(for: .milliseconds(300))
            return data
        }
        let url = try #require(URL(string: "https://example.social/slow.gif"))
        let key = AvatarImageStore.Key(url: url, maxPixelSize: 8, animates: false)

        let start = ContinuousClock.now
        await store.load([key], until: start + .milliseconds(50))

        #expect(ContinuousClock.now - start < .milliseconds(250))
        #expect(store.cachedImage(for: key) == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.cachedImage(for: key) != nil)
    }
}

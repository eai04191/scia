import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

@MainActor
struct MediaImageStoreTests {
    private func pngData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try #require(image.pngData())
    }

    /// 共有や保存で縮めて展開した画像を渡さないよう、元のファイルをバイト列のまま残す。
    /// URLに拡張子がなかったり実際の形式と違ったりするため、拡張子は中身の形式に合わせる。
    @Test func keepsOriginalFileWithExtensionOfItsFormat() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let store = MediaImageStore(files: files) { _, _ in data }
        let url = try #require(URL(string: "https://files.example.social/original/abc.jpg"))

        #expect(await store.hasOriginal(for: url) == false)
        _ = try await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize, keepsOriginal: true)

        #expect(await store.hasOriginal(for: url))
        let file = try #require(await files.file(for: url))
        #expect(file.lastPathComponent == "abc.png")
        #expect(try Data(contentsOf: file) == data)
    }

    /// 一覧のサムネイルのように元のファイルが要らない読み込みでは、ファイルを残さない。
    @Test func doesNotKeepOriginalUnlessAsked() async throws {
        let data = try pngData()
        let store = MediaImageStore(files: .temporary()) { _, _ in data }
        let url = try #require(URL(string: "https://files.example.social/small/abc.png"))

        _ = try await store.image(for: url, maxPixelSize: 400)

        #expect(await store.hasOriginal(for: url) == false)
    }

    /// 展開した画像がメモリにあっても、元のファイルが整理で消えていたら読み込み直して置き直す。共有と保存が選べなくならないようにするため。
    @Test func refetchesWhenOriginalWasRemoved() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let store = MediaImageStore(files: files) { _, _ in data }
        let url = try #require(URL(string: "https://files.example.social/original/abc.png"))
        _ = try await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize, keepsOriginal: true)
        try FileManager.default.removeItem(at: files.directory)

        _ = try await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize, keepsOriginal: true)

        #expect(await store.hasOriginal(for: url))
    }

    /// ビューアで開く画像は、元のファイルがキャッシュにあれば通信せずにそこから表示する。起動し直したあとや、メモリから追い出されたあとに開き直すときのため。
    @Test func loadsOriginalFromCacheWithoutFetching() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://files.example.social/original/abc.png"))
        _ = try await files.store(data, named: "abc.png", for: url)
        let store = MediaImageStore(files: files) { _, _ in throw URLError(.notConnectedToInternet) }

        let image = try await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize, keepsOriginal: true)

        #expect(image.size == CGSize(width: 8, height: 8))
    }

    /// キャッシュのファイルが壊れていて展開できなければ、通信で取り直し、正しいファイルで置き直す。
    @Test func refetchesWhenCachedOriginalIsBroken() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://files.example.social/original/abc.png"))
        _ = try await files.store(Data("broken".utf8), named: "abc.png", for: url)
        let store = MediaImageStore(files: files) { _, _ in data }

        _ = try await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize, keepsOriginal: true)

        let file = try #require(await files.file(for: url))
        #expect(try Data(contentsOf: file) == data)
    }

    /// 一覧のサムネイルのように元のファイルを残さない読み込みは、キャッシュを見ずに通信する。キャッシュはビューアで開いた元の画像のためのもの。
    @Test func thumbnailsDoNotReadCache() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://files.example.social/original/abc.png"))
        _ = try await files.store(data, named: "abc.png", for: url)
        let fetched = Mutex(0)
        let store = MediaImageStore(files: files) { _, _ in
            fetched.withLock { $0 += 1 }
            return data
        }

        _ = try await store.image(for: url, maxPixelSize: 400)

        #expect(fetched.withLock { $0 } == 1)
    }

    /// 動画の先頭から最初のフレームを作れなければ、サーバーのプレビューを出し、その動画は先頭を読み直さない。
    @Test func videoFrameFallsBackToPreviewAndIsNotRetried() async throws {
        let png = try pngData()
        let rangeReads = Mutex(0)
        let store = MediaImageStore(files: .temporary()) { _, range in
            guard range != nil else { return png }
            rangeReads.withLock { $0 += 1 }
            return Data("not a video".utf8)
        }
        let video = try #require(URL(string: "https://files.example.social/original/abc.mp4"))
        let preview = try #require(URL(string: "https://files.example.social/small/abc.png"))
        let request = MediaThumbnailRequest(url: video, maxPixelSize: 1_024, source: .videoFrame(fallback: preview))

        let image = try await store.thumbnail(for: request)
        _ = try await store.thumbnail(for: request)

        #expect(image.size == CGSize(width: 8, height: 8))
        #expect(rangeReads.withLock { $0 } == 1)
        #expect(store.cachedThumbnail(for: request) != nil)
    }

    /// 通信の失敗では、プレビューを出しても、つながれば作れるため、間隔をおいてから作り直す。間隔の前に描いても、作り直さずにプレビューを出す。
    @Test func videoFrameIsRetriedAfterNetworkFailure() async throws {
        let png = try pngData()
        let rangeReads = Mutex(0)
        let clock = TestClock()
        let store = MediaImageStore(files: .temporary(), clock: clock, retryPolicy: { ImageRetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _, range in
            guard range != nil else { return png }
            rangeReads.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let video = try #require(URL(string: "https://files.example.social/original/abc.mp4"))
        let preview = try #require(URL(string: "https://files.example.social/small/abc.png"))
        let request = MediaThumbnailRequest(url: video, maxPixelSize: 1_024, source: .videoFrame(fallback: preview))

        _ = try await store.thumbnail(for: request)
        _ = try await store.thumbnail(for: request)
        #expect(rangeReads.withLock { $0 } == 1)

        clock.advance(by: .seconds(5))
        _ = try await store.thumbnail(for: request)
        #expect(rangeReads.withLock { $0 } == 2)
        #expect(store.cachedThumbnail(for: request) == nil)
    }
}

/// 読めなかった画像は、一覧に描いたときは間隔をおいてから読み直し、ビューアを開いたときはすぐ読み直す。
@MainActor
struct MediaImageStoreRetryTests {
    private let clock = TestClock()
    private let url = URL(filePath: "/").appending(path: "small.png")

    @Test func failedImageIsRetriedAfterTheDelayOrWhenTheUserOpensIt() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        let reads = Mutex(0)
        let store = MediaImageStore(files: .temporary(), clock: clock, retryPolicy: { ImageRetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _, _ in
            let read = reads.withLock { reads in
                defer { reads += 1 }
                return reads
            }
            if read < 2 { throw RemoteFetchError(statusCode: 503) }
            return png
        }

        await #expect(throws: RemoteFetchError.self) { try await store.image(for: url, maxPixelSize: 8) }
        await #expect(throws: ImageLoadDeferred.self) { try await store.image(for: url, maxPixelSize: 8) }
        #expect(reads.withLock { $0 } == 1)

        clock.advance(by: .seconds(5))
        await #expect(throws: RemoteFetchError.self) { try await store.image(for: url, maxPixelSize: 8) }
        #expect(reads.withLock { $0 } == 2)

        _ = try await store.image(for: url, maxPixelSize: 8, retriesNow: true)
        #expect(reads.withLock { $0 } == 3)
    }
}

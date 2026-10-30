import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

@Suite(.scratch)
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
        _ = try await store.image(for: url, maxPixelSize: MediaImagePixelSize.full, keepsOriginal: true)

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
        _ = try await store.image(for: url, maxPixelSize: MediaImagePixelSize.full, keepsOriginal: true)
        try FileManager.default.removeItem(at: files.directory)

        _ = try await store.image(for: url, maxPixelSize: MediaImagePixelSize.full, keepsOriginal: true)

        #expect(await store.hasOriginal(for: url))
    }

    /// ビューアで開く画像は、元のファイルがキャッシュにあれば通信せずにそこから表示する。起動し直したあとや、メモリから追い出されたあとに開き直すときのため。
    @Test func loadsOriginalFromCacheWithoutFetching() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://files.example.social/original/abc.png"))
        _ = try await files.store(data, named: "abc.png", for: url, generation: 0)
        let store = MediaImageStore(files: files) { _, _ in throw URLError(.notConnectedToInternet) }

        let image = try await store.image(for: url, maxPixelSize: MediaImagePixelSize.full, keepsOriginal: true)

        #expect(image.size == CGSize(width: 8, height: 8))
    }

    /// キャッシュのファイルが壊れていて展開できなければ、通信で取り直し、正しいファイルで置き直す。
    @Test func refetchesWhenCachedOriginalIsBroken() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://files.example.social/original/abc.png"))
        _ = try await files.store(Data("broken".utf8), named: "abc.png", for: url, generation: 0)
        let store = MediaImageStore(files: files) { _, _ in data }

        _ = try await store.image(for: url, maxPixelSize: MediaImagePixelSize.full, keepsOriginal: true)

        let file = try #require(await files.file(for: url))
        #expect(try Data(contentsOf: file) == data)
    }

    /// 一覧のサムネイルのように元のファイルを残さない読み込みは、キャッシュを見ずに通信する。キャッシュはビューアで開いた元の画像のためのもの。
    @Test func thumbnailsDoNotReadCache() async throws {
        let data = try pngData()
        let files = MediaFileCache.temporary()
        let url = try #require(URL(string: "https://files.example.social/original/abc.png"))
        _ = try await files.store(data, named: "abc.png", for: url, generation: 0)
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
        let store = MediaImageStore(files: .temporary(), clock: clock, retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _, range in
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

    /// サーバーが混んでいるときの429や5xxは、待てば作れるため、プレビューを出したうえで間隔をおいてから作り直す。起動中ずっとプレビューのままにしない。
    @Test(arguments: [429, 503])
    func videoFrameIsRetriedAfterTemporaryStatus(statusCode: Int) async throws {
        let png = try pngData()
        let rangeReads = Mutex(0)
        let clock = TestClock()
        let store = MediaImageStore(files: .temporary(), clock: clock, retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _, range in
            guard range != nil else { return png }
            rangeReads.withLock { $0 += 1 }
            throw HTTPStatusError(statusCode: statusCode)
        }
        let video = try #require(URL(string: "https://files.example.social/original/abc.mp4"))
        let preview = try #require(URL(string: "https://files.example.social/small/abc.png"))
        let request = MediaThumbnailRequest(url: video, maxPixelSize: 1_024, source: .videoFrame(fallback: preview))

        _ = try await store.thumbnail(for: request)
        #expect(rangeReads.withLock { $0 } == 1)

        clock.advance(by: .seconds(5))
        _ = try await store.thumbnail(for: request)
        #expect(rangeReads.withLock { $0 } == 2, "一時的な失敗のあとに作り直しませんでした")
    }

    /// 一覧に描くための読み込みは自動の通信として送り、止められている間は送らない。ビューアで開くときは、使う人の通信として送る。
    @Test func loadsAreSentWithTheirOrigin() async throws {
        let png = try pngData()
        let origins = Mutex<[RequestPurpose]>([])
        let store = MediaImageStore(files: .temporary()) { _, _ in
            origins.withLock { $0.append(RequestPurpose.current) }
            return png
        }

        _ = try await store.image(for: try #require(URL(string: "https://files.example.social/1.png")), maxPixelSize: 8)
        _ = try await store.image(for: try #require(URL(string: "https://files.example.social/2.png")), maxPixelSize: 8, keepsOriginal: true, retriesNow: true)

        #expect(origins.withLock { $0 } == [.display, .action])
    }

    /// 先読みは、展開せずに先読みの置き場へ置き、メディアのキャッシュには置かない。先読みの目的で送る。
    @Test func prefetchStoresOriginalInPrefetchCacheOnly() async throws {
        let png = try pngData()
        let files = MediaFileCache.temporary()
        let prefetched = MediaFileCache.temporary()
        let purposes = Mutex<[RequestPurpose]>([])
        let store = MediaImageStore(files: files, prefetchedFiles: prefetched) { _, _ in
            purposes.withLock { $0.append(RequestPurpose.current) }
            return png
        }
        let url = try #require(URL(string: "https://files.example.social/original/1.png"))

        await store.prefetchOriginal(url, purpose: .prefetch)

        #expect(await prefetched.contains(url))
        #expect(await files.contains(url) == false)
        #expect(store.cachedImage(for: url, maxPixelSize: MediaImagePixelSize.full) == nil)
        #expect(purposes.withLock { $0 } == [.prefetch])

        // 置いてあれば、読み直さない。
        await store.prefetchOriginal(url, purpose: .prefetch)
        #expect(purposes.withLock { $0 }.count == 1)
    }

    /// ビューアで開いたら、先読みしたファイルを通信せずに使い、メディアのキャッシュへ移す。
    @Test func viewerUsesPrefetchedOriginalAndMovesItToMediaCache() async throws {
        let png = try pngData()
        let files = MediaFileCache.temporary()
        let prefetched = MediaFileCache.temporary()
        let fetches = Mutex(0)
        let store = MediaImageStore(files: files, prefetchedFiles: prefetched) { _, _ in
            fetches.withLock { $0 += 1 }
            return png
        }
        let url = try #require(URL(string: "https://files.example.social/original/1.png"))
        await store.prefetchOriginal(url, purpose: .prefetch)

        _ = try await store.image(for: url, maxPixelSize: MediaImagePixelSize.full, keepsOriginal: true, retriesNow: true)

        #expect(fetches.withLock { $0 } == 1)
        #expect(await files.contains(url))
        #expect(await prefetched.contains(url) == false)
        #expect(await store.hasOriginal(for: url))
    }

    /// サムネイルに元の画像を読んだら、先読みの置き場にも置き、先読みで同じファイルを読み直さない。
    @Test func thumbnailOriginalIsSharedWithPrefetch() async throws {
        let png = try pngData()
        let prefetched = MediaFileCache.temporary()
        let fetches = Mutex(0)
        let store = MediaImageStore(files: .temporary(), prefetchedFiles: prefetched) { _, _ in
            fetches.withLock { $0 += 1 }
            return png
        }
        let url = try #require(URL(string: "https://files.example.social/original/1.png"))

        _ = try await store.image(for: url, maxPixelSize: 1_024, purpose: .enhancement(onExpensiveNetwork: true), sharesWithPrefetch: true)
        await store.prefetchOriginal(url, purpose: .prefetch)

        #expect(fetches.withLock { $0 } == 1)
        #expect(await prefetched.contains(url))
    }

    /// サムネイルとして読んでいる途中なら、先読みはそれを待ち、同じファイルを読まない。
    @Test func prefetchWaitsForThumbnailOriginalInFlight() async throws {
        let png = try pngData()
        let gate = Gate()
        let fetches = Mutex(0)
        let store = MediaImageStore(files: .temporary(), prefetchedFiles: .temporary()) { _, _ in
            fetches.withLock { $0 += 1 }
            try await gate.wait()
            return png
        }
        let url = try #require(URL(string: "https://files.example.social/original/1.png"))
        let thumbnail = Task { try await store.image(for: url, maxPixelSize: 1_024, purpose: .enhancement(onExpensiveNetwork: true), sharesWithPrefetch: true) }
        try await waitUntil { gate.waiterCount == 1 }

        let prefetch = Task { await store.prefetchOriginal(url, purpose: .prefetch) }
        gate.open()
        _ = try await thumbnail.value
        await prefetch.value

        #expect(fetches.withLock { $0 } == 1)
    }

    /// ぼかしている間に先読みしているサムネイルは、外したあとの表示の読み込みが待ち、同じ画像を読み直さない。
    @Test func revealJoinsCoveredPrefetchInFlight() async throws {
        let png = try pngData()
        let gate = Gate()
        let fetches = Mutex(0)
        let store = MediaImageStore(files: .temporary()) { _, _ in
            fetches.withLock { $0 += 1 }
            try await gate.wait()
            return png
        }
        let url = try #require(URL(string: "https://files.example.social/small/1.png"))
        let prefetch = MediaThumbnailRequest(url: url, maxPixelSize: 512).sent(as: .prefetch)
        let covered = Task { try await store.thumbnail(for: prefetch) }
        try await waitUntil { gate.waiterCount == 1 }

        let revealed = Task { try await store.thumbnail(for: MediaThumbnailRequest(url: url, maxPixelSize: 512)) }
        gate.open()
        _ = try await covered.value
        _ = try await revealed.value

        #expect(fetches.withLock { $0 } == 1)
        #expect(store.cachedThumbnail(for: MediaThumbnailRequest(url: url, maxPixelSize: 512)) != nil)
    }

    /// ぼかした動画の最初のコマを作れなかったら、代わりのプレビューも先読みとして読む。モバイル通信に変わってOSが断っても、表示の目的に戻して読まない。
    @Test func coveredVideoFallbackKeepsPrefetchPurpose() async throws {
        let png = try pngData()
        let purposes = Mutex<[RequestPurpose]>([])
        let store = MediaImageStore(files: .temporary()) { _, range in
            purposes.withLock { $0.append(RequestPurpose.current) }
            if range != nil {
                throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.expensive.rawValue])
            }
            return png
        }
        let video = try #require(URL(string: "https://files.example.social/original/1.mp4"))
        let preview = try #require(URL(string: "https://files.example.social/small/1.png"))
        let request = MediaThumbnailRequest(url: video, maxPixelSize: 1_024, source: .videoFrame(fallback: preview), isOriginal: true).sent(as: .prefetch)

        _ = try await store.thumbnail(for: request)

        #expect(purposes.withLock { $0 } == [.prefetch, .prefetch])
    }

    /// 外して表示しようとする呼び出しが複数あり、待っていた先読みをOSが断ったら、読み直すのは1回だけにする。
    @Test func refusedPrefetchIsReadAgainOnceForManyRevealers() async throws {
        let png = try pngData()
        let gate = Gate()
        let fetches = Mutex(0)
        let store = MediaImageStore(files: .temporary()) { _, _ in
            fetches.withLock { $0 += 1 }
            guard RequestPurpose.current == .prefetch else { return png }
            try await gate.wait()
            throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.expensive.rawValue])
        }
        let url = try #require(URL(string: "https://files.example.social/small/2.png"))
        let covered = Task { try await store.image(for: url, maxPixelSize: 512, purpose: .prefetch) }
        try await waitUntil { gate.waiterCount == 1 }
        var entered = 0
        let reveals = (0..<3).map { _ in
            Task { @MainActor in
                entered += 1
                return try await store.image(for: url, maxPixelSize: 512)
            }
        }
        try await waitUntil { entered == 3 }

        gate.open()
        _ = await covered.result
        for reveal in reveals {
            _ = try await reveal.value
        }

        #expect(fetches.withLock { $0 } == 2)
    }

    /// ぼかしている間の先読みでも、前に読めなかった画像は読まない。
    @Test func coveredPrefetchSkipsImagesThatFailed() async throws {
        let clock = TestClock()
        let fetches = Mutex(0)
        let store = MediaImageStore(files: .temporary(), clock: clock) { _, _ in
            fetches.withLock { $0 += 1 }
            throw HTTPStatusError(statusCode: 503)
        }
        let url = try #require(URL(string: "https://files.example.social/small/3.png"))
        let request = MediaThumbnailRequest(url: url, maxPixelSize: 512).sent(as: .prefetch)
        _ = try? await store.thumbnail(for: request)
        clock.advance(by: .seconds(600))

        await #expect(throws: ImageLoadDeferred.self) { try await store.thumbnail(for: request) }
        #expect(fetches.withLock { $0 } == 1)
    }

    /// 読めなかった画像は、読み直しの間隔が過ぎるまで先読みしない。
    @Test func prefetchSkipsImagesThatFailed() async throws {
        let fetches = Mutex(0)
        let prefetched = MediaFileCache.temporary()
        let store = MediaImageStore(files: .temporary(), prefetchedFiles: prefetched) { _, _ in
            fetches.withLock { $0 += 1 }
            throw HTTPStatusError(statusCode: 503)
        }
        let url = try #require(URL(string: "https://files.example.social/original/1.png"))

        await store.prefetchOriginal(url, purpose: .prefetch)
        await store.prefetchOriginal(url, purpose: .prefetch)

        #expect(fetches.withLock { $0 } == 1)
        #expect(await prefetched.contains(url) == false)
    }

    /// Wi-Fiで始めた元の画像の読み込みにモバイル通信でOSが断っても、同じURLをプレビューとして読む処理はその失敗を引き継がずに読む。
    @Test func displayLoadDoesNotJoinEnhancementRefusedOnNetwork() async throws {
        let png = try pngData()
        let enhancementStarted = Gate()
        let refuse = Gate()
        let store = MediaImageStore(files: .temporary()) { _, _ in
            guard RequestPurpose.current == .enhancement(onExpensiveNetwork: false) else { return png }
            enhancementStarted.open()
            try await refuse.wait()
            throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.expensive.rawValue])
        }
        let url = try #require(URL(string: "https://files.example.social/1.png"))

        let enhancement = Task { try await store.image(for: url, maxPixelSize: 8, purpose: .enhancement(onExpensiveNetwork: false)) }
        try await enhancementStarted.wait()
        let display = Task { try await store.image(for: url, maxPixelSize: 8) }
        refuse.open()

        await #expect(throws: URLError.self) { try await enhancement.value }
        _ = try await display.value
    }
}

/// 読めなかった画像は、一覧に描いたときは間隔をおいてから読み直し、ビューアを開いたときはすぐ読み直す。
@Suite(.scratch)
@MainActor
struct MediaImageStoreRetryTests {
    private let clock = TestClock()
    private let url = URL(filePath: "/").appending(path: "small.png")

    @Test func failedImageIsRetriedAfterTheDelayOrWhenTheUserOpensIt() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        let reads = Mutex(0)
        let store = MediaImageStore(files: .temporary(), clock: clock, retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _, _ in
            let read = reads.withLock { reads in
                defer { reads += 1 }
                return reads
            }
            if read < 2 { throw HTTPStatusError(statusCode: 503) }
            return png
        }

        await #expect(throws: HTTPStatusError.self) { try await store.image(for: url, maxPixelSize: 8) }
        await #expect(throws: ImageLoadDeferred.self) { try await store.image(for: url, maxPixelSize: 8) }
        #expect(reads.withLock { $0 } == 1)

        clock.advance(by: .seconds(5))
        await #expect(throws: HTTPStatusError.self) { try await store.image(for: url, maxPixelSize: 8) }
        #expect(reads.withLock { $0 } == 2)

        _ = try await store.image(for: url, maxPixelSize: 8, retriesNow: true)
        #expect(reads.withLock { $0 } == 3)
    }
}

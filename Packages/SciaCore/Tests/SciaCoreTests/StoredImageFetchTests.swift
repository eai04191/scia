import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@Suite(.scratch)
struct StoredImageFetchTests {
    private struct Failure: Error {}

    private final class Remote: Sendable {
        let requested = Mutex<[URL]>([])
        let fails = Mutex(false)

        func data(from url: URL) throws -> Data {
            requested.withLock { $0.append(url) }
            if fails.withLock({ $0 }) { throw Failure() }
            return Data("image \(url.lastPathComponent)".utf8)
        }

        var count: Int { requested.withLock { $0.count } }
    }

    private let root = TestScratch.url("StoredImageFetchTests")

    private func makeFiles() -> MediaFileCache {
        MediaFileCache(directory: root.appending(path: "files"), sharingDirectory: root.appending(path: "sharing"))
    }

    private func makeFetch(_ remote: Remote, files: MediaFileCache? = nil) -> StoredImageFetch {
        StoredImageFetch(files: files ?? makeFiles()) { try remote.data(from: $0) }
    }

    private func url(_ name: String) throws -> URL {
        try #require(URL(string: "https://files.example.social/custom_emojis/\(name)"))
    }

    /// 一度取得した画像は、端末に置いたファイルから読み、取得し直さない。起動し直しても同じ。
    @Test func readsStoredFileInsteadOfFetchingAgain() async throws {
        let remote = Remote()
        let first = try await makeFetch(remote).data(from: try url("a.png"))

        let second = try await makeFetch(remote).data(from: try url("a.png"))

        #expect(second == first)
        #expect(remote.count == 1)
    }

    /// 端末に置いたファイルから読んだときは、そう知らせる。取得したときは、通信の層が知らせるので、ここでは知らせない。
    @Test func reportsFileAsSourceOnlyWhenReadFromStoredFile() async throws {
        let fetch = makeFetch(Remote())
        let reported = Mutex<[ResponseSource]>([])
        try await ResponseSource.$report.withValue({ source in reported.withLock { $0.append(source) } }) {
            _ = try await fetch.data(from: try url("a.png"))
            #expect(reported.withLock { $0 }.isEmpty)
            _ = try await fetch.data(from: try url("a.png"))
        }

        #expect(reported.withLock { $0 } == [.file])
    }

    /// URLごとに置く。別のURLは取得する。
    @Test func fetchesEachURLOnce() async throws {
        let remote = Remote()
        let fetch = makeFetch(remote)

        let a = try await fetch.data(from: try url("a.png"))
        let b = try await fetch.data(from: try url("b.png"))
        _ = try await fetch.data(from: try url("b.png"))

        #expect(a != b)
        #expect(remote.count == 2)
    }

    /// 取得できなかったときは、何も置かずに失敗を返し、次は取得し直す。
    @Test func storesNothingWhenFetchFails() async throws {
        let remote = Remote()
        let fetch = makeFetch(remote)
        remote.fails.withLock { $0 = true }
        await #expect(throws: Failure.self) { try await fetch.data(from: try url("a.png")) }

        remote.fails.withLock { $0 = false }
        _ = try await fetch.data(from: try url("a.png"))

        #expect(remote.count == 2)
    }

    /// 画像として読めなかったファイルは消し、次は取得し直す。残すと、読めないファイルを読み続ける。
    @Test func fetchesAgainAfterDiscarding() async throws {
        let remote = Remote()
        let fetch = makeFetch(remote)
        _ = try await fetch.data(from: try url("a.png"))

        await fetch.discard(try url("a.png"))
        _ = try await fetch.data(from: try url("a.png"))

        #expect(remote.count == 2)
    }

    /// 取得している間に、使う人が置いたファイルを全部消したら、取得した画像は返すが置かない。消したあとに置き直さないため。
    @Test func doesNotStoreAfterFilesWereRemovedDuringFetch() async throws {
        let files = makeFiles()
        let remote = Remote()
        let fetch = StoredImageFetch(files: files) { url in
            try await files.removeCachedFiles()
            return try remote.data(from: url)
        }

        _ = try await fetch.data(from: try url("a.png"))

        #expect(await files.contains(try url("a.png")) == false)
    }
}

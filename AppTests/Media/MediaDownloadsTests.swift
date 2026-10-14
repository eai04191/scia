import Foundation
import Synchronization
import Testing
@testable import Scia

@MainActor
struct MediaDownloadsTests {
    private func makeDirectory() -> URL {
        .temporaryDirectory.appending(path: "MediaDownloadsTests-\(UUID().uuidString)")
    }

    /// 落としたファイルは起動している間残し、同じ添付ファイルをまた共有するときは落とし直さない。
    @Test func reusesDownloadedFile() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = Mutex(0)
        let downloads = MediaDownloads(directory: directory) { url, folder, onProgress in
            count.withLock { $0 += 1 }
            onProgress(1)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try Data("movie".utf8).write(to: file)
            return file
        }
        let url = try #require(URL(string: "https://files.example.social/original/a.mp4"))

        #expect(downloads.cachedFile(for: url) == nil)
        let first = try await downloads.file(for: url) { _ in }
        let second = try await downloads.file(for: url) { _ in }

        #expect(first == second)
        #expect(downloads.cachedFile(for: url) == first)
        #expect(count.withLock { $0 } == 1)
        #expect(first.path.hasPrefix(directory.path))
    }

    /// 落とせなかったものは残さず、次に求められたら落とし直す。
    @Test func doesNotKeepFailedDownload() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = MediaDownloads(directory: directory) { _, _, _ in throw URLError(.notConnectedToInternet) }
        let url = try #require(URL(string: "https://files.example.social/original/a.mp4"))

        await #expect(throws: URLError.self) { try await downloads.file(for: url) { _ in } }
        #expect(downloads.cachedFile(for: url) == nil)
    }

    /// 共有先でファイル名として見えるため、URLの名前を残す。拡張子がなければ応答の形式から付ける。
    @Test(arguments: [
        ("https://x.example/media/a.mp4", "video/mp4", "a.mp4"),
        ("https://x.example/media/abc", "video/mp4", "abc.mp4"),
        ("https://x.example/media/abc", nil, "abc"),
        ("https://x.example/", "audio/mpeg", "media.mp3"),
    ])
    func fileNameKeepsURLNameAndAddsExtension(url: String, mimeType: String?, expected: String) throws {
        #expect(MediaDownloads.fileName(for: try #require(URL(string: url)), mimeType: mimeType) == expected)
    }

    /// サーバーがエラーを返したら、その本文を添付ファイルとして残さず、失敗にする。残すと共有で壊れたファイルを渡し、
    /// サーバーが直っても落とし直せない。
    @Test func failsOnHTTPErrorWithoutKeepingBody() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocol.registerClass(NotFoundProtocol.self)
        defer { URLProtocol.unregisterClass(NotFoundProtocol.self) }
        let downloads = MediaDownloads(directory: directory)
        let url = try #require(URL(string: "https://\(NotFoundProtocol.host)/media/a.mp4"))

        await #expect(throws: URLError.self) { try await downloads.file(for: url) { _ in } }
        #expect(downloads.cachedFile(for: url) == nil)
    }

    /// 端末のファイルのURLも落とせる。ダミー投稿の動画はファイルのURLで渡しているため。
    @Test func downloadsFileURLWithURLSession() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source/a.mp4")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: source)
        let downloads = MediaDownloads(directory: directory.appending(path: "downloads"))

        let file = try await downloads.file(for: source) { _ in }

        #expect(file.lastPathComponent == "a.mp4")
        #expect(try Data(contentsOf: file) == Data("movie".utf8))
    }
}

/// 決まったホストへの通信に、404を返す。
private final class NotFoundProtocol: URLProtocol {
    static let host = "media-downloads-tests.invalid"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>Not Found</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

import Foundation
import Synchronization
import Testing
import UIKit
@testable import Scia

@MainActor
struct MediaDownloadsTests {
    private func makeStaging() -> URL {
        .temporaryDirectory.appending(path: "MediaDownloadsTests-\(UUID().uuidString)")
    }

    /// 落としたファイルはキャッシュに置き、同じ添付ファイルをまた共有するときは落とし直さない。渡すのは毎回キャッシュの写し。
    @Test func reusesCachedFileAndReturnsCopies() async throws {
        let files = MediaFileCache.temporary()
        let count = Mutex(0)
        let downloads = MediaDownloads(files: files, stagingDirectory: makeStaging()) { url, folder, onProgress in
            count.withLock { $0 += 1 }
            onProgress(1)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try Data("movie".utf8).write(to: file)
            return file
        }
        let url = try #require(URL(string: "https://files.example.social/original/a.mp4"))

        let first = try await downloads.fileForSharing(for: url) { _ in }
        let second = try await downloads.fileForSharing(for: url) { _ in }

        #expect(first != second)
        #expect(first.lastPathComponent == "a.mp4")
        #expect(try Data(contentsOf: second) == Data("movie".utf8))
        #expect(first.path.hasPrefix(files.sharingDirectory.path))
        #expect(count.withLock { $0 } == 1)
        #expect(await files.contains(url))
    }

    /// キャッシュにあれば落とさないため、進み具合を出さない。落とすときは、始めた時点で0を伝える。
    @Test func reportsProgressOnlyWhenDownloading() async throws {
        let files = MediaFileCache.temporary()
        let downloads = MediaDownloads(files: files, stagingDirectory: makeStaging()) { url, folder, _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try Data("movie".utf8).write(to: file)
            return file
        }
        let url = try #require(URL(string: "https://files.example.social/original/a.mp4"))
        var reported: [Double] = []

        _ = try await downloads.fileForSharing(for: url) { reported.append($0) }
        #expect(reported == [0])
        _ = try await downloads.fileForSharing(for: url) { reported.append($0) }
        #expect(reported == [0])
    }

    /// 整理で消えた画像を落とし直したときも、拡張子は中身の形式に合わせる。URLの拡張子と中身が違うと、写真に保存できなくなるため。
    @Test func namesImageByItsFormat() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        let downloads = MediaDownloads(files: .temporary(), stagingDirectory: makeStaging()) { url, folder, _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: url.lastPathComponent)
            try png.write(to: file)
            return file
        }
        let url = try #require(URL(string: "https://files.example.social/original/abc.jpg"))

        let file = try await downloads.fileForSharing(for: url) { _ in }

        #expect(file.lastPathComponent == "abc.png")
    }

    /// 落とせなかったものは置かず、次に求められたら落とし直す。
    @Test func doesNotKeepFailedDownload() async throws {
        let files = MediaFileCache.temporary()
        let downloads = MediaDownloads(files: files, stagingDirectory: makeStaging()) { _, _, _ in throw URLError(.notConnectedToInternet) }
        let url = try #require(URL(string: "https://files.example.social/original/a.mp4"))

        await #expect(throws: URLError.self) { try await downloads.fileForSharing(for: url) { _ in } }
        #expect(await files.contains(url) == false)
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
        URLProtocol.registerClass(NotFoundProtocol.self)
        defer { URLProtocol.unregisterClass(NotFoundProtocol.self) }
        let files = MediaFileCache.temporary()
        let downloads = MediaDownloads(files: files, stagingDirectory: makeStaging())
        let url = try #require(URL(string: "https://\(NotFoundProtocol.host)/media/a.mp4"))

        await #expect(throws: URLError.self) { try await downloads.fileForSharing(for: url) { _ in } }
        #expect(await files.contains(url) == false)
    }

    /// 端末のファイルのURLも落とせる。ダミー投稿の動画はファイルのURLで渡しているため。
    @Test func downloadsFileURLWithURLSession() async throws {
        let directory = makeStaging()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source/a.mp4")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: source)
        let downloads = MediaDownloads(files: .temporary(), stagingDirectory: directory.appending(path: "staging"))

        let file = try await downloads.fileForSharing(for: source) { _ in }

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

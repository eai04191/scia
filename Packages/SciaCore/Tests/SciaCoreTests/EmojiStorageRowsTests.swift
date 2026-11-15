import Foundation
import Testing
@testable import SciaCore

/// 設定のストレージの「絵文字」の中の行。行はURLで決め、重なる画像は両方の行に数える。
struct EmojiStorageRowsTests {
    private func url(_ host: String, _ name: String) throws -> URL {
        try #require(URL(string: "https://\(host)/custom_emojis/\(name).png"))
    }

    private func emoji(_ host: String, _ name: String) throws -> ServerEmoji {
        ServerEmoji(shortcode: name, url: try url(host, name), staticUrl: try url(host, "\(name)_static"), visibleInPicker: true, category: nil)
    }

    private func name(_ url: URL) -> String {
        MediaFileCache.folderName(for: url)
    }

    /// サーバーの行には、そのサーバーの応答に載っている画像を、AとBのどちらに置いたものも数え、小さい静止画、応答のファイル、記録も足す。
    /// 応答に載っていないBの画像は、「ほかのサーバーの絵文字」の行に数える。
    @Test func countsByURL() throws {
        let own = try emoji("own.example", "blob")
        let otherURL = try url("other.example", "cat")
        let sources = EmojiStorageSources(
            lists: [StoredEmojiList(server: "own.example", emojis: [own], fileBytes: 4_000)],
            listedSizes: [name(own.url): 20_000],
            othersSizes: [name(own.staticUrl): 8_000, name(otherURL): 16_000],
            thumbnailSizes: [own.url: 1_000],
            oversizedURLs: [own.url],
            oversizedBytes: 500,
            unicodeBytes: 3_000
        )

        #expect(EmojiStorageRow.rows(sources) == [
            EmojiStorageRow(kind: .server("own.example"), bytes: 4_000 + 20_000 + 8_000 + 1_000 + 500),
            EmojiStorageRow(kind: .unicode, bytes: 3_000),
            EmojiStorageRow(kind: .otherServers, bytes: 16_000),
        ])
    }

    /// 2つのサーバーの応答に同じURLが載っていれば、どちらの行にも数える。
    @Test func countsSharedImageInBothServers() throws {
        let shared = try emoji("cdn.example", "shared")
        let sources = EmojiStorageSources(
            lists: [
                StoredEmojiList(server: "a.example", emojis: [shared], fileBytes: 0),
                StoredEmojiList(server: "b.example", emojis: [shared], fileBytes: 0),
            ],
            listedSizes: [name(shared.url): 10_000],
            othersSizes: [:],
            thumbnailSizes: [:],
            oversizedURLs: [],
            oversizedBytes: 0,
            unicodeBytes: 0
        )

        let rows = EmojiStorageRow.rows(sources)

        #expect(rows.first { $0.kind == .server("a.example") }?.bytes == 10_000)
        #expect(rows.first { $0.kind == .server("b.example") }?.bytes == 10_000)
        #expect(rows.first { $0.kind == .otherServers }?.bytes == 0)
    }
}

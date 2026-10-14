import Foundation
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
        let directory = URL.temporaryDirectory.appending(path: "MediaImageStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaImageStore(originalsDirectory: directory) { _ in data }
        let url = try #require(URL(string: "https://files.example.social/original/abc.jpg"))

        #expect(store.originalFile(for: url) == nil)
        _ = try await store.image(for: url, maxPixelSize: MediaImageStore.fullPixelSize, keepsOriginal: true)

        let file = try #require(store.originalFile(for: url))
        #expect(file.lastPathComponent == "abc.png")
        #expect(try Data(contentsOf: file) == data)
    }

    /// 一覧のサムネイルのように元のファイルが要らない読み込みでは、ファイルを残さない。
    @Test func doesNotKeepOriginalUnlessAsked() async throws {
        let data = try pngData()
        let directory = URL.temporaryDirectory.appending(path: "MediaImageStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaImageStore(originalsDirectory: directory) { _ in data }
        let url = try #require(URL(string: "https://files.example.social/small/abc.png"))

        _ = try await store.image(for: url, maxPixelSize: 400)

        #expect(store.originalFile(for: url) == nil)
    }
}

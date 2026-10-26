import Foundation
import SciaCore
import Testing
import SciaTesting
import UIKit
import UniformTypeIdentifiers
@testable import Scia

/// ペーストしたファイルのURLの項目を、指す先のファイルで添付に回すか。
@Suite(.scratch)
@MainActor
struct LocalMediaPasteTests {
    /// MacのFinderでコピーしたファイルと同じく、ファイルのURL、ファイル名の文字、アイコンの画像を持つ項目を作る。
    private func finderItem(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(url as NSURL, visibility: .all)
        provider.registerObject(url.lastPathComponent as NSString, visibility: .all)
        provider.registerDataRepresentation(for: UTType("com.apple.icns") ?? .image, visibility: .all) { completion in
            completion(Data([0]), nil)
            return nil
        }
        return provider
    }

    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let folder = TestScratch.url("LocalMediaPasteTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try contents.write(to: url)
        return url
    }

    @Test func 画像のファイルのURLは文字やアイコンより優先して指す先のファイルを添付する() async throws {
        let contents = Data("png".utf8)
        let source = try temporaryFile(named: "screenshot.png", contents: contents)
        let provider = finderItem(for: source)

        #expect(LocalMediaLoader.hasFileURL(provider))
        let pasted = try #require(await LocalMediaLoader.startLoadingPastedFile(from: provider))
        let file = try await pasted.load()
        defer { file.remove() }

        #expect(pasted.kind == .image)
        #expect(file.kind == .image)
        #expect(file.mimeType == "image/png")
        #expect(file.url.lastPathComponent == "screenshot.png")
        #expect(file.url != source)
        #expect(try Data(contentsOf: file.url) == contents)
    }

    @Test func 動画のファイルのURLは動画として添付する() async throws {
        let source = try temporaryFile(named: "clip.mov", contents: Data("mov".utf8))
        let pasted = try #require(await LocalMediaLoader.startLoadingPastedFile(from: finderItem(for: source)))
        let file = try await pasted.load()
        defer { file.remove() }

        #expect(pasted.kind == .video)
        #expect(file.mimeType == "video/quicktime")
    }

    @Test func 画像でも動画でもないファイルのURLは添付しない() async throws {
        let source = try temporaryFile(named: "notes.txt", contents: Data("text".utf8))
        #expect(await LocalMediaLoader.startLoadingPastedFile(from: finderItem(for: source)) == nil)
    }

    @Test func ファイルのURLを持たない項目は今までどおり型で振り分ける() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .png, visibility: .all) { completion in
            completion(Data([0]), nil)
            return nil
        }
        #expect(!LocalMediaLoader.hasFileURL(provider))
        #expect(LocalMediaLoader.pastedMediaType(in: provider) == .png)
    }
}

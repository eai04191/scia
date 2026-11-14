import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 投稿欄に渡すメディアのファイルを消すときに、使う人のファイルを巻き込まないこと。
@Suite(.scratch)
struct LocalMediaFileTests {
    private let root = TestScratch.url("LocalMediaFileTests")

    /// コピーして作ったファイルは、消してもコピーだけが消える。元のファイルと、同じフォルダーのほかのファイルは残る。
    @Test func removingCopyKeepsSourceAndItsFolder() throws {
        let userFolder = root.appending(path: "user")
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let source = userFolder.appending(path: "photo.png")
        let neighbour = userFolder.appending(path: "notes.txt")
        try Data([1]).write(to: source)
        try Data([2]).write(to: neighbour)
        let staging = root.appending(path: "staging")

        let file = try LocalMediaFile(copying: source, in: staging, mimeType: "image/png", kind: .image)
        #expect(file.url.lastPathComponent == "photo.png")
        #expect(file.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL)
        file.remove()

        #expect(!FileManager.default.fileExists(atPath: file.url.path()))
        #expect(FileManager.default.fileExists(atPath: source.path()))
        #expect(FileManager.default.fileExists(atPath: neighbour.path()))
    }

    /// 同じ名前のファイルを続けてコピーしても、フォルダーを分けるので、片方を消してももう片方は残る。
    @Test func copiesOfSameNameDoNotShareFolder() throws {
        let source = root.appending(path: "photo.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: source)
        let staging = root.appending(path: "staging")

        let first = try LocalMediaFile(copying: source, in: staging, mimeType: "image/png", kind: .image)
        let second = try LocalMediaFile(copying: source, in: staging, mimeType: "image/png", kind: .image)
        first.remove()

        #expect(FileManager.default.fileExists(atPath: second.url.path()))
    }
}

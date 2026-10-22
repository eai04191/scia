import Foundation
import SciaCore
import Testing

struct SharedMediaInboxTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "SharedMediaInboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeFile(named name: String, contents: String) throws -> URL {
        let folder = root.appending(path: "source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func returnsFilesInReceivedOrderWithOriginalNames() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedMediaInbox(root: root.appending(path: "inbox"))
        let id = UUID()
        // 番号が10を超えても、文字の順ではなく受け取った順に並ぶ。
        for index in 0..<12 {
            try inbox.store(try makeFile(named: "IMG_\(index).HEIC", contents: "\(index)"), id: id, index: index)
        }
        let files = try inbox.files(id: id)
        #expect(files.map(\.lastPathComponent) == (0..<12).map { "IMG_\($0).HEIC" })
        #expect(try files.map { try String(contentsOf: $0, encoding: .utf8) } == (0..<12).map(String.init))
    }

    @Test func keepsFilesWithTheSameName() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedMediaInbox(root: root.appending(path: "inbox"))
        let id = UUID()
        try inbox.store(try makeFile(named: "image.jpeg", contents: "a"), id: id, index: 0)
        try inbox.store(try makeFile(named: "image.jpeg", contents: "b"), id: id, index: 1)
        #expect(try inbox.files(id: id).map { try String(contentsOf: $0, encoding: .utf8) } == ["a", "b"])
    }

    @Test func removesOnlyTheGivenShare() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedMediaInbox(root: root.appending(path: "inbox"))
        let removed = UUID()
        let kept = UUID()
        try inbox.store(try makeFile(named: "a.png", contents: "a"), id: removed, index: 0)
        try inbox.store(try makeFile(named: "b.png", contents: "b"), id: kept, index: 0)
        inbox.remove(id: removed)
        #expect(throws: (any Error).self) { try inbox.files(id: removed) }
        #expect(try inbox.files(id: kept).map(\.lastPathComponent) == ["b.png"])
    }
}

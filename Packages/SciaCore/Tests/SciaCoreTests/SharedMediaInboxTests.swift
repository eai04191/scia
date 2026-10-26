import Foundation
import SciaCore
import Testing
import SciaTesting

@Suite(.scratch)
struct SharedMediaInboxTests {
    private let root = TestScratch.url("SharedMediaInboxTests")

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

    /// 受け取る前にアプリへ渡せなかった共有（拡張が途中で終わった、アプリが開かれなかったなど）は、古くなったら消す。消さないと、App Groupのコンテナに残り続ける。
    @Test func removesStaleSharesOnly() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedMediaInbox(root: root.appending(path: "inbox"))
        let stale = UUID()
        let recent = UUID()
        try inbox.store(try makeFile(named: "a.png", contents: "a"), id: stale, index: 0)
        try inbox.store(try makeFile(named: "b.png", contents: "b"), id: recent, index: 0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try setModificationDate(now.addingTimeInterval(-2 * 24 * 60 * 60), of: inbox.root.appending(path: stale.uuidString))
        try setModificationDate(now.addingTimeInterval(-60), of: inbox.root.appending(path: recent.uuidString))

        inbox.removeStale(now: now)

        #expect(throws: (any Error).self) { try inbox.files(id: stale) }
        #expect(try inbox.files(id: recent).map(\.lastPathComponent) == ["b.png"])
    }

    /// 受け渡しの途中のファイルは、端末のバックアップに入れない。
    @Test func excludesInboxFromBackup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedMediaInbox(root: root.appending(path: "inbox"))
        try inbox.store(try makeFile(named: "a.png", contents: "a"), id: UUID(), index: 0)
        #expect(try inbox.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        var values = URLResourceValues()
        values.contentModificationDate = date
        var url = url
        try url.setResourceValues(values)
    }
}

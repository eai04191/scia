import Foundation
import SciaTesting
import Testing
@testable import Scia

@Suite(.scratch)
struct MediaFileCacheTests {
    private struct Directories {
        let root = TestScratch.url("MediaFileCacheTests")
        var cache: URL { root.appending(path: "cache") }
        var sharing: URL { root.appending(path: "sharing") }

        /// - Parameter clock: 最後に使った日時を決める時計。使った順を決めるテストは、使うたびに進める。
        func makeCache(sizeLimit: Int = 1_024 * 1_024, clock: TestClock = TestClock()) -> MediaFileCache {
            MediaFileCache(directory: cache, sharingDirectory: sharing, sizeLimit: sizeLimit) { clock.date }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func url(_ name: String) throws -> URL {
        try #require(URL(string: "https://files.example.social/original/\(name)"))
    }

    /// 起動をまたいで残す。作り直したキャッシュからも、置いたファイルを同じ名前のまま引ける。
    @Test func keepsFilesAcrossInstances() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let data = Data("movie".utf8)
        _ = try await directories.makeCache().store(data, named: "a.mp4", for: try url("a"), generation: 0)

        let file = try #require(await directories.makeCache().file(for: try url("a")))

        #expect(file.lastPathComponent == "a.mp4")
        #expect(try Data(contentsOf: file) == data)
        #expect(await directories.makeCache().file(for: try url("b")) == nil)
    }

    /// ログアウトで、置いたファイルと共有用のコピーを全部消す。消したあとも、続けて置ける。
    @Test func removesAllFilesAndSharingCopies() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let cache = directories.makeCache()
        _ = try await cache.store(Data("photo".utf8), named: "a.jpg", for: try url("a"), generation: 0)
        let copy = try #require(try await cache.copyForSharing(for: try url("a")))

        await cache.removeAll()

        #expect(await cache.file(for: try url("a")) == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path()))
        _ = try await cache.store(Data("next".utf8), named: "b.jpg", for: try url("b"), generation: await cache.generation)
        #expect(await cache.file(for: try url("b")) != nil)
    }

    /// 名前はURLやサーバーの応答から作るため、区切りや`..`が入っていても、URLごとのフォルダーの外には置かない。
    @Test func keepsFileInsideItsFolderWhateverTheName() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let cache = directories.makeCache()

        for (index, name) in ["../../escaped.mp4", "..", ".", "", ".partial-x"].enumerated() {
            let file = try await cache.store(Data("movie".utf8), named: name, for: try url("a\(index)"), generation: await cache.generation)

            #expect(file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == directories.cache.standardizedFileURL, "\(name)を\(file.path)に置きました")
            #expect(!file.lastPathComponent.hasPrefix("."))
            #expect(await cache.file(for: try url("a\(index)")) == file)
        }
        #expect(!FileManager.default.fileExists(atPath: directories.root.appending(path: "escaped.mp4").path))
    }

    /// ダウンロードした一時ファイルは、メモリに読み込まずに移して置く。
    @Test func storesByMovingFile() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let source = directories.root.appending(path: "download.tmp")
        try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: source)

        let file = try await directories.makeCache().store(movingFile: source, named: "a.mp4", for: try url("a"), generation: 0)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: file) == Data("movie".utf8))
    }

    /// 合計が上限を超えたら、最後に使ったのが古いものから、上限の7割まで消す。最近引いたものは残る。
    @Test func trimsLeastRecentlyUsedFiles() async throws {
        let directories = Directories()
        defer { directories.remove() }
        // 割り当ての単位（4KB）で大きさが丸められないよう、十分に大きいファイルで測る。
        let size = 100 * 1_024
        let clock = TestClock()
        let cache = directories.makeCache(sizeLimit: size * 3 + size / 2, clock: clock)
        for name in ["a", "b", "c"] {
            _ = try await cache.store(Data(count: size), named: name, for: try url(name), generation: 0)
            clock.advance(by: .seconds(1))
        }
        // aを引いて、bをいちばん古くする。
        _ = await cache.file(for: try url("a"))
        clock.advance(by: .seconds(1))

        _ = try await cache.store(Data(count: size), named: "d", for: try url("d"), generation: 0)

        #expect(await cache.contains(try url("b")) == false)
        #expect(await cache.contains(try url("c")) == false)
        #expect(await cache.contains(try url("a")))
        #expect(await cache.contains(try url("d")))
    }

    /// 上限より大きなファイルでも、置いた直後に消さない。共有や保存に渡す前に消えないようにするため。
    @Test func keepsMostRecentFileEvenIfOverLimit() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let cache = directories.makeCache(sizeLimit: 1_024)

        _ = try await cache.store(Data(count: 100 * 1_024), named: "big.mp4", for: try url("big"), generation: 0)

        #expect(await cache.contains(try url("big")))
    }

    /// 共有や保存にはコピーを渡す。元のファイルが整理で消えても、コピーは読める。
    @Test func sharingCopySurvivesRemovalOfCachedFile() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let cache = directories.makeCache()
        let data = Data("photo".utf8)
        _ = try await cache.store(data, named: "a.png", for: try url("a"), generation: 0)

        let copy = try #require(try await cache.copyForSharing(for: try url("a")))
        try FileManager.default.removeItem(at: directories.cache)

        #expect(copy.lastPathComponent == "a.png")
        #expect(copy.path.hasPrefix(directories.sharing.path))
        #expect(try Data(contentsOf: copy) == data)
    }

    /// 共有先が読み終えたことは知れないため、コピーは次に作るとき（起動時）にまとめて消す。キャッシュのファイルは残す。
    @Test func clearsSharingCopiesOnInit() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let file = try await directories.makeCache().store(Data("photo".utf8), named: "a.png", for: try url("a"), generation: 0)
        let copy = try #require(try await directories.makeCache().copyForSharing(for: try url("a")))

        _ = directories.makeCache()

        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// 同じURLのファイルを置き直している最中でも、共有に渡すコピーは作れる。表示のための読み込みが元のファイルを置き直すのと、
    /// 共有の操作が重なっても、失敗しないようにするため。
    @Test func copyForSharingIsNotBrokenByConcurrentReplacement() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let cache = directories.makeCache()
        let url = try url("a")
        let data = Data(count: 64 * 1_024)
        _ = try await cache.store(data, named: "a.png", for: url, generation: 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<100 {
                    _ = try await cache.store(data, named: "a.png", for: url, generation: 0)
                }
            }
            group.addTask {
                for _ in 0..<100 {
                    let copy = try #require(try await cache.copyForSharing(for: url))
                    #expect(try Data(contentsOf: copy) == data)
                }
            }
            try await group.waitForAll()
        }
    }

    /// 書き込みの途中で落ちて残ったファイルは、置いたものとして扱わず、整理で消す。書きかけのファイルを共有しないようにするため。
    @Test func ignoresAndTrimsUnfinishedWrites() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let cache = directories.makeCache(sizeLimit: 1)
        _ = try await cache.store(Data("a".utf8), named: "a.png", for: try url("a"), generation: 0)
        let folder = try #require(try FileManager.default.contentsOfDirectory(at: directories.cache, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: folder.appending(path: "a.png"))
        try Data("half".utf8).write(to: folder.appending(path: ".partial-\(UUID().uuidString)"))

        #expect(await cache.contains(try url("a")) == false)
        _ = try await cache.store(Data("b".utf8), named: "b.png", for: try url("b"), generation: 0)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}


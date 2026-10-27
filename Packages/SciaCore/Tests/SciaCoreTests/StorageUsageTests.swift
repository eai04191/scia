import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
struct StorageUsageTests {
    private let root = TestScratch.url("StorageUsageTests")

    /// `path`に`size`バイトのファイルを書く。
    @discardableResult
    private func write(_ path: String, size: Int = 10_000) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
        return url
    }

    /// `path`をフォルダーに置いた日時。起動の日時の代わりに、このあとに置いたものと前に置いたものの境目として使う。
    /// 置いた日時は書き換えられないので、実際の順に書いたファイルの日時を読んで、テストが時刻を作らずに済むようにする。
    private func added(_ path: String) throws -> Date {
        var url = root.appending(path: path)
        url.removeAllCachedResourceValues()
        return try #require(url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }

    /// 下の階層のファイルと隠しファイルも足し、ディスクに割り当てた大きさで数える。
    @Test func sumsAllocatedSizeOfNestedAndHiddenFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", size: 1)
        try write("folder/b", size: 5_000)
        try write("folder/.hidden", size: 5_000)
        let total = StorageUsage.allocatedSize(of: root)
        // APFSは1バイトのファイルにも1ブロック割り当てるため、中身の長さの合計より大きい。
        #expect(total >= 10_001)
        #expect(StorageUsage.allocatedSize(of: root.appending(path: "a")) > 0)
    }

    /// ハードリンクは、同じ中身を指すので1つとして数える。
    @Test func countsHardLinksOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("a", size: 20_000)
        let single = StorageUsage.allocatedSize(of: root)
        try FileManager.default.createDirectory(at: root.appending(path: "folder"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: file, to: root.appending(path: "folder/b"))
        #expect(StorageUsage.allocatedSize(of: root) == single)
        #expect(StorageUsage.allocatedSize(in: root, addedBefore: .distantFuture) == single)
    }

    /// 同じURLで測り直しても、URLが覚えた前の値ではなく、いまの大きさを返す。
    @Test func remeasuringTheSameURLReadsTheCurrentSize() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("a", size: 100_000)
        let before = StorageUsage.allocatedSize(of: file)
        try Data(count: 1).write(to: file)
        #expect(StorageUsage.allocatedSize(of: file) < before)
    }

    @Test func missingFolderIsZero() {
        #expect(StorageUsage.allocatedSize(of: root.appending(path: "missing")) == 0)
    }

    /// 起動より前に置いたファイルだけを消し、起動のあとに置いたファイルと、それを入れたフォルダーは残す。
    @Test func removesOnlyItemsAddedBeforeTheDate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Old/a")
        try write("Old/Nested/b")
        try write("Shared/old")
        try write("Shared/new")
        try write("new")
        let launch = try added("Shared/new")
        try #require(try added("Shared/old") < launch)

        let removable = StorageUsage.allocatedSize(in: root, addedBefore: launch)
        #expect(removable == StorageUsage.allocatedSize(of: root.appending(path: "Old")) + StorageUsage.allocatedSize(of: root.appending(path: "Shared/old")))

        try StorageUsage.removeItems(in: root, addedBefore: launch)

        #expect(!exists("Old"))
        #expect(!exists("Shared/old"))
        #expect(exists("Shared/new"))
        #expect(exists("new"))
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
        #expect(StorageUsage.allocatedSize(in: root, addedBefore: launch) == 0)
    }

    /// 前の起動のファイルを起動のあとにコピーしたもの（共有用のコピーや下書きの添付）は、作った日時が古くても消さない。
    /// `copyItem`は作った日時を元のファイルから引き継ぐため、作った日時で判定すると、使っているコピーを消してしまう。
    @Test func keepsCopiesOfOldFilesMadeAfterTheDate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write("Caches/old.jpg")
        var values = URLResourceValues()
        values.creationDate = .distantPast
        var sourceWithValues = source
        try sourceWithValues.setResourceValues(values)
        try FileManager.default.createDirectory(at: root.appending(path: "tmp/Sharing"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: root.appending(path: "tmp/Sharing/old.jpg"))
        let launch = try added("tmp/Sharing/old.jpg")

        #expect(StorageUsage.allocatedSize(in: root.appending(path: "tmp"), addedBefore: launch) == 0)
        try StorageUsage.removeItems(in: root.appending(path: "tmp"), addedBefore: launch)
        #expect(exists("tmp/Sharing/old.jpg"))
    }

    /// 起動のあとに置いた空のフォルダーは、これから使うかもしれないので消さない。
    @Test func keepsEmptyFoldersAddedAfterTheDate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Fresh", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try StorageUsage.removeItems(in: root, addedBefore: added("Fresh"))
        #expect(exists("Fresh"))
    }

    /// 前の起動のフォルダーでも、中に起動のあとに置いたものがあれば消さない。
    @Test func keepsOldFoldersHoldingNewItems() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "ComposeMedia/Old", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try write("ComposeMedia/New/a.png")
        let launch = try added("ComposeMedia/New")
        try #require(try added("ComposeMedia") < launch)
        try StorageUsage.removeItems(in: root, addedBefore: launch)
        #expect(!exists("ComposeMedia/Old"))
        #expect(exists("ComposeMedia/New/a.png"))
    }

    /// 項目に分けた残りを「その他」にし、合計がコンテナとApp Groupのコンテナの大きさと合う。一時ファイルは起動より前の分だけを消してよいものにする。
    @Test func breakdownSplitsTheContainer() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Container/Library/Caches/MediaFiles/x/a.jpg", size: 20_000)
        try write("Container/tmp/old", size: 8_000)
        try write("Container/tmp/new", size: 8_000)
        let launch = try added("Container/tmp/new")
        try #require(try added("Container/tmp/old") < launch)
        try write("Container/Documents/DiscomfortReports/r.json")
        try write("Container/Library/Preferences/p.plist")
        try write("Container/Library/HTTPStorages/c")
        try write("Container/SystemData/com.apple.SafariViewService/Library/w", size: 6_000)
        try write("Container/Library/Caches/net.example/Cache.db", size: 4_096)
        try write("Container/Library/Caches/net.example/fsCachedData/f", size: 9_000)
        try write("Container/Library/Caches/net.example/com.apple.metal/m")
        try write("Shared/SharedMedia/s")
        try write("App.app/App", size: 30_000)
        let size = { (path: String) in StorageUsage.allocatedSize(of: root.appending(path: path)) }
        let locations = StorageLocations(
            container: root.appending(path: "Container"),
            mediaFiles: root.appending(path: "Container/Library/Caches/MediaFiles"),
            temporary: root.appending(path: "Container/tmp"),
            discomfortReports: root.appending(path: "Container/Documents/DiscomfortReports"),
            preferences: root.appending(path: "Container/Library/Preferences"),
            networkCache: ["Cache.db", "Cache.db-wal", "fsCachedData"].map { root.appending(path: "Container/Library/Caches/net.example/\($0)") },
            inAppSafari: root.appending(path: "Container/SystemData/com.apple.SafariViewService"),
            sharedContainer: root.appending(path: "Shared"),
            appBundle: root.appending(path: "App.app")
        )
        let networkCache = size("Container/Library/Caches/net.example/Cache.db") + size("Container/Library/Caches/net.example/fsCachedData")
        let breakdown = StorageBreakdown.measure(locations, launchDate: launch)

        let media = size("Container/Library/Caches/MediaFiles")
        #expect(breakdown.item(.mediaFiles) == .init(category: .mediaFiles, bytes: media, removableBytes: media))
        #expect(breakdown.item(.networkCache) == .init(category: .networkCache, bytes: networkCache, removableBytes: networkCache))
        #expect(breakdown.item(.temporaryFiles) == .init(category: .temporaryFiles, bytes: size("Container/tmp"), removableBytes: size("Container/tmp/old")))
        let reports = size("Container/Documents/DiscomfortReports")
        #expect(breakdown.item(.discomfortReports) == .init(category: .discomfortReports, bytes: reports, removableBytes: reports))
        let safari = size("Container/SystemData/com.apple.SafariViewService")
        #expect(breakdown.item(.inAppSafari) == .init(category: .inAppSafari, bytes: safari, removableBytes: safari))
        #expect(breakdown.item(.settings)?.bytes == size("Container/Library/Preferences"))
        #expect(breakdown.item(.sharedMedia)?.bytes == size("Shared"))
        #expect(breakdown.item(.other)?.bytes == size("Container/Library/HTTPStorages") + size("Container/Library/Caches/net.example/com.apple.metal"))
        #expect(breakdown.appBytes == size("App.app"))
        #expect(breakdown.dataBytes == size("Container") + size("Shared"))
    }

    /// 中を読めないフォルダー（実機のアプリ内のSafariのデータ）は、0ではなく測れないものとし、合計にも入れない。消すのは公開APIで行えるので、消せるものとして扱う。
    @Test func unreadableSafariDataIsUnmeasured() throws {
        let safari = root.appending(path: "Container/SystemData/com.apple.SafariViewService")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: root)
        }
        try write("Container/SystemData/com.apple.SafariViewService/Library/w", size: 6_000)
        try write("Container/Library/Caches/MediaFiles/a.jpg", size: 20_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari.path(percentEncoded: false))
        let locations = StorageLocations(
            container: root.appending(path: "Container"), mediaFiles: root.appending(path: "Container/Library/Caches/MediaFiles"), temporary: root.appending(path: "tmp"),
            discomfortReports: root.appending(path: "d"), preferences: root.appending(path: "p"), networkCache: [], inAppSafari: safari, sharedContainer: nil, appBundle: root.appending(path: "a")
        )
        let breakdown = StorageBreakdown.measure(locations, launchDate: nil)
        #expect(breakdown.item(.inAppSafari) == .init(category: .inAppSafari, bytes: nil, removableBytes: nil))
        #expect(breakdown.hasUnmeasuredItems)
        #expect(breakdown.dataBytes == StorageUsage.allocatedSize(of: root.appending(path: "Container/Library/Caches/MediaFiles")))
    }

    /// まだ作られていないフォルダーは、読めないのではなく何もないので0とする。
    @Test func missingSafariDataIsZero() {
        let locations = StorageLocations(
            container: root, mediaFiles: root.appending(path: "m"), temporary: root.appending(path: "tmp"),
            discomfortReports: root.appending(path: "d"), preferences: root.appending(path: "p"), networkCache: [], inAppSafari: root.appending(path: "s"), sharedContainer: nil, appBundle: root.appending(path: "a")
        )
        let breakdown = StorageBreakdown.measure(locations, launchDate: nil)
        #expect(breakdown.item(.inAppSafari) == .init(category: .inAppSafari, bytes: 0, removableBytes: 0))
        #expect(!breakdown.hasUnmeasuredItems)
    }

    /// 起動の日時が分からないときは、一時ファイルを消してよいものとして数えない。
    @Test func unknownLaunchDateKeepsTemporaryFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("tmp/old")
        let locations = StorageLocations(
            container: root, mediaFiles: root.appending(path: "m"), temporary: root.appending(path: "tmp"),
            discomfortReports: root.appending(path: "d"), preferences: root.appending(path: "p"), networkCache: [], inAppSafari: root.appending(path: "s"), sharedContainer: nil, appBundle: root.appending(path: "a")
        )
        let breakdown = StorageBreakdown.measure(locations, launchDate: nil)
        #expect(breakdown.item(.temporaryFiles)?.removableBytes == 0)
        #expect(breakdown.item(.temporaryFiles)?.bytes ?? 0 > 0)
    }
}

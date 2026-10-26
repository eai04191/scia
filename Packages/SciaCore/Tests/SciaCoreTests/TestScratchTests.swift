import Foundation
import Testing
@testable import SciaTesting

struct TestScratchTests {
    /// テストの終わりに、作った一時ファイルと、設定の保存先のplistを消す。
    @Test func removesFilesAndPreferencesWhenTheTestEnds() async throws {
        let registry = TestScratch.Registry()
        let (url, suite) = TestScratch.$registry.withValue(registry) {
            (TestScratch.url("TestScratchTests", pathExtension: "txt"), TestScratch.suiteName("TestScratchTests"))
        }
        #expect(url.lastPathComponent.hasPrefix("TestScratch-\(getpid())-TestScratchTests-"))
        #expect(url.pathExtension == "txt")
        try Data("a".utf8).write(to: url)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(1, forKey: "value")
        let plist = URL.libraryDirectory.appending(path: "Preferences/\(suite).plist")
        try await waitUntil { FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)) }

        registry.removeAll()

        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)))
    }

    /// 終わったプロセスが残したものは消し、走っているプロセスのものと、ほかの名前のものは残す。
    @Test(.scratch) func removesLeftoversOfFinishedProcessesOnly() throws {
        let folder = TestScratch.url("TestScratchTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 終わったプロセスには、プロセスIDになりえない大きな値を使う。1は走り続けているlaunchd。
        let names = ["TestScratch-\(Int32.max)-a-1", "TestScratch-\(getpid())-b-2", "TestScratch-1-c-3", "Other-\(Int32.max)-d"]
        for name in names {
            try Data().write(to: folder.appending(path: name))
        }

        TestScratch.removeLeftovers(in: folder, separator: "-", suffix: "")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(remaining == ["Other-\(Int32.max)-d", "TestScratch-1-c-3", "TestScratch-\(getpid())-b-2"])
    }

    /// `.scratch`の外で作ると、消せないまま残るので、テストを失敗にする。
    @Test func recordsAnIssueOutsideTheScope() {
        withKnownIssue {
            _ = TestScratch.url("TestScratchTests")
        }
    }
}

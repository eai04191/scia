import Foundation
import Synchronization
import Testing
@testable import SciaTesting

@Suite(.scratch)
struct TestDiagnosticsTests {
    @Test func capturesFailureBeforeScratchCleanup() async throws {
        let output = Mutex<[String: Data]>([:])
        let diagnostics = TestDiagnostics { data, name in output.withLock { $0[name] = data } }
        let registry = TestScratch.Registry()
        let file = TestScratch.$registry.withValue(registry) { TestScratch.url("evidence", pathExtension: "bin") }
        try Data([1, 2, 3]).write(to: file)
        defer { registry.removeAll() }
        let test = try #require(Test.current)

        try await IssueHandlingTrait.filterIssues { _ in false }.provideScope(for: test, testCase: nil) {
            try await diagnostics.withScope(for: test, testCase: nil, scratch: registry) {
                let gate = Gate()
                let clock = TestClock()
                let waiting = Task { try await gate.wait() }
                try await waitUntil { gate.waiterCount >= 1 }
                let sleeping = Task { try await clock.sleep(for: .seconds(3)) }
                try await waitUntil { clock.sleeperCount(remaining: .seconds(3)) >= 1 }
                Issue.record("診断の検証用の失敗")
                gate.open()
                clock.advance(by: .seconds(3))
                try await waiting.value
                try await sleeping.value
            }
        }

        let files = output.withLock { $0 }
        let report = String(decoding: try #require(files["failure-diagnostics.txt"]), as: UTF8.self)
        #expect(report.contains("Gate"))
        #expect(report.contains("wait #0 待機数=1"))
        #expect(report.contains("TestClock"))
        #expect(report.contains("sleep #0"))
        #expect(report.contains("失敗を記録したスレッドのスタック"))
        #expect(files.values.contains(Data([1, 2, 3])))
        registry.removeAll()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(files.values.contains(Data([1, 2, 3])))
    }

    @Test func capturesNestedFilesWithoutFollowingLinks() throws {
        let registry = TestScratch.Registry()
        let root = TestScratch.$registry.withValue(registry) { TestScratch.url("diagnostic-directory") }
        defer { registry.removeAll() }
        let nested = root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([7, 8]).write(to: nested.appending(path: "image.bin"))
        let outside = TestScratch.url("outside-diagnostic-directory")
        try Data([9]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside)
        let output = Mutex<[String: Data]>([:])
        registry.captureFiles { data, name in output.withLock { $0[name] = data } }
        let files = output.withLock { $0 }
        #expect(files.values.contains(Data([7, 8])))
        #expect(!files.values.contains(Data([9])))
        #expect(String(decoding: try #require(files["scratch-files.txt"]), as: UTF8.self).contains("nested/image.bin"))
    }

    @Test func reportsUnreadableDirectory() throws {
        let registry = TestScratch.Registry()
        let root = TestScratch.$registry.withValue(registry) { TestScratch.url("unreadable-diagnostics") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appending(path: "evidence.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            registry.removeAll()
        }
        let output = Mutex<[String: Data]>([:])
        registry.captureFiles { data, name in output.withLock { $0[name] = data } }
        let manifest = String(decoding: try #require(output.withLock { $0["scratch-files.txt"] }), as: UTF8.self)
        #expect(manifest.contains(root.resolvingSymlinksInPath().path), "\(manifest)")
        #expect(manifest.contains("列挙できませんでした"))
    }

    @Test func scratchSharesTheOuterDiagnostics() async throws {
        let reports = Mutex<[String]>([])
        let diagnostics = TestDiagnostics { _, name in reports.withLock { $0.append(name) } }
        let test = try #require(Test.current)
        try await IssueHandlingTrait.filterIssues { _ in false }.provideScope(for: test, testCase: nil) {
            try await diagnostics.withScope(for: test, testCase: nil) {
                try await TestScratchTrait().provideScope(for: test, testCase: nil) {
                    let file = TestScratch.url("shared-diagnostics")
                    try Data([1]).write(to: file)
                    Issue.record("共通の収集器を確かめる失敗")
                }
            }
        }
        let names = reports.withLock { $0 }
        #expect(names.filter { $0 == "failure-diagnostics.txt" }.count == 1)
        #expect(names.contains { $0.contains("shared-diagnostics") })
    }

    @Test func stallLimitCapturesThrownError() async throws {
        struct Failure: Error {}
        let reports = Mutex<[String]>([])
        let diagnostics = TestDiagnostics { data, _ in reports.withLock { $0.append(String(decoding: data, as: UTF8.self)) } }
        let test = try #require(Test.current)
        let clock = TestClock()
        try await IssueHandlingTrait.filterIssues { _ in false }.provideScope(for: test, testCase: nil) {
            try await TestDiagnostics.$current.withValue(diagnostics) {
                try await StallLimitTrait(limit: .seconds(60), clock: clock).provideScope(for: test, testCase: nil) {
                    throw Failure()
                }
            }
        }
        #expect(reports.withLock { $0 }.contains { $0.contains("Failure") })
        #expect(clock.sleeperCount == 0)
    }

    @Test func successfulScopeDoesNotEmitAttachments() async throws {
        let output = Mutex<[String]>([])
        let diagnostics = TestDiagnostics { _, name in output.withLock { $0.append(name) } }
        let test = try #require(Test.current)
        try await diagnostics.withScope(for: test, testCase: nil) {
            let gate = Gate()
            gate.open()
            try await gate.wait()
        }
        #expect(output.withLock { $0.isEmpty })
    }

    @Test func keepsCurrentStateAfterHistoryIsTruncated() {
        let diagnostics = TestDiagnostics()
        TestDiagnostics.$current.withValue(diagnostics) {
            let stuck = DiagnosticResource("未完了の待機")
            stuck.note("待機中")
            let active = DiagnosticResource("進行中の処理")
            for index in 0..<200 { active.note("段階\(index)") }
        }
        #expect(diagnostics.history.contains("未完了の待機"))
        #expect(diagnostics.history.contains("段階199"))
        #expect(!diagnostics.history.contains("段階0\n"))
        #expect(diagnostics.history.contains("先頭73件省略"))
    }

    @Test func separateScopesDoNotMixEvents() async throws {
        let test = try #require(Test.current)
        let first = TestDiagnostics()
        let second = TestDiagnostics()
        async let one: Void = first.withScope(for: test, testCase: nil) { DiagnosticResource("first").note("開始") }
        async let two: Void = second.withScope(for: test, testCase: nil) { DiagnosticResource("second").note("開始") }
        _ = try await (one, two)
        #expect(first.history.contains("first"))
        #expect(!first.history.contains("second"))
        #expect(second.history.contains("second"))
        #expect(!second.history.contains("first"))
    }
}

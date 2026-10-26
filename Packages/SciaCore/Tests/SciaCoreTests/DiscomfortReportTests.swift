import Foundation
import os
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct StateDumpRegistryTests {
    private final class Screen {
        var count = 3
    }

    @Test func dumpsRegisteredOwnersInOrder() {
        let registry = StateDumpRegistry()
        let first = Screen()
        let second = Screen()
        second.count = 5
        registry.register("first", owner: first) { "count=\($0.count)" }
        registry.register("second", owner: second) { "count=\($0.count)" }

        #expect(registry.dumpAll() == [
            StateDump(name: "first", text: "count=3"),
            StateDump(name: "second", text: "count=5"),
        ])
    }

    @Test func skipsReleasedOwners() throws {
        let registry = StateDumpRegistry()
        let kept = Screen()
        var released: Screen? = Screen()
        registry.register("kept", owner: kept) { "count=\($0.count)" }
        registry.register("released", owner: try #require(released)) { "count=\($0.count)" }
        released = nil

        #expect(registry.dumpAll().map(\.name) == ["kept"])
    }
}

@Suite(.scratch)
struct DiscomfortReportStoreTests {
    private func makeStore() -> DiscomfortReportStore {
        DiscomfortReportStore(directory: TestScratch.url("DiscomfortReportStoreTests"))
    }

    private func makeReport(capturedAt: Date) -> DiscomfortReport {
        DiscomfortReport(
            capturedAt: capturedAt,
            memo: "新着が来たときに一瞬ガクッとした",
            operationComments: [OperationComment(date: capturedAt.addingTimeInterval(-2), operation: "2秒前 ホームを下へ1.0画面分スクロールした（0.5秒）", text: "ここでガクッとした")],
            stateDumps: [StateDump(name: "timeline", text: "items=60")],
            logs: [LogLine(date: capturedAt.addingTimeInterval(-1), category: "timeline", level: "info", message: "prepend 3")]
        )
    }

    @Test func savedReportRoundTrips() throws {
        let store = makeStore()
        let report = makeReport(capturedAt: Date(timeIntervalSince1970: 1_791_861_705.123))

        let url = try store.save(report)

        #expect(url.lastPathComponent.hasPrefix("discomfort-"))
        let loaded = try #require(try store.loadAll().first)
        // 日時はISO 8601のミリ秒までで保存するため、それより細かい精度は落ちる。
        #expect(abs(loaded.capturedAt.timeIntervalSince(report.capturedAt)) < 0.001)
        #expect(loaded.memo == report.memo)
        #expect(loaded.operationComments.map(\.text) == report.operationComments.map(\.text))
        #expect(loaded.stateDumps == report.stateDumps)
        #expect(loaded.logs.map(\.message) == report.logs.map(\.message))
    }

    @Test func loadsReportsNewestFirst() throws {
        let store = makeStore()
        let older = makeReport(capturedAt: Date(timeIntervalSince1970: 1_791_861_705))
        let newer = makeReport(capturedAt: Date(timeIntervalSince1970: 1_791_861_800))
        try store.save(older)
        try store.save(newer)

        #expect(try store.loadAll().map(\.capturedAt) == [newer.capturedAt, older.capturedAt])
    }

    /// 書きかけで落ちたなどで読めないレポートが1件あっても、残りは読む。
    @Test func skipsUnreadableReport() throws {
        let store = makeStore()
        let report = makeReport(capturedAt: Date(timeIntervalSince1970: 1_791_861_705))
        try store.save(report)
        try Data("{\"capturedAt\":".utf8).write(to: store.directory.appending(path: "discomfort-broken.json"))

        #expect(try store.loadAll().map(\.capturedAt) == [report.capturedAt])
    }

    /// 全部消したあとも、続けて保存できる。まだ何も保存していなくても失敗しない。
    @Test func removeAllDeletesReportsAndKeepsSaving() throws {
        let store = makeStore()
        try store.removeAll()
        try store.save(makeReport(capturedAt: Date(timeIntervalSince1970: 1_791_861_705)))
        try store.save(makeReport(capturedAt: Date(timeIntervalSince1970: 1_791_861_706)))

        try store.removeAll()

        #expect(try store.loadAll().isEmpty)
        try store.save(makeReport(capturedAt: Date(timeIntervalSince1970: 1_791_861_707)))
        #expect(try store.loadAll().count == 1)
    }

    @Test func loadAllReturnsEmptyWhenNothingSaved() throws {
        #expect(try makeStore().loadAll().isEmpty)
    }
}

// macOSでは、OSLogStoreをプロセスで初めて読むときにMac全体のログを走査し、1回に10秒以上かかる。
// 2件で`make test-core`の時間の半分を占めるため、iOSシミュレーター（`make test`）でだけ走らせる。
#if os(iOS)
@Suite(.scratch)
struct RecentLogReaderTests {
    /// iOSシミュレーターでは、ログを書いてからOSLogStoreで読めるまでに1秒以上かかることがある。
    /// マーカーまで読めるのを待つことで、確保した瞬間の直前のログまで含める。
    @Test func readsLogsUpToMarker() async throws {
        let subsystem = "net.mizle.scia.tests.\(UUID().uuidString)"
        // subsystemはこのテストだけのものなので、プロセスの初めから読んでも、このテストで書いたログだけが読める。
        // 今の時刻から始めると、ログに記録される時刻がそれより早くなることがあるため、時刻では区切らない。
        let start = Date.distantPast
        let logger = Logger(subsystem: subsystem, category: "timeline")
        logger.notice("prepend \(3, privacy: .public)")
        Logger(subsystem: "net.mizle.scia.tests.other", category: "timeline").notice("other subsystem")
        let marker = RecentLogReader.writeMarker(subsystem: subsystem)
        logger.notice("after marker")

        let lines = try await RecentLogReader.read(subsystem: subsystem, from: start, untilMarker: marker)

        #expect(lines.map(\.message) == ["prepend 3", marker])
        #expect(lines.first?.category == "timeline")
        #expect(lines.first?.level == "notice")
    }

    @Test func failsWhenMarkerNeverAppears() async {
        let subsystem = "net.mizle.scia.tests.\(UUID().uuidString)"

        await #expect(throws: RecentLogReader.ReadError.markerNotFound) {
            // 待つ長さを0にして、1回読んで見つからなければ失敗させる。
            _ = try await RecentLogReader.read(subsystem: subsystem, from: .distantPast, untilMarker: "never", timeout: .zero)
        }
    }
}
#endif

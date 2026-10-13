import Foundation
import os
import Testing
@testable import SciaCore

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

struct DiscomfortReportStoreTests {
    private func makeStore() -> DiscomfortReportStore {
        DiscomfortReportStore(directory: FileManager.default.temporaryDirectory.appending(path: "DiscomfortReportStoreTests-\(UUID().uuidString)"))
    }

    private func makeReport(capturedAt: Date) -> DiscomfortReport {
        DiscomfortReport(
            capturedAt: capturedAt,
            memo: "新着が来たときに一瞬ガクッとした",
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

    @Test func loadAllReturnsEmptyWhenNothingSaved() throws {
        #expect(try makeStore().loadAll().isEmpty)
    }
}

struct RecentLogReaderTests {
    /// iOSシミュレーターでは、ログを書いてからOSLogStoreで読めるまでに1秒以上かかることがある。
    /// マーカーまで読めるのを待つことで、確保した瞬間の直前のログまで含める。
    @Test func readsLogsUpToMarker() async throws {
        let subsystem = "net.mizle.scia.tests.\(UUID().uuidString)"
        // ログに記録される時刻はDate()より数ミリ秒早くなることがあるため、開始時刻に余裕を持たせる。
        let start = Date().addingTimeInterval(-1)
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
            _ = try await RecentLogReader.read(subsystem: subsystem, from: Date(), untilMarker: "never", timeout: .milliseconds(300))
        }
    }
}

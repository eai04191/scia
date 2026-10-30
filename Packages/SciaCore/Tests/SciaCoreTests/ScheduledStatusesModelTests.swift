import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 予約の一覧の読み込みと操作。決まりはdocs/tabs.mdの「予約投稿」にある。
@MainActor
@Suite(.serialized)
struct ScheduledStatusesModelTests {
    /// 予約の一覧の画面の偽物。送られた並びと状態を記録する。
    private final class RecordingDisplay: ScheduledStatusesDisplay {
        var account: Account?
        private(set) var statusesCalls: [(ids: [String], animatingChanges: Bool)] = []
        private(set) var contentState = ScheduledStatusesContentState.loading
        var ids: [String] { statusesCalls.last?.ids ?? [] }

        func setStatuses(_ statuses: [ScheduledStatus], animatingChanges: Bool) {
            statusesCalls.append((statuses.map(\.id), animatingChanges))
        }

        func setContentState(_ state: ScheduledStatusesContentState) {
            contentState = state
        }
    }

    nonisolated private static func body(_ ids: [String]) -> Data {
        let items = ids.map { #"{"id":"\#($0)","scheduled_at":"2026-10-28T00:00:00.000Z","params":{"text":"予約\#($0)"},"media_attachments":[]}"# }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    private static let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)

    private func makeModel(transport: RoutedTransport, tasks: TaskScope = TaskScope()) -> (ScheduledStatusesModel, RecordingDisplay) {
        let model = ScheduledStatusesModel(client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), tasks: tasks, myAccount: { Self.account }) {}
        let display = RecordingDisplay()
        model.display = display
        return (model, display)
    }

    /// 読んでいる間に予約できたら、その前に送った読み込みの古い応答で、予約した行を消さない。読み直して、新しい応答を使う。
    @Test func localChangeDuringLoadIsNotOverwritten() async throws {
        let gate = Gate()
        let calls = Mutex(0)
        let transport = RoutedTransport { _ in
            let call = calls.withLock { calls in
                defer { calls += 1 }
                return calls
            }
            switch call {
            case 0: return (200, Self.body(["60"]))
            case 1:
                try await gate.wait()
                return (200, Self.body(["60"]))
            default: return (200, Self.body(["60", "70"]))
            }
        }
        let (model, display) = makeModel(transport: transport)
        await model.reload(purpose: .action)?.value
        #expect(display.ids == ["60"])
        #expect(display.account == Self.account)
        #expect(display.contentState == .loaded)

        let loading = model.reload(purpose: .display)
        try await waitUntil { gate.waiterCount == 1 }
        model.didSchedule(ScheduledStatus(id: "70", scheduledAt: Date(timeIntervalSince1970: 1_900_000_000), params: ScheduledStatus.Params(text: "予約70")))
        #expect(display.ids == ["60", "70"])
        gate.open()
        await loading?.value

        #expect(Set(display.ids) == ["60", "70"])
        #expect(calls.withLock { $0 } == 3)
    }

    /// 取り消そうとした予約がもうなければ、投稿されないことは変わらないので、行を動かして消す。
    @Test func cancellingMissingScheduleRemovesRow() async throws {
        let transport = RoutedTransport { request in
            if request.httpMethod == "DELETE" {
                return (404, Data(#"{"error":"Record not found"}"#.utf8))
            }
            return (200, Self.body(["60", "70"]))
        }
        let (model, display) = makeModel(transport: transport)
        var failures: [ScheduledStatusesModel.Operation] = []
        model.onFailure = { operation, _ in failures.append(operation) }
        await model.reload(purpose: .action)?.value

        model.cancel(ScheduledStatus(id: "60", scheduledAt: Date(timeIntervalSince1970: 1_900_000_000), params: ScheduledStatus.Params(text: "予約60")))
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(display.ids == ["70"])
        #expect(display.statusesCalls.last?.animatingChanges == true)
        #expect(failures.isEmpty)
    }

    /// 日時を変えられなかったら、行はそのままにして、作る側に失敗を知らせる。
    @Test func failedRescheduleReportsFailure() async throws {
        let transport = RoutedTransport { request in
            if request.httpMethod == "PUT" {
                return (422, Data(#"{"error":"Scheduled at must be at least 5 minutes in the future"}"#.utf8))
            }
            return (200, Self.body(["60"]))
        }
        let (model, display) = makeModel(transport: transport)
        var failures: [ScheduledStatusesModel.Operation] = []
        model.onFailure = { operation, _ in failures.append(operation) }
        await model.reload(purpose: .action)?.value
        let callsBefore = display.statusesCalls.count

        model.reschedule(ScheduledStatus(id: "60", scheduledAt: Date(timeIntervalSince1970: 1_900_000_000), params: ScheduledStatus.Params(text: "予約60")), to: Date(timeIntervalSince1970: 1_900_003_600))
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(failures == [.reschedule])
        #expect(display.statusesCalls.count == callsBefore)
    }

    /// 読めた一覧は、読み直しに失敗しても消さない。まだ何も読めていなければ、理由を一覧の場所に出す。
    @Test func reloadFailureKeepsLoadedList() async throws {
        let fails = Mutex(true)
        let transport = RoutedTransport { _ in
            if fails.withLock({ $0 }) {
                return (422, Data(#"{"error":"Unprocessable"}"#.utf8))
            }
            return (200, Self.body(["60"]))
        }
        let (model, display) = makeModel(transport: transport)

        await model.reload(purpose: .action)?.value
        guard case .failed = display.contentState else {
            Issue.record("読めなかったことを出していません: \(display.contentState)")
            return
        }

        fails.withLock { $0 = false }
        await model.reload(purpose: .action)?.value
        #expect(display.contentState == .loaded)

        fails.withLock { $0 = true }
        await model.reload(purpose: .display)?.value
        #expect(display.contentState == .loaded)
        #expect(display.ids == ["60"])
    }
}

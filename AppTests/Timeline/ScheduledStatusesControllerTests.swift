import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

/// 予約の一覧の読み込み。決まりはdocs/tabs.mdの「予約投稿」にある。
@MainActor
struct ScheduledStatusesControllerTests {
    nonisolated private static func body(_ ids: [String]) -> Data {
        let items = ids.map { #"{"id":"\#($0)","scheduled_at":"2026-10-28T00:00:00.000Z","params":{"text":"予約\#($0)"},"media_attachments":[]}"# }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    private func makeController(tasks: TaskScope = TaskScope(), transport: some HTTPTransport) throws -> ScheduledStatusesController {
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/a.png"))
        return ScheduledStatusesController(client: MastodonClient(credential: credential, transport: transport), tasks: tasks, myAccount: { account }) {}
    }

    /// 読んでいる間に予約できたら、その前に送った読み込みの古い応答で、予約した行を消さない。読み直して、新しい応答を使う。
    @Test func localChangeDuringLoadIsNotOverwritten() async throws {
        let gate = Gate()
        let calls = Mutex(0)
        let transport = ScriptedTransport { _ in
            let call = calls.withLock { calls in
                defer { calls += 1 }
                return calls
            }
            switch call {
            case 0: return Self.body(["60"])
            case 1:
                try await gate.wait()
                return Self.body(["60"])
            default: return Self.body(["60", "70"])
            }
        }
        let controller = try makeController(transport: transport)
        await controller.reload(purpose: .action)?.value
        #expect(controller.viewController.statuses.map(\.id) == ["60"])

        let loading = controller.reload(purpose: .display)
        try await waitUntil { gate.waiterCount == 1 }
        controller.didSchedule(ScheduledStatus(id: "70", scheduledAt: Date(timeIntervalSince1970: 1_900_000_000), params: ScheduledStatus.Params(text: "予約70")))
        gate.open()
        await loading?.value

        #expect(Set(controller.viewController.statuses.map(\.id)) == ["60", "70"])
        #expect(calls.withLock { $0 } == 3)
    }

    /// 引っぱって読み直す読み込みも、一覧の持ち主の子で走らせる。ログアウトで閉じたら止まる。
    @Test func refreshRunsInsideScope() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _ in
            try await gate.wait()
            return Self.body([])
        }
        let tasks = TaskScope()
        let controller = try makeController(tasks: tasks, transport: transport)

        let refreshing = Task { await controller.viewController.onRefresh() }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(controller.runningTaskCount == 1)
        tasks.close()
        await refreshing.value

        #expect(controller.runningTaskCount == 0)
    }
}

/// 予約の本文を、投稿の本文と同じ部品で描く。
@MainActor
struct ScheduledStatusBodyTests {
    /// 書いたときのソースの文字なので、HTMLとして読まず、連続する空白、字下げ、改行、記号を書いたまま残す。
    @Test func plainBodyKeepsSourceAsWritten() {
        let builder = PostContentBuilder(tuning: AppDependencies.tuning, settings: AppDependencies.settings, emojiImages: AppDependencies.emojiImages, mediaImages: AppDependencies.mediaImages, avatarImages: AppDependencies.avatarImages)
        let status = Status(id: "1", createdAt: Date(timeIntervalSince1970: 0), account: Account(id: "1", username: "a", acct: "a", displayName: "A", avatar: nil), content: "", spoilerText: "", url: nil)
        let source = "A  B\n  字下げ\n<b>&</b>"

        let body = builder.body(plain: source, of: status, base: .cell())

        // 改行は、投稿の本文の`<br>`と同じく、段落の中の改行（U+2028）で描く。
        #expect(body.string == source.replacingOccurrences(of: "\n", with: "\u{2028}"))
    }
}

/// 呼ばれるたびに、渡した処理が返す本文を200で返す。
private struct ScriptedTransport: HTTPTransport {
    let body: @Sendable (URLRequest) async throws -> Data

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let data = try await body(request)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}

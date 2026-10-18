import Foundation
import Testing
@testable import SciaCore

struct LiveUpdatesTests {
    private static let reconnect = ReconnectingStream.Policy(
        initialRetryDelay: .milliseconds(10),
        maxRetryDelay: .milliseconds(40),
        pingInterval: .seconds(3600),
        pingTimeout: .seconds(5)
    )
    private static let policy = LiveUpdates.Policy(pollingInterval: .milliseconds(15), outageNoticeDelay: .milliseconds(30))

    @Test func pollsAndNoticesOutageWhileNeverConnected() async throws {
        let connector = ScriptedConnector(Array(repeating: .init(handshake: .fail(URLError(.cannotConnectToHost))), count: 100))
        let log = LiveLog()
        let updates = makeUpdates(connector)

        let task = Task { try await updates.run { await log.append($0) } }
        await log.waitUntil { $0.filter { $0 == "poll" }.count >= 3 && $0.contains("outage started") }
        task.cancel()
        _ = await task.result

        let labels = await log.labels
        #expect(labels.filter { $0 == "outage started" }.count == 1, "切れていることを何度も知らせています: \(labels)")
        #expect(!labels.contains("outage ended"))
    }

    @Test func connectingStopsPollingAndEndsNotice() async throws {
        // 10+20+40+40msの失敗の後につながる。知らせるまでの30msとポーリングの15msは、その間に過ぎる。
        let connector = ScriptedConnector(Array(repeating: .init(handshake: .fail(URLError(.cannotConnectToHost))), count: 4) + [.init()])
        let log = LiveLog()
        let updates = makeUpdates(connector)

        let task = Task { try await updates.run { await log.append($0) } }
        await log.waitUntil { $0.contains("outage ended") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.result

        let labels = await log.labels
        let connected = try #require(labels.firstIndex(of: "connected"))
        #expect(labels[..<connected].contains("poll"))
        #expect(labels[..<connected].contains("outage started"))
        #expect(!labels[connected...].contains("poll"), "つながった後もポーリングしています: \(labels)")
        #expect(labels.filter { $0 == "outage ended" }.count == 1)
    }

    @Test func staysQuietWhileConnected() async throws {
        let connector = ScriptedConnector([.init()])
        let log = LiveLog()
        let updates = makeUpdates(connector)

        let task = Task { try await updates.run { await log.append($0) } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["connected"])
    }

    /// 短く切れてすぐつながったときは、知らせず、ポーリングもしない。
    @Test func briefDisconnectionIsNotNoticed() async throws {
        let connector = ScriptedConnector([
            .init(messages: [#"{"stream":["user"],"event":"delete","payload":"1"}"#], afterMessages: .drop),
            .init(),
        ])
        let log = LiveLog()
        // つなぎ直しの10msより十分長くする。
        let updates = makeUpdates(connector, policy: LiveUpdates.Policy(pollingInterval: .milliseconds(80), outageNoticeDelay: .milliseconds(80)))

        let task = Task { try await updates.run { await log.append($0) } }
        await log.waitUntil { $0.filter { $0 == "connected" }.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["connected", "event", "disconnected", "connected"])
    }

    @Test func disconnectionAfterConnectingStartsPollingAgain() async throws {
        let connector = ScriptedConnector([.init(messages: [#"{"stream":["user"],"event":"delete","payload":"1"}"#], afterMessages: .drop)] + Array(repeating: .init(handshake: .fail(URLError(.cannotConnectToHost))), count: 100))
        let log = LiveLog()
        let updates = makeUpdates(connector)

        let task = Task { try await updates.run { await log.append($0) } }
        await log.waitUntil { $0.contains("poll") && $0.contains("outage started") }
        task.cancel()
        _ = await task.result

        let labels = await log.labels
        #expect(Array(labels.prefix(3)) == ["connected", "event", "disconnected"], "\(labels)")
    }

    @Test func cancellationEndsRun() async throws {
        let connector = ScriptedConnector([.init()])
        let log = LiveLog()
        let updates = makeUpdates(connector)

        let task = Task { try await updates.run { await log.append($0) } }
        await log.waitUntil { !$0.isEmpty }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connector.closedCount == 1)
    }

    private func makeUpdates(_ connector: ScriptedConnector, policy: LiveUpdates.Policy = Self.policy) -> LiveUpdates {
        let client = StreamingClient(
            credential: Credential(
                instance: URL(filePath: "/"),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            connector: connector
        )
        let stream = ReconnectingStream(policy: Self.reconnect) {
            client.open(baseURL: URL(filePath: "/"))
        }
        return LiveUpdates(stream: stream, policy: policy)
    }
}

/// 届いた活動を記録し、条件を満たすまで待てるようにする。
private actor LiveLog {
    private(set) var labels: [String] = []
    private var waiters: [(condition: @Sendable ([String]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ activity: LiveUpdates.Activity) {
        labels.append(Self.label(activity))
        let labels = labels
        let ready = waiters.filter { $0.condition(labels) }
        waiters.removeAll { $0.condition(labels) }
        ready.forEach { $0.continuation.resume() }
    }

    func waitUntil(_ condition: @escaping @Sendable ([String]) -> Bool) async {
        if condition(labels) { return }
        await withCheckedContinuation { waiters.append((condition, $0)) }
    }

    private static func label(_ activity: LiveUpdates.Activity) -> String {
        switch activity {
        case .stream(.connected): "connected"
        case .stream(.event): "event"
        case .stream(.unauthorized): "unauthorized"
        case .stream(.disconnected): "disconnected"
        case .poll: "poll"
        case .outage(isOngoing: true): "outage started"
        case .outage(isOngoing: false): "outage ended"
        }
    }
}

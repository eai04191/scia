import Foundation
import SciaTesting
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
        let clock = TestClock()
        let updates = makeUpdates(connector, clock: clock)

        let task = Task { try await updates.run { await log.append($0) } }
        // 数だけを確かめるので、順は問わずに時計を進める。
        try await waitUntil(advancing: clock, by: .milliseconds(5)) {
            let labels = await log.labels
            return labels.filter { $0 == "poll" }.count >= 3 && labels.contains("outage started")
        }
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
        let clock = TestClock()
        let updates = makeUpdates(connector, clock: clock)

        let task = Task { try await updates.run { await log.append($0) } }
        // つなぎ直し（10ms後）、ポーリング（15ms後）、知らせ（30ms後）を待ち始めてから、30msまで進める。
        try await waitUntil { await log.labels == ["disconnected"] && clock.sleeperCount(dueWithin: .milliseconds(30)) == 3 }
        clock.advance(by: .milliseconds(10))
        try await waitUntil { await log.labels.count == 2 && clock.sleeperCount(dueWithin: .milliseconds(20)) == 3 }
        clock.advance(by: .milliseconds(20))
        // つながるのは、まだ進めていない4回目のつなぎ直しの後なので、ポーリングと知らせは必ずその前に届く。
        try await log.waitUntil { $0.contains("poll") && $0.contains("outage started") && $0.filter { $0 == "disconnected" }.count == 3 }
        try await waitUntil(advancing: clock, by: .milliseconds(10)) { await log.labels.contains("outage ended") }
        // つながったら、ポーリングと知らせの待ちを取り消している。
        #expect(clock.sleeperCount(dueWithin: .seconds(1)) == 0)
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
        let clock = TestClock()
        let updates = makeUpdates(connector, clock: clock)

        let task = Task { try await updates.run { await log.append($0) } }
        // つないだと知らせ、ポーリングと知らせの待ちを取り消してから、時計を進めて静かなままかを見る。
        try await waitUntil { await log.labels.contains("connected") && clock.sleeperCount(dueWithin: .seconds(1)) == 0 }
        clock.advance(by: .milliseconds(150))
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
        let clock = TestClock()
        // つなぎ直しの10msより十分長くする。
        let updates = makeUpdates(connector, policy: LiveUpdates.Policy(pollingInterval: .milliseconds(80), outageNoticeDelay: .milliseconds(80)), clock: clock)

        let task = Task { try await updates.run { await log.append($0) } }
        // 切れてつなぎ直しを待ち始めたら、つなぎ直す10msだけ進める。
        try await waitUntil { await log.labels.count == 3 && clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        // つなぎ直して、ポーリングと知らせの待ちを取り消してから、その締め切りより先まで進める。
        try await waitUntil { await log.labels.filter { $0 == "connected" }.count == 2 && clock.sleeperCount(dueWithin: .seconds(1)) == 0 }
        clock.advance(by: .milliseconds(100))
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["connected", "event", "disconnected", "connected"])
    }

    @Test func disconnectionAfterConnectingStartsPollingAgain() async throws {
        let connector = ScriptedConnector([.init(messages: [#"{"stream":["user"],"event":"delete","payload":"1"}"#], afterMessages: .drop)] + Array(repeating: .init(handshake: .fail(URLError(.cannotConnectToHost))), count: 100))
        let log = LiveLog()
        let clock = TestClock()
        let updates = makeUpdates(connector, clock: clock)

        let task = Task { try await updates.run { await log.append($0) } }
        // 切れるまでは時計を進めないので、つながる前のポーリングや知らせは届かない。切れてから、順は問わずに進める。
        try await log.waitUntil { $0.contains("disconnected") }
        try await waitUntil(advancing: clock, by: .milliseconds(5)) {
            let labels = await log.labels
            return labels.contains("poll") && labels.contains("outage started")
        }
        task.cancel()
        _ = await task.result

        #expect(Array(await log.labels.prefix(3)) == ["connected", "event", "disconnected"])
    }

    @Test func cancellationEndsRun() async throws {
        let connector = ScriptedConnector([.init()])
        let log = LiveLog()
        let updates = makeUpdates(connector)

        let task = Task { try await updates.run { await log.append($0) } }
        try await log.waitUntil { !$0.isEmpty }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connector.closedCount == 1)
    }

    /// 待つ時間はすべて`clock`で数える。進めなければ、つなぎ直しもポーリングも知らせも起きない。
    private func makeUpdates(_ connector: ScriptedConnector, policy: LiveUpdates.Policy = Self.policy, clock: TestClock = TestClock()) -> LiveUpdates {
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
        let stream = ReconnectingStream(policy: Self.reconnect, clock: clock) {
            client.open(baseURL: URL(filePath: "/"))
        }
        return LiveUpdates(stream: stream, policy: policy, clock: clock)
    }
}

/// 届いた活動を記録し、条件を満たすまで待てるようにする。
private actor LiveLog {
    private(set) var labels: [String] = []

    func append(_ activity: LiveUpdates.Activity) {
        labels.append(Self.label(activity))
    }

    func waitUntil(_ condition: @Sendable ([String]) -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await SciaTesting.waitUntil({ condition(labels) }, sourceLocation: sourceLocation)
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

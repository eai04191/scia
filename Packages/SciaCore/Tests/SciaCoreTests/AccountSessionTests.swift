import Foundation
import Observation
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct AccountSessionTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(
        transport: RoutedTransport,
        connector: any WebSocketConnector = StubWebSocketConnector(messages: []),
        clock: TestClock = TestClock()
    ) -> AccountSession {
        AccountSession(
            credential: TimelineModelFixtures.credential(),
            transport: transport,
            connector: connector,
            tuning: TuningStore(defaults: nil),
            clock: clock,
            now: { Self.now }
        )
    }

    /// 書き始めたときと同じく、使う人の操作として読む。
    private func applyComposeDefaults(of session: AccountSession, to model: ComposeModel) async {
        await RequestPurpose.$current.withValue(.action) {
            await session.applyComposeDefaults(to: model)
        }
    }

    nonisolated private static func unauthorized() -> (Int, Data) {
        (401, Data(#"{"error":"The access token is invalid"}"#.utf8))
    }

    /// ストリーミングが429で断られたら、RESTの自動の通信も止める。門が別々だと、断られてもRESTが送り続ける。
    @Test func streamingRefusalPausesRESTRequests() async throws {
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v2/instance" else { return (404, Data()) }
            return (200, Data(#"{"configuration":{"urls":{"streaming":"wss://streaming.example.social"}}}"#.utf8))
        }
        let connector = ScriptedConnector([.init(handshake: .fail(WebSocketHandshakeRejected(statusCode: 429, headers: ["retry-after": "30"])))])
        let session = makeSession(transport: transport, connector: connector)
        defer { session.close() }

        let subscription = session.streamingHub.subscribe(StreamingSubscription(stream: "user")) { _ in }
        defer { subscription.cancel() }

        try await waitUntil { await session.client.automaticRequestsPausedUntil() == Self.now.addingTimeInterval(30) }
    }

    /// 401を受けてトークンが無効と確かめられたら、ストリーミングと登録した一覧を止め、そのあとにアプリへ知らせる。
    @Test func invalidCredentialsStopStreamingAndLists() async throws {
        let transport = RoutedTransport { _ in Self.unauthorized() }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let list = RecordingList()
        session.register(list)
        var stoppedListsWhenNotified: Int?
        session.onCredentialsInvalid = { stoppedListsWhenNotified = list.stopCount }

        session.reportUnauthorized()
        try await waitUntil { stoppedListsWhenNotified != nil }

        #expect(stoppedListsWhenNotified == 1)
        #expect(session.streamingHub.state == .loginRequired)
        #expect(transport.requests(to: "/api/v1/accounts/verify_credentials").count == 1)
    }

    /// 一部のAPIだけが401を返しても、トークンが有効なら何も止めない。
    @Test func unauthorizedWithValidTokenStopsNothing() async throws {
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v1/accounts/verify_credentials" else { return Self.unauthorized() }
            return (200, Data())
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let list = RecordingList()
        session.register(list)
        var notified = false
        session.onCredentialsInvalid = { notified = true }

        session.reportUnauthorized()
        try await waitUntil { session.tasks.runningCount == 0 }

        #expect(transport.requests(to: "/api/v1/accounts/verify_credentials").count == 1)
        #expect(list.stopCount == 0)
        #expect(!notified)
    }

    /// セッションから作った一覧は、登録されていて、トークンが無効と分かったら止まる。止まった一覧は始め直しても読まない。
    @Test func listsMadeFromSessionStopWhenCredentialsBecomeInvalid() async throws {
        let transport = RoutedTransport { _ in Self.unauthorized() }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let model = FeedTimelineModel(feed: .home, session: session, tuning: TuningStore(defaults: nil), clock: TestClock(), now: { Self.now }) { _, _ in {} }
        var notified = false
        session.onCredentialsInvalid = { notified = true }

        session.reportUnauthorized()
        try await waitUntil { notified }
        model.start(purpose: .action)

        #expect(model.runningTaskCount == 0)
        #expect(transport.requests(to: "/api/v1/timelines/home").isEmpty)
    }

    /// 電波が戻るたびに、登録した一覧にやり直させる。
    @Test func networkRecoveryRecoversLists() async throws {
        let session = makeSession(transport: RoutedTransport { _ in (404, Data()) })
        defer { session.close() }
        let list = RecordingList()
        session.register(list)
        let network = RecoveryCounter()

        session.observeRecoveries { network.count }
        #expect(list.recoverCount == 0)
        // 観察を始めたときの回数は飛ばすので、観察が始まる前に増やした分は数えられないことがある。届くまで増やす。
        try await waitUntil {
            if list.recoverCount > 0 { return true }
            network.count += 1
            return false
        }
        let recovered = list.recoverCount
        network.count += 1
        try await waitUntil { list.recoverCount == recovered + 1 }
    }

    /// レート制限が明けたら、登録した一覧にやり直させる。
    @Test func rateLimitResumptionRecoversLists() async throws {
        let clock = TestClock()
        let session = makeSession(transport: RoutedTransport { _ in (404, Data()) }, clock: clock)
        defer { session.close() }
        let list = RecordingList()
        session.register(list)
        session.observeRecoveries { 0 }

        await session.rateLimit.pause(until: Self.now.addingTimeInterval(30))
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(list.recoverCount == 0)
        clock.advance(by: .seconds(30))

        try await waitUntil { list.recoverCount == 1 }
    }

    /// 閉じたら、申し込みが残っていてもストリーミングを切り、以後は申し込まれてもつながない。
    @Test func closingShutsDownStreaming() {
        let connector = StubWebSocketConnector(messages: [])
        let session = makeSession(transport: RoutedTransport { _ in (404, Data()) }, connector: connector)

        session.close()
        let subscription = session.streamingHub.subscribe(StreamingSubscription(stream: "user")) { _ in }
        defer { subscription.cancel() }

        #expect(session.streamingHub.state == .stopped)
        #expect(connector.requests.isEmpty)
    }

    /// 書き始めるときに、インスタンスの上限とアカウントの既定値を読んで投稿欄に反映する。反映するまで投稿できない。
    @Test func composeDefaultsAreLoadedAndApplied() async throws {
        let instance = try Data(contentsOf: try #require(Bundle.module.url(forResource: "instance_v2", withExtension: "json", subdirectory: "Fixtures")))
        let transport = RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v2/instance": (200, instance)
            case "/api/v1/preferences": (200, Data(#"{"posting:default:visibility":"unlisted","posting:default:sensitive":true,"posting:default:language":"ja","reading:expand:spoilers":true}"#.utf8))
            default: (404, Data())
            }
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        var loaded: ServerPreferences?
        session.onPreferencesLoad = { loaded = $0 }
        let model = ComposeModel(tasks: session.tasks.child(), myAccountID: "1") { _ in }
        model.text = "hello"
        #expect(!model.canPost)

        await applyComposeDefaults(of: session, to: model)

        #expect(model.canPost)
        #expect(model.visibility == .unlisted)
        #expect(model.maxMediaAttachments == 6)
        #expect(loaded?.expandsSpoilers == true)
        #expect(session.preferences == loaded)
        // 2度目は読み直さない。
        await applyComposeDefaults(of: session, to: model)
        #expect(transport.requests(to: "/api/v2/instance").count == 1)
        #expect(transport.requests(to: "/api/v1/preferences").count == 1)
    }

    /// 読めなくても既定のまま投稿でき、次に書き始めたときに読み直す。
    @Test func composeDefaultsRetryAfterFailure() async throws {
        // 送り直さない失敗にし、送り直しの待ちで止まらないようにする。
        let transport = RoutedTransport { _ in (403, Data()) }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let model = ComposeModel(tasks: session.tasks.child(), myAccountID: "1") { _ in }
        model.text = "hello"

        await applyComposeDefaults(of: session, to: model)
        #expect(model.canPost)
        #expect(session.preferences == nil)
        let firstPreferenceRequests = transport.requests(to: "/api/v1/preferences").count

        await applyComposeDefaults(of: session, to: model)
        #expect(transport.requests(to: "/api/v1/preferences").count > firstPreferenceRequests)
    }
}

@MainActor
private final class RecordingList: SessionList {
    private(set) var recoverCount = 0
    private(set) var stopCount = 0

    func recover() {
        recoverCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
@Observable
private final class RecoveryCounter {
    var count = 0
}

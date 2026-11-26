import Foundation
import Observation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct AccountSessionTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(
        transport: RoutedTransport,
        connector: any WebSocketConnector = StubWebSocketConnector(messages: []),
        clock: TestClock = TestClock()
    ) -> AccountSession {
        .testing(transport: transport, connector: connector, clock: clock, now: { Self.now })
    }

    @Test(.requestPurpose(.action)) func userDisplayDomainRetriesFailureAndCachesSuccess() async throws {
        let attempts = Mutex(0)
        let body = try Data(contentsOf: try #require(Bundle.module.url(forResource: "instance_account_domain", withExtension: "json", subdirectory: "Fixtures")))
        let transport = RoutedTransport { _ in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt == 1 ? (500, Data()) : (200, body)
        }
        let settings = AppSettings(defaults: TestScratch.defaults("domainSession")).forAccount("@alice@web.example.com")
        let session = AccountSession.testing(transport: transport, settings: settings)
        defer { session.close() }
        #expect(await session.loadUserDisplayDomain() == nil)
        #expect(session.settings.userDisplayKey(acct: "alice") == nil)
        #expect(await session.loadUserDisplayDomain() == "example.com")
        #expect(await session.loadUserDisplayDomain() == "example.com")
        #expect(session.settings.userDisplayKey(acct: "alice") == "alice@example.com")
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test(.requestPurpose(.action)) func userDisplayLookupRejectsSimilarAccount() async throws {
        let body = try accountBody("Similar name")
        let transport = RoutedTransport { _ in
            (200, Data("{\"accounts\":[".utf8) + body + Data("]}".utf8))
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        await #expect(throws: ProfileNotFound.self) {
            try await session.resolveUserDisplayAccount(acct: "deleted@remote.example")
        }
    }

    @Test(.requestPurpose(.action)) func userDisplayLookupMatchesCanonicalLocalHandle() async throws {
        let account = try accountBody("Local Bob")
        let local = Data(String(decoding: account, as: UTF8.self).replacingOccurrences(of: "bob@remote.example", with: "bob").utf8)
        let domain = try Data(contentsOf: try #require(Bundle.module.url(forResource: "instance_account_domain", withExtension: "json", subdirectory: "Fixtures")))
        let transport = RoutedTransport { request in
            request.url?.path == "/api/v2/instance" ? (200, domain) : (200, Data("{\"accounts\":[".utf8) + local + Data("]}".utf8))
        }
        let settings = AppSettings(defaults: TestScratch.defaults("localLookup")).forAccount("@me@web.example.com")
        let session = AccountSession.testing(transport: transport, settings: settings)
        defer { session.close() }
        #expect(try await session.resolveUserDisplayAccount(acct: "BOB@EXAMPLE.COM").acct == "bob")
        await #expect(throws: ProfileNotFound.self) {
            try await session.resolveUserDisplayAccount(acct: "bob@web.example.com")
        }
    }

    @Test func supersededUserDisplayDoesNotOpenAfterDomainArrives() async throws {
        let domain = try Data(contentsOf: try #require(Bundle.module.url(forResource: "instance_account_domain", withExtension: "json", subdirectory: "Fixtures")))
        let gate = Gate()
        let transport = RoutedTransport { _ in try await gate.wait(); return (200, domain) }
        let settings = AppSettings(defaults: TestScratch.defaults("slowDomain")).forAccount("@me@web.example.com")
        let session = AccountSession.testing(transport: transport, settings: settings)
        defer { session.close() }
        let lookup = LatestLookup(clock: TestClock(), slowAfter: { nil })
        let local = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
        let remote = Account(id: "2", username: "bob", acct: "bob@remote.example", displayName: "Bob", avatar: nil)
        var opened: [String] = []
        lookup.start(.action, { try await session.prepareUserDisplay(local) }, isStillWanted: { true }) { result in
            if case .success(let account) = result { opened.append(account.acct) }
        }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(lookup.isWaiting)
        lookup.start(.action, { try await session.prepareUserDisplay(remote) }, isStillWanted: { true }) { result in
            if case .success(let account) = result { opened.append(account.acct) }
        }
        gate.open()
        try await waitUntil { !lookup.isWaiting && gate.waiterCount == 0 }
        #expect(opened == ["bob@remote.example"])
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

    /// fixtureのアカウント（IDは2）を、表示名を`name`に替えて返す。`withSource`なら、プロフィールの保存の応答と同じく`source`も付ける。
    private func accountBody(_ name: String, withSource: Bool = false) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "account", withExtension: "json", subdirectory: "Fixtures"))
        var text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "Bob :blobcat:", with: name)
        if withSource {
            text = text.replacingOccurrences(of: #""id": "2","#, with: #""id": "2", "source": {"note": "", "fields": []},"#)
        }
        return Data(text.utf8)
    }

    /// セッションのクライアントで受け取ったアカウントは、応答を受け取った側が続けて読むときには、もうセッションの`AccountCache`がキャッシュしている。
    /// 受け取ったものでプロフィールを開くとき、キャッシュしている古いもので置き換えないため。
    @Test func accountsReceivedByClientAreInCacheWhenResponseReturns() async throws {
        let body = try accountBody("Fresh")
        let transport = RoutedTransport { _ in (200, body) }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let client = session.client
        #expect(session.accounts.account("2") == nil)

        let loaded = try await RequestPurpose.$current.withValue(.action) { try await client.account("2") }

        #expect(session.accounts.account("2") == loaded)
        #expect(session.accounts.latest(of: loaded).displayName == "Fresh")
    }

    /// プロフィールを保存している間に読み始めた読み込みが保存の前の内容を返しても、保存の応答のほうを新しいものとしてキャッシュする。
    @Test func savedProfileWinsOverReadStartedWhileSaving() async throws {
        let oldBody = try accountBody("Old")
        let savedBody = try accountBody("Saved", withSource: true)
        let gate = Gate()
        let transport = RoutedTransport { request in
            guard request.httpMethod == "PATCH" else { return (200, oldBody) }
            try await gate.wait()
            return (200, savedBody)
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let client = session.client
        let old = try MastodonDecoder.make().decode(Account.self, from: oldBody)
        var draft = ProfileDraft(source: ProfileSource(account: old, note: "", fields: []))
        draft.displayName = "Saved"
        let submitted = draft

        let save = Task { try await RequestPurpose.$current.withValue(.action) { try await client.updateProfile(submitted) } }
        try await waitUntil { gate.waiterCount == 1 }
        _ = try await RequestPurpose.$current.withValue(.action) { try await client.account("2") }
        #expect(session.accounts.account("2")?.displayName == "Old")
        gate.open()
        let saved = try await save.value

        #expect(session.accounts.latest(of: saved.account).displayName == "Saved")
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

    /// REST APIの401を受けたら、ストリーミングと登録したタイムラインを止め、そのあとにアプリへ知らせる。
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
    }

    /// セッションのクライアントで受けたREST APIの401は、呼び出し側が拾わなくても、セッションがトークンを無効として止め、アプリへ知らせる。
    /// 呼び出し側に401が届く前に、知らせ終えている。
    @Test func clientUnauthorizedInvalidatesSessionWithoutCaller() async throws {
        let session = makeSession(transport: RoutedTransport { _ in Self.unauthorized() })
        defer { session.close() }
        let list = RecordingList()
        session.register(list)
        var notified = 0
        session.onCredentialsInvalid = { notified += 1 }

        let error = await #expect(throws: MastodonAPIError.self) {
            try await RequestPurpose.$current.withValue(.action) { try await session.client.bookmarks(maxID: nil, limit: 1) }
        }

        #expect(error?.isUnauthorized == true)
        #expect(notified == 1)
        #expect(list.stopCount == 1)
        #expect(session.streamingHub.state == .loginRequired)
    }

    /// 閉じたあと（ログアウトやアカウントの切り替えのあと）に届いた401では、ログインし直しを促さない。
    @Test func unauthorizedAfterCloseIsIgnored() async throws {
        let gate = Gate()
        let session = makeSession(transport: RoutedTransport { _ in
            try await gate.wait()
            return Self.unauthorized()
        })
        var notified = false
        session.onCredentialsInvalid = { notified = true }
        let client = session.client
        let request = Task(.action) { try? await client.bookmarks(maxID: nil, limit: 1) }
        try await waitUntil { gate.waiterCount == 1 }

        session.close()
        gate.open()
        _ = await request.value

        #expect(!notified)
        #expect(session.authorization.state == .valid)
    }

    /// `saveReadPositions()`は、登録した一覧の既読位置を保存し終えるまで待つ。
    @Test func saveReadPositionsWaitsForRegisteredLists() async throws {
        let session = makeSession(transport: RoutedTransport { _ in (404, Data()) })
        defer { session.close() }
        let first = RecordingList()
        let second = RecordingList()
        session.register(first)
        session.register(second)

        await session.saveReadPositions()

        #expect(first.savedReadPositionCount == 1)
        #expect(second.savedReadPositionCount == 1)
    }

    /// REST APIの401では、確かめずに止める。MastodonのREST APIは、トークンが無効なときだけ401を返すため。
    @Test func restUnauthorizedStopsWithoutVerification() async throws {
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

        #expect(notified)
        #expect(list.stopCount == 1)
        #expect(transport.requests(to: "/api/v1/accounts/verify_credentials").isEmpty)
    }

    /// ストリーミングの401は、消したリストなどで有効なトークンでも返るので、確かめて有効なら何も止めない。
    @Test func streamingUnauthorizedWithValidTokenStopsNothing() async throws {
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

        let ongoingTasks = session.tasks.runningCount
        session.reportStreamingUnauthorized()
        try await waitUntil { session.tasks.runningCount == ongoingTasks }

        #expect(transport.requests(to: "/api/v1/accounts/verify_credentials").count == 1)
        #expect(list.stopCount == 0)
        #expect(!notified)
    }

    /// セッションから作ったタイムラインは、登録されていて、トークンが無効と分かったら止まる。止まったタイムラインは始め直しても読まない。
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

    /// トークンが無効と分かったあとにセッションから作ったタイムライン（あとから開いたハッシュタグやリスト）も、止まっていて、始めても読まない。
    @Test func listsMadeAfterCredentialsBecameInvalidAreStopped() async throws {
        let transport = RoutedTransport { _ in Self.unauthorized() }
        let session = makeSession(transport: transport)
        defer { session.close() }
        var notified = false
        session.onCredentialsInvalid = { notified = true }
        session.reportUnauthorized()
        try await waitUntil { notified }

        let model = FeedTimelineModel(feed: .hashtag(name: "scia"), session: session, tuning: TuningStore(defaults: nil), clock: TestClock(), now: { Self.now }) { _, _ in {} }
        model.start(purpose: .action)

        #expect(model.runningTaskCount == 0)
        #expect(transport.requests(to: "/api/v1/timelines/tag/scia").isEmpty, "トークンが無効と分かったあとに作ったタイムラインが読み込みました")
    }

    /// 電波が戻るたびに、登録したタイムラインにやり直させる。
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

    /// レート制限が明けたら、登録したタイムラインにやり直させる。
    @Test func rateLimitResumptionRecoversLists() async throws {
        let clock = TestClock()
        let session = makeSession(transport: RoutedTransport { _ in (404, Data()) }, clock: clock)
        defer { session.close() }
        let list = RecordingList()
        session.register(list)
        session.observeRecoveries { 0 }

        await session.rateLimit.pause(until: Self.now.addingTimeInterval(30))
        try await waitUntil { clock.sleeperCount(remaining: .seconds(30)) >= 1 }
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
        let model = ComposeModel(tasks: session.tasks.child(), home: ComposeAccount(id: session.credential.id, myAccountID: "1", media: .unavailable) { .stub(for: $0) })
        model.text = "hello"
        #expect(!model.canPost)

        await applyComposeDefaults(of: session, to: model)

        #expect(model.canPost)
        #expect(model.visibility == .unlisted)
        #expect(model.maxMediaAttachments == 6)
        #expect(loaded?.expandsSpoilers == true)
        #expect(session.preferences == loaded)
        // 2度目は再読み込みしない。
        await applyComposeDefaults(of: session, to: model)
        #expect(transport.requests(to: "/api/v2/instance").count == 1)
        #expect(transport.requests(to: "/api/v1/preferences").count == 1)
    }

    /// 起動のときに読み始めた上限と既定値がまだ届いていなければ、書き始めたときは再送せずにそれを待つ。
    @Test func composeDefaultsWaitForLoadsAlreadyRunning() async throws {
        let instance = try Data(contentsOf: try #require(Bundle.module.url(forResource: "instance_v2", withExtension: "json", subdirectory: "Fixtures")))
        let gate = Gate()
        let transport = RoutedTransport { request in
            try await gate.wait()
            return switch request.url?.path() {
            case "/api/v2/instance": (200, instance)
            case "/api/v1/preferences": (200, Data(#"{"posting:default:visibility":"unlisted","posting:default:sensitive":false,"posting:default:language":null,"reading:expand:spoilers":false}"#.utf8))
            default: (404, Data())
            }
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let model = ComposeModel(tasks: session.tasks.child(), home: ComposeAccount(id: session.credential.id, myAccountID: "1", media: .unavailable) { .stub(for: $0) })
        model.text = "hello"

        session.preloadComposeDefaults()
        try await waitUntil { gate.waiterCount >= 2 }
        let applying = Task { await applyComposeDefaults(of: session, to: model) }
        try await waitUntil { session.composeDefaultsWaiterCount >= 2 }
        #expect(!model.canPost)

        gate.open()
        await applying.value
        #expect(model.canPost)
        #expect(model.visibility == .unlisted)
        #expect(model.maxMediaAttachments == 6)
        #expect(transport.requests(to: "/api/v2/instance").count == 1)
        #expect(transport.requests(to: "/api/v1/preferences").count == 1)
    }

    /// 待っていた読み込みが失敗したら、書き始めた側が自分で再読み込みする。起動のときの読み込みは、レート制限で止められている間は送られないため。
    @Test func composeDefaultsReloadWhenAwaitedLoadFails() async throws {
        let instance = try Data(contentsOf: try #require(Bundle.module.url(forResource: "instance_v2", withExtension: "json", subdirectory: "Fixtures")))
        let gate = Gate()
        let failsNext = Mutex(true)
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v2/instance" else { return (403, Data()) }
            if failsNext.withLock({ fails in defer { fails = false }; return fails }) {
                try await gate.wait()
                return (403, Data())
            }
            return (200, instance)
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let model = ComposeModel(tasks: session.tasks.child(), home: ComposeAccount(id: session.credential.id, myAccountID: "1", media: .unavailable) { .stub(for: $0) })

        session.preloadComposeDefaults()
        try await waitUntil { gate.waiterCount >= 1 }
        let applying = Task { await applyComposeDefaults(of: session, to: model) }
        try await waitUntil { session.composeDefaultsWaiterCount >= 1 }

        gate.open()
        await applying.value
        #expect(model.maxMediaAttachments == 6)
        #expect(transport.requests(to: "/api/v2/instance").count == 2)
    }

    /// 読めなくても既定のまま投稿でき、次に書き始めたときに再読み込みする。
    @Test func composeDefaultsRetryAfterFailure() async throws {
        // 再送しない失敗にし、再送の待ちで止まらないようにする。
        let transport = RoutedTransport { _ in (403, Data()) }
        let session = makeSession(transport: transport)
        defer { session.close() }
        let model = ComposeModel(tasks: session.tasks.child(), home: ComposeAccount(id: session.credential.id, myAccountID: "1", media: .unavailable) { .stub(for: $0) })
        model.text = "hello"

        await applyComposeDefaults(of: session, to: model)
        #expect(model.canPost)
        #expect(session.preferences == nil)
        let firstPreferenceRequests = transport.requests(to: "/api/v1/preferences").count

        await applyComposeDefaults(of: session, to: model)
        #expect(transport.requests(to: "/api/v1/preferences").count > firstPreferenceRequests)
    }

    /// 起動時の設定の読み込みが遅れ、その間に既定を保存しても、遅れて届いた古い応答で、保存したあとの設定を上書きせず、投稿欄にも配らない。
    @Test func staleStartupLoadDoesNotUndoSavedPostingDefault() async throws {
        let startupResponse = Gate()
        let reads = Mutex(0)
        let transport = RoutedTransport { request in
            if request.httpMethod == "PATCH" { return (200, Data("{}".utf8)) }
            let count = reads.withLock { count in
                count += 1
                return count
            }
            if count == 1 { try await startupResponse.wait() }
            let visibility = count <= 2 ? "public" : "private"
            return (200, Data(#"{"posting:default:visibility":"\#(visibility)"}"#.utf8))
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        var delivered: [Status.Visibility] = []
        session.onPreferencesLoad = { delivered.append($0.defaultVisibility) }

        let startup = Task { await RequestPurpose.$current.withValue(.action) { await session.loadPreferences() } }
        try await waitUntil { startupResponse.waiterCount == 1 }
        try await RequestPurpose.$current.withValue(.action) {
            _ = try await session.reloadPreferences()
            _ = try await session.updatePostingDefault(.visibility(.private))
        }
        startupResponse.open()
        let loaded = await startup.value

        #expect(loaded?.defaultVisibility == .private)
        #expect(session.preferences?.defaultVisibility == .private)
        #expect(delivered == [.public, .private])
    }

    /// 既定を保存する前に始めた設定の再読み込みが、保存のあとに届いても、保存したあとの設定を古い値で上書きせず、投稿欄にも配らない。
    @Test func staleReloadDoesNotUndoSavedPostingDefault() async throws {
        let staleResponse = Gate()
        let reads = Mutex(0)
        let transport = RoutedTransport { request in
            if request.httpMethod == "PATCH" { return (200, Data("{}".utf8)) }
            let count = reads.withLock { count in
                count += 1
                return count
            }
            if count == 1 { try await staleResponse.wait() }
            let visibility = count == 1 ? "public" : "private"
            return (200, Data(#"{"posting:default:visibility":"\#(visibility)"}"#.utf8))
        }
        let session = makeSession(transport: transport)
        defer { session.close() }
        var delivered: [Status.Visibility] = []
        session.onPreferencesLoad = { delivered.append($0.defaultVisibility) }

        let reload = Task { try await RequestPurpose.$current.withValue(.action) { try await session.reloadPreferences() } }
        try await waitUntil { staleResponse.waiterCount == 1 }
        try await RequestPurpose.$current.withValue(.action) { _ = try await session.updatePostingDefault(.visibility(.private)) }
        staleResponse.open()
        let reloaded = try await reload.value

        #expect(reloaded.defaultVisibility == .private)
        #expect(session.preferences?.defaultVisibility == .private)
        #expect(delivered == [.private])
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

    private(set) var savedReadPositionCount = 0

    func saveReadPosition() async {
        savedReadPositionCount += 1
    }
}

@MainActor
@Observable
private final class RecoveryCounter {
    var count = 0
}

import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 保留中の通知の一覧と、通知のフィルタリングの設定と、受け入れた通知の取り込み。決まりはdocs/notification-filter.mdにある。
@MainActor
@Suite(.serialized)
struct NotificationRequestsModelTests {
    nonisolated private static let account = #"{"id":"2","username":"bob","acct":"bob@remote.example","display_name":"Bob","avatar":"https://example.social/avatars/bob.png","avatar_static":"https://example.social/avatars/bob.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://remote.example/@bob","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#

    nonisolated private static func requestsBody(_ ids: [String]) -> Data {
        let items = ids.map { #"{"id":"\#($0)","created_at":"2026-10-17T14:45:41.171Z","updated_at":"2026-10-17T14:45:41.171Z","notifications_count":"2","account":\#(account)}"# }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    nonisolated private static func policyBody(notFollowing: String = "accept", newAccounts: String = "accept", pending: Int = 0) -> Data {
        Data(#"{"for_not_following":"\#(notFollowing)","for_not_followers":"accept","for_new_accounts":"\#(newAccounts)","for_private_mentions":"filter","for_limited_accounts":"filter","summary":{"pending_requests_count":\#(pending),"pending_notifications_count":\#(pending)}}"#.utf8)
    }

    private func client(_ transport: RoutedTransport) -> MastodonClient {
        MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)
    }

    private func makeRequests(_ transport: RoutedTransport) -> (NotificationRequestsModel, RecordingTimelineDisplay) {
        let model = NotificationRequestsModel(client: client(transport), tasks: TaskScope()) {}
        let display = RecordingTimelineDisplay()
        model.display = display
        return (model, display)
    }

    private func requestIDs(_ display: RecordingTimelineDisplay) -> [String] {
        display.entries.compactMap { entry in
            if case .notificationRequest(let request) = entry { request.id } else { nil }
        }
    }

    // MARK: - 保留中の通知の一覧

    /// 受け入れたら、行を閉じる動きで消し、済んだことを知らせる。
    @Test func acceptingRemovesTheRowWithAnimation() async throws {
        let transport = RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v1/notifications/requests": (200, Self.requestsBody(["10", "9"]))
            default: (200, Data("{}".utf8))
            }
        }
        let (model, display) = makeRequests(transport)
        let answered = Mutex<[NotificationRequestDecision]>([])
        model.onAnswered = { decision in answered.withLock { $0.append(decision) } }
        await model.start(purpose: .action)?.value
        #expect(requestIDs(display) == ["10", "9"])
        #expect(display.entriesCalls.last?.animatesRemoval == false)

        let request = try #require(model.requests.first)
        await model.answer(request, .accept)?.value

        #expect(requestIDs(display) == ["9"])
        #expect(display.entriesCalls.last?.animatesRemoval == true)
        #expect(model.isAnswered("10"))
        #expect(answered.withLock { $0 } == [.accept])
        #expect(transport.requests(to: "/api/v1/notifications/requests/10/accept").count == 1)
    }

    /// 送れなかったら行を残し、理由を知らせる。
    @Test func failedAnswerKeepsTheRow() async throws {
        let transport = RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v1/notifications/requests": (200, Self.requestsBody(["10"]))
            default: (422, Data(#"{"error":"だめ"}"#.utf8))
            }
        }
        let (model, display) = makeRequests(transport)
        let failures = Mutex<[NotificationRequestDecision]>([])
        model.onFailure = { decision, _ in failures.withLock { $0.append(decision) } }
        await model.start(purpose: .action)?.value

        await model.answer(try #require(model.requests.first), .dismiss)?.value

        #expect(requestIDs(display) == ["10"])
        #expect(!model.isAnswered("10"))
        #expect(failures.withLock { $0 } == [.dismiss])
    }

    /// 404は、もうないことなので、済んだときと同じく消す。
    @Test func missingRequestIsRemoved() async throws {
        let transport = RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v1/notifications/requests": (200, Self.requestsBody(["10"]))
            default: (404, Data(#"{"error":"Record not found"}"#.utf8))
            }
        }
        let (model, display) = makeRequests(transport)
        await model.start(purpose: .action)?.value

        await model.answer(try #require(model.requests.first), .dismiss)?.value

        #expect(requestIDs(display).isEmpty)
    }

    /// 送っている途中のまとまりには重ねて送らず、答える前に送った読み込みの応答でも、答えた行を戻さない。
    @Test func answeringTwiceSendsOnceAndStaleLoadDoesNotRestoreTheRow() async throws {
        let gate = Gate()
        let transport = RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v1/notifications/requests": return (200, Self.requestsBody(["10", "9"]))
            default:
                try await gate.wait()
                return (200, Data("{}".utf8))
            }
        }
        let (model, display) = makeRequests(transport)
        await model.start(purpose: .action)?.value
        let request = try #require(model.requests.first)

        let first = model.answer(request, .accept)
        #expect(model.answer(request, .accept) == nil)
        gate.open()
        await first?.value
        await model.refresh()

        #expect(requestIDs(display) == ["9"])
        #expect(transport.requests(to: "/api/v1/notifications/requests/10/accept").count == 1)
    }

    // MARK: - その人からの通知

    nonisolated private static let accountNotificationsBody = Data(#"[{"id":"20","type":"mention","created_at":"2026-10-13T03:26:00.000Z","account":\#(account)},{"id":"19","type":"follow","created_at":"2026-10-13T03:20:00.000Z","account":\#(account)}]"#.utf8)

    /// その人からの通知を、`account_id`で絞って読んで並べる。
    @Test func accountNotificationsLoadNotificationsOfTheAccount() async throws {
        let transport = RoutedTransport { request in
            request.url?.path() == "/api/v1/notifications" ? (200, Self.accountNotificationsBody) : (404, Data("{}".utf8))
        }
        let model = AccountNotificationsModel(accountID: "2", client: client(transport), tasks: TaskScope()) {}
        let display = RecordingTimelineDisplay()
        model.display = display

        await model.start(purpose: .action)?.value

        #expect(display.contentState == .loaded)
        #expect(display.entries.map(\.id) == [.notification("20"), .notification("19")])
        let query = try #require(transport.requests(to: "/api/v1/notifications").first?.url?.query())
        #expect(query.contains("account_id=2"))
    }

    /// 通知の一覧と同じく、ブロックした相手の通知を閉じる動きで除く。
    @Test func accountNotificationsDropBlockedAccount() async throws {
        let transport = RoutedTransport { _ in (200, Self.accountNotificationsBody) }
        let model = AccountNotificationsModel(accountID: "2", client: client(transport), tasks: TaskScope()) {}
        let display = RecordingTimelineDisplay()
        model.display = display
        await model.start(purpose: .action)?.value

        model.setAccount("2", excluded: true)

        #expect(display.entries.isEmpty)
        #expect(display.entriesCalls.last?.animatesRemoval == true)
    }

    // MARK: - 通知のフィルタリングの設定

    /// 選んだ値はすぐ入れ、変えた項目だけを送る。
    @Test func selectingAppliesAtOnceAndSendsTheItem() async throws {
        let gate = Gate()
        let transport = RoutedTransport { request in
            if request.httpMethod == "PATCH" {
                try await gate.wait()
                return (200, Self.policyBody(newAccounts: "filter", pending: 4))
            }
            return (200, Self.policyBody(pending: 3))
        }
        let model = NotificationPolicyModel(client: client(transport), tasks: TaskScope()) {}
        await model.reload(purpose: .action)?.value
        #expect(model.pendingRequestsCount == 3)

        let sending = model.select(.filter, for: .newAccounts)
        #expect(model.policy?[.newAccounts] == .filter)
        gate.open()
        await sending?.value

        #expect(model.policy?[.newAccounts] == .filter)
        #expect(model.pendingRequestsCount == 4)
        let body = try #require(transport.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == "for_new_accounts=filter")
    }

    /// 送っている間に選び直したら、先の応答で選び直した値を戻さず、最後に選んだ値を送る。
    @Test func lastSelectionWins() async throws {
        let gate = Gate()
        let sent = Mutex<[String]>([])
        let transport = RoutedTransport { request in
            guard request.httpMethod == "PATCH" else { return (200, Self.policyBody()) }
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let isFirst = sent.withLock { sent in
                sent.append(form)
                return sent.count == 1
            }
            if isFirst {
                try await gate.wait()
                return (200, Self.policyBody(notFollowing: "filter"))
            }
            return (200, Self.policyBody(notFollowing: "drop"))
        }
        let model = NotificationPolicyModel(client: client(transport), tasks: TaskScope()) {}
        await model.reload(purpose: .action)?.value

        model.select(.filter, for: .notFollowing)
        try await waitUntil { sent.withLock { $0.count } == 1 }
        let last = model.select(.drop, for: .notFollowing)
        gate.open()
        await last?.value

        #expect(model.policy?[.notFollowing] == .drop)
        #expect(sent.withLock { $0 } == ["for_not_following=filter", "for_not_following=drop"])
    }

    /// 選ぶ前に始めた読み込みの応答が、選んで送れた値を戻さない。人数は入れる。
    @Test func staleReloadDoesNotUndoSelection() async throws {
        let staleGET = Gate()
        let gets = Mutex(0)
        let transport = RoutedTransport { request in
            if request.httpMethod == "PATCH" { return (200, Self.policyBody(newAccounts: "filter", pending: 1)) }
            let count = gets.withLock { gets in
                gets += 1
                return gets
            }
            if count == 2 { try await staleGET.wait() }
            return (200, Self.policyBody(pending: count == 2 ? 5 : 0))
        }
        let model = NotificationPolicyModel(client: client(transport), tasks: TaskScope()) {}
        await model.reload(purpose: .action)?.value
        let reload = model.reload(purpose: .action)
        try await waitUntil { staleGET.waiterCount == 1 }

        await model.select(.filter, for: .newAccounts)?.value
        staleGET.open()
        await reload?.value

        #expect(model.policy?[.newAccounts] == .filter)
        #expect(model.pendingRequestsCount == 5)
    }

    /// 通知のフィルタリングのAPIがないサーバーでは、使えないとして入口を隠させ、失敗の理由は出さない。
    @Test func unsupportedPolicyIsReportedWithoutFailure() async throws {
        let transport = RoutedTransport { _ in (404, Data("<html>Not Found</html>".utf8)) }
        let model = NotificationPolicyModel(client: client(transport), tasks: TaskScope()) {}
        #expect(model.isSupported)

        await model.reload(purpose: .action)?.value

        #expect(!model.isSupported)
        #expect(model.loadFailure == nil)
    }

    /// 送れなかったら、サーバーに残っている値に戻して知らせる。
    @Test func failedSelectionReverts() async throws {
        let transport = RoutedTransport { request in
            request.httpMethod == "PATCH" ? (500, Data("{}".utf8)) : (200, Self.policyBody())
        }
        let model = NotificationPolicyModel(client: client(transport), tasks: TaskScope()) {}
        let failures = Mutex(0)
        model.onFailure = { _ in failures.withLock { $0 += 1 } }
        await model.reload(purpose: .action)?.value

        await model.select(.drop, for: .newAccounts)?.value

        #expect(model.policy?[.newAccounts] == .accept)
        #expect(failures.withLock { $0 } == 1)
    }

    /// 知らない値は選べず、送らない。
    @Test func unknownValueCannotBeSelected() async throws {
        let transport = RoutedTransport { _ in (200, Self.policyBody()) }
        let model = NotificationPolicyModel(client: client(transport), tasks: TaskScope()) {}
        await model.reload(purpose: .action)?.value

        #expect(model.select(.unknown("quarantine"), for: .newAccounts) == nil)
        #expect(transport.requests.allSatisfy { $0.httpMethod != "PATCH" })
    }

    // MARK: - 受け入れた通知の取り込み

    nonisolated private static func notificationsTransport(merged: Bool = false) throws -> RoutedTransport {
        let url = try #require(Bundle.module.url(forResource: "grouped_notifications", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        return RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v2/notifications":
                let query = request.url?.query() ?? ""
                if query.contains("min_id") || query.contains("since_id") {
                    return (200, Data(#"{"accounts":[],"statuses":[],"notification_groups":[]}"#.utf8))
                }
                return (200, fixture)
            case "/api/v1/notifications/requests/merged":
                return (200, Data(#"{"merged":\#(merged)}"#.utf8))
            default:
                return (200, Data("{}".utf8))
            }
        }
    }

    private func makeNotifications(_ transport: RoutedTransport, hub: StreamingHub, clock: TestClock) -> (NotificationsModel, RecordingTimelineDisplay) {
        let model = NotificationsModel(
            client: client(transport),
            streamingHub: hub,
            tuning: TuningStore(defaults: nil),
            clock: clock,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            backgroundTime: BackgroundTimeRecorder().request,
            tasks: TaskScope()
        ) {}
        let display = RecordingTimelineDisplay()
        model.display = display
        return (model, display)
    }

    /// 最新のページを読む読み込み（新しい側を区切らないもの）の数。
    private func latestPageLoads(_ transport: RoutedTransport) -> Int {
        transport.requests(to: "/api/v2/notifications").filter { request in
            let query = request.url?.query() ?? ""
            return !query.contains("min_id") && !query.contains("since_id") && !query.contains("max_id")
        }.count
    }

    /// ストリーミングで取り込みの知らせが届いたら、一番上から読み直して置き換える。
    @Test func mergedEventReloadsFromTheTop() async throws {
        let firstMessage = Gate()
        let connector = ScriptedConnector([.init(messages: [#"{"stream":["user"],"event":"notifications_merged"}"#], firstMessageGate: firstMessage)])
        let transport = try Self.notificationsTransport()
        let (model, display) = makeNotifications(transport, hub: TimelineModelFixtures.hub(connector), clock: TestClock())
        defer { model.stop() }
        let reloads = Mutex(0)
        model.onReload = { reloads.withLock { $0 += 1 } }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && model.runningTaskCount == 0 }
        #expect(latestPageLoads(transport) == 1)
        display.anchorID = display.entries.last?.id
        firstMessage.open()

        try await waitUntil { latestPageLoads(transport) == 2 && model.runningTaskCount == 0 }
        #expect(reloads.withLock { $0 } == 2)
        // 読んでいた位置は保たず、一番上に置く。
        let call = try #require(display.entriesCalls.last)
        #expect(call.topID == call.entries.first?.id)
    }

    /// 古いページを読んでいる間に取り込みの知らせが届いたら、読み終えてから一番上から読み直す。
    @Test func mergedEventDuringOlderLoadReloadsAfterIt() async throws {
        let url = try #require(Bundle.module.url(forResource: "grouped_notifications", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        let older = Gate()
        let event = Gate()
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v2/notifications" else { return (200, Data("{}".utf8)) }
            let query = request.url?.query() ?? ""
            if query.contains("max_id") { try await older.wait() }
            if query.contains("max_id") || query.contains("since_id") || query.contains("min_id") {
                return (200, Data(#"{"accounts":[],"statuses":[],"notification_groups":[]}"#.utf8))
            }
            return (200, fixture)
        }
        let hub = TimelineModelFixtures.hub(ScriptedConnector([.init(messages: [#"{"stream":["user"],"event":"notifications_merged"}"#], firstMessageGate: event)]))
        let (model, display) = makeNotifications(transport, hub: hub, clock: TestClock())
        defer { model.stop() }
        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && hub.isConnected && model.runningTaskCount == 0 }
        model.approachEnd()
        try await waitUntil { older.waiterCount == 1 }

        event.open()
        try await waitUntil { model.runningTaskCount == 1 }
        #expect(latestPageLoads(transport) == 1)
        older.open()

        try await waitUntil { latestPageLoads(transport) == 2 && model.runningTaskCount == 0 }
    }

    /// つながっている間に受け入れ、知らせを受け取る前に切れたら、つなぎ直したときに問い合わせて読み直す。
    @Test func acceptThenReconnectChecksMergedState() async throws {
        let disconnect = Gate()
        let transport = try Self.notificationsTransport(merged: true)
        let connector = ScriptedConnector([.init(afterMessages: .drop, dropGate: disconnect), .init()])
        let hub = TimelineModelFixtures.hub(connector)
        let (model, display) = makeNotifications(transport, hub: hub, clock: TestClock())
        defer { model.stop() }
        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && hub.isConnected && model.runningTaskCount == 0 }
        model.didAcceptRequest()
        #expect(transport.requests(to: "/api/v1/notifications/requests/merged").isEmpty)

        disconnect.open()
        try await waitUntil { !hub.isConnected }
        hub.recover()

        try await waitUntil { latestPageLoads(transport) == 2 && model.runningTaskCount == 0 }
        #expect(transport.requests(to: "/api/v1/notifications/requests/merged").count == 1)
    }

    /// つながっていないときは、受け入れたあとに取り込みを問い合わせ、済んでいたら読み直す。
    @Test func acceptWhileOfflineChecksMergedState() async throws {
        let connector = ScriptedConnector(Array(repeating: .init(handshake: .fail(URLError(.cannotConnectToHost))), count: 10))
        let clock = TestClock()
        let transport = try Self.notificationsTransport(merged: true)
        let (model, display) = makeNotifications(transport, hub: TimelineModelFixtures.hub(connector, clock: clock), clock: clock)
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded }
        model.didAcceptRequest()
        try await waitUntil { clock.sleeperCount(dueWithin: .seconds(2)) == 1 }
        #expect(transport.requests(to: "/api/v1/notifications/requests/merged").isEmpty)

        clock.advance(by: .seconds(2))

        try await waitUntil { latestPageLoads(transport) == 2 }
        #expect(transport.requests(to: "/api/v1/notifications/requests/merged").count == 1)
    }
}

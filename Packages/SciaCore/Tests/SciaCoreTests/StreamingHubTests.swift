import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct StreamingHubTests {
    private static let reconnect = ReconnectingStream.Policy(
        initialRetryDelay: .milliseconds(10),
        maxRetryDelay: .milliseconds(40),
        pingInterval: .seconds(3600),
        pingTimeout: .seconds(5)
    )
    /// 待つ時間はテストごとの手で進める時計で数えるので、進めない限りポーリングや知らせは起きない。切断を確かめないテストでは、念のため長くする。
    private static let live = LiveUpdates.Policy(pollingInterval: .seconds(3600), outageNoticeDelay: .seconds(3600))
    private static let outage = LiveUpdates.Policy(pollingInterval: .milliseconds(15), outageNoticeDelay: .milliseconds(30))
    private static let subscribeUser = #"{"stream":"user","type":"subscribe"}"#
    private static let publicStream = StreamingSubscription(stream: "public")

    private static func delete(_ id: String, stream: String = #"["user"]"#) -> String {
        #"{"stream":\#(stream),"event":"delete","payload":"\#(id)"}"#
    }

    @Test func sharesOneConnectionAndOneSubscription() async throws {
        let connector = ScriptedConnector([.init(messages: [Self.delete("1")])])
        let hub = makeHub(connector)
        let home = Recorder()
        let notifications = Recorder()

        let homeSubscription = hub.subscribe(.user, home.record)
        let notificationsSubscription = hub.subscribe(.user, notifications.record)
        try await waitUntil { home.labels.contains("delete 1") && notifications.labels.contains("delete 1") }

        #expect(connector.connectCount == 1)
        #expect(connector.sent == [[Self.subscribeUser]])
        #expect(home.labels == ["connected", "delete 1"])
        #expect(notifications.labels == ["connected", "delete 1"])
        #expect(hub.subscriptions == [.user])
        #expect(hub.state == .connected)
        homeSubscription.cancel()
        notificationsSubscription.cancel()
    }

    @Test func deliversEventsOnlyToTheirStream() async throws {
        let connector = ScriptedConnector([.init(messages: [Self.delete("1"), Self.delete("2", stream: #"["public"]"#)])])
        let hub = makeHub(connector)
        let user = Recorder()
        let publicTimeline = Recorder()

        let userSubscription = hub.subscribe(.user, user.record)
        let publicSubscription = hub.subscribe(Self.publicStream, publicTimeline.record)
        try await waitUntil { user.labels.contains("delete 1") && publicTimeline.labels.contains("delete 2") }

        #expect(user.labels == ["connected", "delete 1"])
        #expect(publicTimeline.labels == ["connected", "delete 2"])
        #expect(connector.sent == [[Self.subscribeUser, #"{"stream":"public","type":"subscribe"}"#]])
        userSubscription.cancel()
        publicSubscription.cancel()
    }

    @Test func resubscribesAfterReconnecting() async throws {
        let connector = ScriptedConnector([.init(messages: [Self.delete("1")], afterMessages: .drop), .init(messages: [Self.delete("2")])])
        let clock = TestClock()
        let hub = makeHub(connector, clock: clock)
        let home = Recorder()

        let subscription = hub.subscribe(.user, home.record)
        // 切れてつなぎ直しを待ち始めたら、つなぎ直す10msだけ進める。
        try await waitUntil { home.labels.contains("delete 1") && clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        try await waitUntil { home.labels.contains("delete 2") }

        // 台本の接続は購読しなくてもイベントを流し、最初の接続は購読を送り終える前に切れることがあるため、つなぎ直した方だけを見る。
        #expect(connector.connectCount == 2)
        #expect(connector.sent.last == [Self.subscribeUser])
        #expect(home.labels == ["connected", "delete 1", "connected", "delete 2"])
        subscription.cancel()
    }

    /// つながったら補完するため、購読が届く前に知らせると、補完の後から購読が効くまでの新着を取りこぼす。
    @Test func subscribesBeforeReportingConnected() async throws {
        let sendGate = Gate()
        let connector = ScriptedConnector([.init(sendGates: [Self.subscribeUser: sendGate])])
        let hub = makeHub(connector)
        var sentWhenConnected: [[String]]?

        let subscription = hub.subscribe(.user) { activity in
            if activity == .connected {
                sentWhenConnected = connector.sent
            }
        }
        // 購読を送っている途中では、まだ知らせない。
        try await waitUntil { sendGate.waiterCount > 0 }
        #expect(sentWhenConnected == nil)
        sendGate.open()
        try await waitUntil { sentWhenConnected != nil }

        #expect(sentWhenConnected == [[Self.subscribeUser]])
        subscription.cancel()
    }

    @Test func joiningWhileConnectedReceivesConnectedAtOnce() async throws {
        let connector = ScriptedConnector([.init()])
        let hub = makeHub(connector)
        let home = Recorder()
        let homeSubscription = hub.subscribe(.user, home.record)
        try await waitUntil { hub.isConnected }

        let notifications = Recorder()
        let notificationsSubscription = hub.subscribe(.user, notifications.record)

        #expect(notifications.labels == ["connected"])
        #expect(connector.sent == [[Self.subscribeUser]])
        homeSubscription.cancel()
        notificationsSubscription.cancel()
    }

    /// つながっている間に新しいストリームを申し込んだら、購読を送り終えてから`connected`を届ける。
    /// 先に届けると、受け取った側の補完が購読より先に終わり、その間の新着をどちらでも受け取れないため。
    @Test func joiningNewStreamWhileConnectedReportsConnectedAfterSubscribing() async throws {
        let sendGate = Gate()
        let connector = ScriptedConnector([.init(sendGates: [#"{"stream":"public:local","type":"subscribe"}"#: sendGate])])
        let hub = makeHub(connector)
        let homeSubscription = hub.subscribe(.user) { _ in }
        try await waitUntil { hub.isConnected }

        var sentWhenConnected: [[String]]?
        let localSubscription = hub.subscribe(TimelineFeed.local.subscription) { activity in
            if activity == .connected {
                sentWhenConnected = connector.sent
            }
        }
        // ローカルの購読を送っている途中では、まだ知らせない。
        try await waitUntil { sendGate.waiterCount > 0 }
        #expect(sentWhenConnected == nil)
        sendGate.open()
        try await waitUntil { sentWhenConnected != nil }

        #expect(sentWhenConnected == [[Self.subscribeUser, #"{"stream":"public:local","type":"subscribe"}"#]])
        homeSubscription.cancel()
        localSubscription.cancel()
    }

    /// `connected`を待っている間に届いたイベントは、`connected`の後に渡す。
    /// 受け取った側は`connected`で補完を始めるので、先に新着を一覧に入れると補完の基準が進み、その手前を読み飛ばすため。
    @Test func eventsArrivingBeforeDelayedConnectedFollowIt() async throws {
        let messageGate = Gate()
        let sendGate = Gate()
        // ホームのイベントは、手前のローカルのイベントをハブが受け取り終えた印に使う。
        let connector = ScriptedConnector([
            .init(
                messages: [Self.delete("1", stream: #"["public:local"]"#), Self.delete("2")],
                firstMessageGate: messageGate,
                sendGates: [#"{"stream":"public:local","type":"subscribe"}"#: sendGate]
            ),
        ])
        let hub = makeHub(connector)
        let home = Recorder()
        let local = Recorder()
        var localSubscription: StreamingHub.Subscription?
        let homeSubscription = hub.subscribe(.user) { activity in
            home.record(activity)
            if activity == .connected, localSubscription == nil {
                localSubscription = hub.subscribe(TimelineFeed.local.subscription, local.record)
                // ローカルの購読を送っている途中に、ローカルのイベントを届ける。
                messageGate.open()
            }
        }
        try await waitUntil { home.labels.contains("delete 2") }
        #expect(local.labels.isEmpty, "購読を送り終える前に、ローカルへ渡しました")

        sendGate.open()
        try await waitUntil { local.labels.count == 2 }

        #expect(local.labels == ["connected", "delete 1"])
        homeSubscription.cancel()
        localSubscription?.cancel()
    }

    /// `connected`を待っている間に届いたイベントは、その間に切れてつなぎ直しても捨てず、つなぎ直した`connected`の後に渡す。
    /// 削除や編集は、つなぎ直したあとの補完では読み直せないため。
    @Test func eventsHeldBeforeDelayedConnectedSurviveReconnecting() async throws {
        let messageGate = Gate()
        let sendGate = Gate()
        let dropGate = Gate()
        // ホームのイベントは、手前のローカルのイベントをハブが受け取り終えた印に使う。
        let connector = ScriptedConnector([
            .init(
                messages: [Self.delete("29", stream: #"["public:local"]"#), Self.delete("30")],
                afterMessages: .drop,
                dropGate: dropGate,
                firstMessageGate: messageGate,
                sendGates: [#"{"stream":"public:local","type":"subscribe"}"#: sendGate]
            ),
            .init(),
        ])
        let clock = TestClock()
        let hub = makeHub(connector, clock: clock)
        let home = Recorder()
        let local = Recorder()
        var localSubscription: StreamingHub.Subscription?
        let homeSubscription = hub.subscribe(.user) { activity in
            home.record(activity)
            if activity == .connected, localSubscription == nil {
                localSubscription = hub.subscribe(TimelineFeed.local.subscription, local.record)
            }
        }
        // ローカルの購読を送っている途中に、ローカルのイベントを届ける。
        try await waitUntil { sendGate.waiterCount > 0 }
        messageGate.open()
        try await waitUntil { home.labels.contains("delete 30") }
        #expect(local.labels.isEmpty, "購読を送り終える前に、ローカルへ渡しました")

        // 購読を送り終える前に切れて、つなぎ直す。
        dropGate.open()
        try await waitUntil { clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        try await waitUntil { connector.connectCount == 2 && local.labels.count == 2 }

        #expect(local.labels == ["connected", "delete 29"])
        homeSubscription.cancel()
        localSubscription?.cancel()
        sendGate.open()
    }

    /// 購読を送っている間に切れてつなぎ直したら、つなぎ直したときの`connected`だけを届ける。
    /// 切れる前の送信が後から終わっても、もう一度届けると、受け取った側が補完を余分に繰り返すため。
    @Test func connectedAfterSendingIsDroppedWhenReconnectedMeanwhile() async throws {
        let sendGate = Gate()
        let dropGate = Gate()
        let connector = ScriptedConnector([
            .init(
                messages: [Self.delete("1")],
                afterMessages: .drop,
                dropGate: dropGate,
                sendGates: [#"{"stream":"public:local","type":"subscribe"}"#: sendGate]
            ),
            .init(),
        ])
        let clock = TestClock()
        let hub = makeHub(connector, clock: clock)
        let local = Recorder()
        var localSubscription: StreamingHub.Subscription?
        let homeSubscription = hub.subscribe(.user) { activity in
            // 最初の接続でイベントが届いた時点、つまり切れる直前に、新しいストリームを申し込む。
            if case .event = activity, localSubscription == nil {
                localSubscription = hub.subscribe(TimelineFeed.local.subscription, local.record)
            }
        }
        // 購読を送り始めてから切る。
        try await waitUntil { sendGate.waiterCount > 0 }
        dropGate.open()
        try await waitUntil { clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        try await waitUntil { connector.connectCount == 2 && hub.isConnected && local.labels == ["connected"] }

        // 切れる前の送信を、つなぎ直した後に送り終えさせ、届けるか捨てるかが決まるまで待つ。
        sendGate.open()
        await hub.lastConnectedReportAfterSending?.value

        #expect(local.labels == ["connected"])
        homeSubscription.cancel()
        localSubscription?.cancel()
    }

    @Test func unsubscribesWhenLastOfStreamLeavesAndClosesWhenNoneLeft() async throws {
        let connector = ScriptedConnector([.init()])
        let hub = makeHub(connector)
        let home = hub.subscribe(.user) { _ in }
        let notifications = hub.subscribe(.user) { _ in }
        let publicTimeline = hub.subscribe(Self.publicStream) { _ in }
        try await waitUntil { hub.isConnected && connector.sent.first?.count == 2 }

        home.cancel()
        await hub.sending?.value
        #expect(connector.sent.first?.count == 2, "まだ通知が購読しているのに解除しました")

        notifications.cancel()
        try await waitUntil { connector.sent.first?.count == 3 }
        #expect(connector.sent.first?.last == #"{"stream":"user","type":"unsubscribe"}"#)
        #expect(hub.subscriptions == [Self.publicStream])

        publicTimeline.cancel()
        try await waitUntil { connector.closedCount == 1 }
        #expect(hub.state == .stopped)
        #expect(hub.subscriptions.isEmpty)
    }

    @Test func cancelledSubscriptionReceivesNothing() async throws {
        let connector = ScriptedConnector(Array(repeating: .init(handshake: .fail(URLError(.cannotConnectToHost))), count: 100))
        let clock = TestClock()
        let hub = makeHub(connector, live: Self.outage, clock: clock)
        let leaving = Recorder()
        let staying = Recorder()
        let leavingSubscription = hub.subscribe(.user, leaving.record)
        let stayingSubscription = hub.subscribe(.user, staying.record)

        leavingSubscription.cancel()
        try await waitUntil(advancing: clock, by: .milliseconds(5)) { staying.labels.contains("poll") }

        #expect(leaving.labels.isEmpty)
        stayingSubscription.cancel()
    }

    @Test func pollsAndNoticesOutageForEveryone() async throws {
        let connector = ScriptedConnector(Array(repeating: .init(handshake: .fail(URLError(.cannotConnectToHost))), count: 100))
        let clock = TestClock()
        let hub = makeHub(connector, live: Self.outage, clock: clock)
        let home = Recorder()
        let notifications = Recorder()
        let homeSubscription = hub.subscribe(.user, home.record)
        let notificationsSubscription = hub.subscribe(.user, notifications.record)

        try await waitUntil(advancing: clock, by: .milliseconds(5)) { home.labels.contains("outage true") && notifications.labels.contains("poll") }
        #expect(hub.state == .polling)

        let late = Recorder()
        let lateSubscription = hub.subscribe(.user, late.record)
        #expect(late.labels == ["outage true"], "切れていると知らせた後に申し込んだ相手に、知らせが届きません")
        homeSubscription.cancel()
        notificationsSubscription.cancel()
        lateSubscription.cancel()
    }

    @Test func recoverReconnectsWithoutWaitingAndResetsNotice() async throws {
        let slow = ReconnectingStream.Policy(initialRetryDelay: .seconds(3600), maxRetryDelay: .seconds(3600), pingInterval: .seconds(3600), pingTimeout: .seconds(5))
        let connector = ScriptedConnector([.init(handshake: .fail(URLError(.cannotConnectToHost))), .init()])
        let clock = TestClock()
        let hub = makeHub(connector, reconnect: slow, live: LiveUpdates.Policy(pollingInterval: .seconds(3600), outageNoticeDelay: .milliseconds(10)), clock: clock)
        let home = Recorder()
        let subscription = hub.subscribe(.user, home.record)
        // 1回目の接続に失敗して、つなぎ直しを3600秒待っている間に、知らせの10msだけ進める。
        try await waitUntil { connector.connectCount == 1 && clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        try await waitUntil { home.labels.contains("outage true") }

        hub.recover()

        try await waitUntil { hub.isConnected }
        #expect(connector.connectCount == 2)
        // つなぎ直したあとは時計を進めないので、新しく数え始めた知らせは届かない。
        #expect(Array(home.labels.prefix(2)) == ["outage true", "outage false"])
        #expect(home.labels.contains("connected"))
        subscription.cancel()
    }

    @Test func stopsUntilLogin() async throws {
        let connector = ScriptedConnector([.init()])
        let hub = makeHub(connector)
        let home = hub.subscribe(.user) { _ in }
        try await waitUntil { hub.isConnected }

        hub.stopUntilLogin()
        home.cancel()
        let again = hub.subscribe(.user) { _ in }
        // 止めた接続が閉じ終えたら、それ以上つなぎ直さない。申し込み直しでつなぐなら、申し込んだときに始めている。
        try await waitUntil { connector.closedCount == 1 }

        #expect(hub.state == .loginRequired)
        #expect(connector.connectCount == 1)
        again.cancel()
    }

    @Test func forwardsUnauthorized() async throws {
        let connector = ScriptedConnector([.init(handshake: .fail(MastodonAPIError(statusCode: 401, message: "")))])
        let hub = makeHub(connector)
        var unauthorizedCount = 0
        hub.onUnauthorized = { unauthorizedCount += 1 }
        let home = Recorder()

        let subscription = hub.subscribe(.user, home.record)
        try await waitUntil { unauthorizedCount == 1 }

        #expect(!home.labels.contains("unauthorized"))
        subscription.cancel()
    }

    private func makeHub(
        _ connector: ScriptedConnector,
        reconnect: ReconnectingStream.Policy = Self.reconnect,
        live: LiveUpdates.Policy = Self.live,
        clock: TestClock = TestClock()
    ) -> StreamingHub {
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
        return StreamingHub(reconnectPolicy: reconnect, livePolicy: { live }, clock: clock) {
            client.open(baseURL: URL(filePath: "/"))
        }
    }
}

/// 届いたものを、比べやすい文字列で記録する。
@MainActor
private final class Recorder {
    private(set) var labels: [String] = []

    func record(_ activity: StreamingHub.Activity) {
        let label = switch activity {
        case .connected: "connected"
        case .event(.delete(let id)): "delete \(id)"
        case .event(let event): "event \(event)"
        case .poll: "poll"
        case .outage(let isOngoing): "outage \(isOngoing)"
        }
        labels.append(label)
    }
}

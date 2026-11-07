import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
@Suite(.serialized)
struct NotificationsModelTests {
    private static let reblogPayload = #"{"id":"34975865","type":"reblog","created_at":"2026-10-13T03:26:00.000Z","account":{"id":"2","username":"bob","acct":"bob","display_name":"Bob","avatar":"https://example.social/avatars/bob.png","avatar_static":"https://example.social/avatars/bob.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@bob","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"status":{"id":"113000000000000001","created_at":"2026-10-13T03:21:45.123Z","spoiler_text":"","url":null,"content":"<p>Hello</p>","account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"mentions":[],"tags":[],"emojis":[],"media_attachments":[],"sensitive":false}}"#

    /// 最初の読み込みは見本の通知を返し、補完など、それより新しい通知を読む読み込みには何も返さない。
    private static func transport() throws -> RoutedTransport {
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
            case "/api/v1/markers" where request.httpMethod == "POST":
                return (200, Data(#"{"notifications":{"last_read_id":"1"}}"#.utf8))
            default:
                return (200, Data("{}".utf8))
            }
        }
    }

    private func makeModel(transport: RoutedTransport, hub: StreamingHub = TimelineModelFixtures.hub(), tuning: TuningStore = TuningStore(defaults: nil), clock: TestClock = TestClock()) -> (NotificationsModel, RecordingTimelineDisplay) {
        let model = NotificationsModel(
            client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport),
            streamingHub: hub,
            tuning: tuning,
            clock: clock,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            backgroundTime: BackgroundTimeRecorder().request,
            tasks: TaskScope()
        )
        let display = RecordingTimelineDisplay()
        model.display = display
        model.streamingStatus = display
        return (model, display)
    }

    /// 最初の読み込みで通知を並べ、未読の数を画面とタブのバッジへ伝える。
    @Test func initialLoadShowsNotificationsAndUnreadCount() async throws {
        let (model, display) = makeModel(transport: try Self.transport())
        defer { model.stop() }
        let badge = Mutex<(Int, Bool)?>(nil)
        model.onUnreadCountChange = { count, isLowerBound in badge.withLock { $0 = (count, isLowerBound) } }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded }

        #expect(display.entries.map(\.id) == ["34975864", "34975863", "34975862", "34975861"].map { .notification($0) })
        #expect(badge.withLock { $0?.0 } == display.unreadCount)
        #expect(display.footerState == model.footerState)
    }

    /// 補完の最中に頼まれた補完を続けて読み、それが失敗しても、先に読めた通知を画面に出す。
    @Test func filledNotificationsAreShownWhenFollowingFillFails() async throws {
        let url = try #require(Bundle.module.url(forResource: "grouped_notifications", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        // 最初の読み込みでは、最も新しい通知をまだ返さない。
        var initial = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        initial["notification_groups"] = try #require(initial["notification_groups"] as? [Any]).dropFirst().map { $0 }
        let initialBody = try JSONSerialization.data(withJSONObject: initial)
        let empty = Data(#"{"accounts":[],"statuses":[],"notification_groups":[]}"#.utf8)
        let firstFillGate = Gate()
        let sinceCount = Mutex(0)
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v2/notifications" else { return (200, Data("{}".utf8)) }
            let query = request.url?.query() ?? ""
            guard query.contains("min_id") || query.contains("since_id") else { return (200, initialBody) }
            switch sinceCount.withLock({ count in count += 1; return count }) {
            case 1:
                // 1回目の補完は、最も新しい通知を返す。
                try await firstFillGate.wait()
                return (200, fixture)
            case 3:
                // 続けて読む補完を失敗させる。2回目は、1回目の補完がつながったかを確かめる読み込み。
                return (500, Data("{}".utf8))
            default:
                return (200, empty)
            }
        }
        // 1回目の補完は、つながったときの補完。
        let (model, display) = makeModel(transport: transport, hub: TimelineModelFixtures.hub(ScriptedConnector([])))
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { firstFillGate.waiterCount == 1 }
        #expect(display.entries.first?.id == .notification("34975863"))
        // 1回目の補完の応答を待つ間に補完を求め、読み終えたあと続けて読ませる。
        let refresh = Task { await model.refresh() }
        try await waitUntil { model.fillWaiterCount == 1 && model.runningTaskCount == 1 }
        firstFillGate.open()
        await refresh.value

        #expect(sinceCount.withLock { $0 } == 3, "続けて読む補完が走っていません")
        #expect(display.entries.map(\.id) == ["34975864", "34975863", "34975862", "34975861"].map { .notification($0) })
    }

    /// 届いた通知は、すぐステータスバーへ流し、通知のタイムラインへは間隔をおいて挿入する。
    @Test func arrivalIsReportedAtOnceAndInsertedAfterInterval() async throws {
        let firstMessage = Gate()
        let connector = ScriptedConnector([.init(messages: [try TimelineModelFixtures.notificationMessage(Self.reblogPayload)], firstMessageGate: firstMessage)])
        let clock = TestClock()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(2, for: TuningCatalog.insertionInterval)
        let (model, display) = makeModel(transport: try Self.transport(), hub: TimelineModelFixtures.hub(connector), tuning: tuning, clock: clock)
        defer { model.stop() }
        let arrivals = Mutex<[MastodonNotification.ID]>([])
        model.onArrival = { notification, _ in arrivals.withLock { $0.append(notification.id) } }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && display.catchUp?.attempt == 1 && display.catchUp?.phase == .idle && model.runningTaskCount == 0 }
        firstMessage.open()
        try await waitUntil { clock.sleeperCount == 1 }

        #expect(arrivals.withLock { $0 } == ["34975865"])
        #expect(display.entries.first?.id == .notification("34975864"), "間隔を待たずに挿入されました")

        clock.advance(by: .seconds(2))
        try await waitUntil { display.entries.first?.id == .notification("34975865") }
    }

    /// バックグラウンドから戻ったときは、切れていた間の補完を終えるまで、最上部にいても追従せず、一番上に見えていた行の位置を保つ。
    /// 補完の最中に届いた通知も、補完を終える前に挿入しても後に挿入しても、位置を保って挿入する。
    @Test(arguments: [true, false])
    func arrivalDuringResumeFillKeepsTopRow(insertsBeforeFillEnds: Bool) async throws {
        let base = try Self.transport()
        let fillGate = Gate()
        let fillCount = Mutex(0)
        let transport = RoutedTransport { request in
            let query = request.url?.query() ?? ""
            if request.url?.path() == "/api/v2/notifications", query.contains("min_id") || query.contains("since_id"),
               fillCount.withLock({ count in count += 1; return count }) > 1 {
                try await fillGate.wait()
            }
            let (body, response) = try await base.send(request)
            return (response.statusCode, body)
        }
        let connector = ScriptedConnector([.init(), .init(messages: [try TimelineModelFixtures.notificationMessage(Self.reblogPayload)])])
        let clock = TestClock()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(2, for: TuningCatalog.insertionInterval)
        let (model, display) = makeModel(transport: transport, hub: TimelineModelFixtures.hub(connector), tuning: tuning, clock: clock)
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && display.catchUp?.attempt == 1 && display.catchUp?.phase == .idle && model.runningTaskCount == 0 }
        display.anchorID = .notification("34975864")
        model.enterBackground()
        model.enterForeground()
        try await waitUntil { fillGate.waiterCount == 1 && clock.sleeperCount == 1 }
        if insertsBeforeFillEnds {
            clock.advance(by: .seconds(2))
            try await waitUntil { display.entries.first?.id == .notification("34975865") }
            fillGate.open()
        } else {
            fillGate.open()
            try await waitUntil { display.catchUp?.attempt == 2 && display.catchUp?.phase == .idle && model.runningTaskCount == 1 }
            clock.advance(by: .seconds(2))
        }
        try await waitUntil { display.entries.first?.id == .notification("34975865") && model.runningTaskCount == 0 }
        #expect(display.entriesCalls.last?.anchorID == .notification("34975864"), "補完の最中に届いた通知の挿入で、最上部へ追従しました")
    }

    /// 既読位置は、スクロールが止まるのを待たずに保存する。指で操作している間は、操作が終わってから保存する。
    @Test func markReadSavesUnlessInteracting() async throws {
        let transport = try Self.transport()
        let clock = TestClock()
        let (model, display) = makeModel(transport: transport, clock: clock)
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && model.runningTaskCount == 0 }
        display.isUserInteracting = true
        model.markRead(["34975862"])
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(Self.markerSaves(transport).isEmpty, "操作の途中に保存しました")

        display.isUserInteracting = false
        model.interactionDidSettle()
        try await waitUntil { Self.markerSaves(transport).count == 1 }
        #expect(Self.markerSaves(transport) == ["notifications%5Blast_read_id%5D=34975862"])
    }

    /// 操作の途中に読み進めたあと、操作の終わりを知らされなくても、操作をやめて決まった時間が経てば保存する。
    @Test func markReadDuringInteractionSavesAfterDelayWithoutSettle() async throws {
        let transport = try Self.transport()
        let clock = TestClock()
        let (model, display) = makeModel(transport: transport, clock: clock)
        defer { model.stop() }
        let delay = Duration.seconds(TuningCatalog.readPositionSaveDelay.defaultValue)

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && model.runningTaskCount == 0 }
        display.isUserInteracting = true
        model.markRead(["34975862"])
        try await waitUntil { clock.sleeperCount == 1 }
        // 操作の最中は、決まった時間が経っても保存せず、待ち直す。
        clock.advance(by: delay)
        try await waitUntil { clock.sleeperCount == 1 && clock.sleeperCount(dueWithin: delay) == 1 && clock.sleeperCount(dueWithin: delay - .milliseconds(1)) == 0 }
        #expect(Self.markerSaves(transport).isEmpty, "操作の途中に保存しました")

        display.isUserInteracting = false
        clock.advance(by: delay)
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(Self.markerSaves(transport) == ["notifications%5Blast_read_id%5D=34975862"])
    }

    private static func markerSaves(_ transport: RoutedTransport) -> [String] {
        transport.requests(to: "/api/v1/markers").filter { $0.httpMethod == "POST" }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    }
}

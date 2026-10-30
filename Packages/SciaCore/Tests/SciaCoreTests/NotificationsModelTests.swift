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
        ) {}
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

        model.start()
        try await waitUntil { display.contentState == .loaded }

        #expect(display.entries.map(\.id) == ["34975864", "34975863", "34975862", "34975861"].map { .notification($0) })
        #expect(badge.withLock { $0?.0 } == display.unreadCount)
        #expect(display.footerState == model.footerState)
    }

    /// 届いた通知は、すぐステータスバーへ流し、一覧へは間隔をおいて挿入する。
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

        model.start()
        try await waitUntil { display.contentState == .loaded && display.catchUp?.attempt == 1 && display.catchUp?.phase == .idle && model.runningTaskCount == 0 }
        firstMessage.open()
        try await waitUntil { clock.sleeperCount == 1 }

        #expect(arrivals.withLock { $0 } == ["34975865"])
        #expect(display.entries.first?.id == .notification("34975864"), "間隔を待たずに挿入されました")

        clock.advance(by: .seconds(2))
        try await waitUntil { display.entries.first?.id == .notification("34975865") }
    }

    /// 既読位置は、スクロールが止まるのを待たずに保存する。指で操作している間は、操作が終わってから保存する。
    @Test func markReadSavesUnlessInteracting() async throws {
        let transport = try Self.transport()
        let (model, display) = makeModel(transport: transport)
        defer { model.stop() }
        func saves() -> [String] {
            transport.requests(to: "/api/v1/markers").filter { $0.httpMethod == "POST" }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        }

        model.start()
        try await waitUntil { display.contentState == .loaded && model.runningTaskCount == 0 }
        display.isUserInteracting = true
        model.markRead(["34975862"])
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(saves().isEmpty, "操作の途中に保存しました")

        display.isUserInteracting = false
        model.interactionDidSettle()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(saves() == ["notifications%5Blast_read_id%5D=34975862"])
    }
}

import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
@Suite(.serialized)
struct FeedTimelineModelTests {
    private func makeModel(
        feed: TimelineFeed = .home,
        transport: RoutedTransport,
        hub: StreamingHub = TimelineModelFixtures.hub(),
        tuning: TuningStore = TuningStore(defaults: nil),
        clock: TestClock = TestClock(),
        backgroundTime: BackgroundTimeRecorder = BackgroundTimeRecorder(),
        tasks: TaskScope = TaskScope(),
        onUnauthorized: @escaping () -> Void = {}
    ) -> (FeedTimelineModel, RecordingTimelineDisplay) {
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)
        let model = FeedTimelineModel(
            feed: feed,
            client: client,
            streamingHub: hub,
            tuning: tuning,
            clock: clock,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            backgroundTime: backgroundTime.request,
            tasks: tasks,
            onUnauthorized: onUnauthorized
        )
        let display = RecordingTimelineDisplay()
        model.display = display
        model.streamingStatus = display
        return (model, display)
    }

    /// 最初の読み込みは、ホームの投稿を読み、既読位置を取り込む。補完など、それより新しい投稿を読む読み込みには何も返さない。
    private static func homeTransport(_ ids: [Int], marker: String? = nil) -> RoutedTransport {
        RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v1/markers" where request.httpMethod == "POST":
                return (200, Data(#"{"home":{"last_read_id":"1"}}"#.utf8))
            case "/api/v1/markers":
                return (200, Data((marker.map { #"{"home":{"last_read_id":"\#($0)"}}"# } ?? "{}").utf8))
            case "/api/v1/timelines/home":
                let query = request.url?.query() ?? ""
                return (200, try TimelineModelFixtures.body(query.contains("min_id") || query.contains("since_id") ? [] : ids))
            default:
                return (404, Data(#"{"error":"Not found"}"#.utf8))
            }
        }
    }

    /// 最初の読み込みで、既読位置の投稿を最上部に置き、読み込みの状態を画面に伝える。
    @Test func initialLoadPlacesMarkerAtTop() async throws {
        let (model, display) = makeModel(transport: Self.homeTransport([3, 2, 1], marker: "2"))
        defer { model.stop() }

        model.start()
        #expect(display.contentState == .loading)
        try await waitUntil { display.contentState == .loaded }

        #expect(display.statusIDs == ["3", "2", "1"])
        #expect(display.entriesCalls.first?.topID == .status("2"))
        #expect(display.unreadCount == 1)
        #expect(model.contentState == .loaded)
        #expect(display.footerState == model.footerState)
    }

    /// 最初の読み込みに失敗したら、画面ではなくモデルが失敗を覚えていて、電波の回復でやり直す。
    @Test func recoverRetriesFailedInitialLoad() async throws {
        let failsTimeline = Mutex(true)
        let transport = RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v1/timelines/home":
                if failsTimeline.withLock({ $0 }) {
                    return (422, Data(#"{"error":"Unprocessable"}"#.utf8))
                }
                return (200, try TimelineModelFixtures.body([1]))
            default:
                return (200, Data("{}".utf8))
            }
        }
        let (model, display) = makeModel(transport: transport)
        defer { model.stop() }

        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        guard case .failed = model.contentState else {
            Issue.record("最初の読み込みの失敗を覚えていません: \(model.contentState)")
            return
        }
        #expect(display.contentState == model.contentState)

        failsTimeline.withLock { $0 = false }
        model.recover()
        try await waitUntil { display.contentState == .loaded }
        #expect(display.statusIDs == ["1"])
    }

    /// 作り直し中で投稿のないホームは、作り直し中と伝える。
    @Test func emptyRegeneratingHomeShowsRegenerating() async throws {
        let transport = RoutedTransport { _ in (206, Data("[]".utf8)) }
        let (model, display) = makeModel(transport: transport)
        defer { model.stop() }

        model.start()
        try await waitUntil { display.contentState != .loading }

        #expect(display.contentState == .regenerating)
    }

    /// 届いた新着は、間隔をおいて挿入する。指で操作している間は、操作が終わるまで待つ。
    @Test func arrivalWaitsForInteractionToSettle() async throws {
        let firstMessage = Gate()
        let connector = ScriptedConnector([.init(messages: [try TimelineModelFixtures.updateMessage(2)], firstMessageGate: firstMessage)])
        let clock = TestClock()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(2, for: TuningCatalog.insertionInterval)
        let (model, display) = makeModel(transport: Self.homeTransport([1]), hub: TimelineModelFixtures.hub(connector), tuning: tuning, clock: clock)
        defer { model.stop() }

        model.start()
        // つながったときの補完まで終える。
        try await waitUntil { display.contentState == .loaded && model.isSubscribedToStreaming && display.catchUp?.attempt == 1 && display.catchUp?.phase == .idle && model.runningTaskCount == 0 }
        display.isUserInteracting = true
        firstMessage.open()
        try await waitUntil { clock.sleeperCount == 1 }
        #expect(display.statusIDs == ["1"], "間隔を待たずに挿入されました")

        clock.advance(by: .seconds(2))
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.statusIDs == ["1"], "操作の途中に挿入されました")

        display.isUserInteracting = false
        model.interactionDidSettle()
        #expect(display.statusIDs == ["2", "1"])
        #expect(display.entriesCalls.last?.base != nil, "挿入では、残る行の中身を変えていないと伝えます")
    }

    /// 止めたあとに届いた401は、ログインし直しを促さず、画面にも何も伝えない。
    @Test func stoppedModelIgnoresLateResults() async throws {
        let gate = Gate()
        let transport = RoutedTransport { _ in
            try await gate.wait()
            return (401, Data(#"{"error":"The access token is invalid"}"#.utf8))
        }
        let reported = Mutex(false)
        let (model, display) = makeModel(transport: transport) {
            reported.withLock { $0 = true }
        }

        model.start()
        try await waitUntil { gate.waiterCount == 1 }
        let commandsBeforeStop = display.commandCount
        model.stop()
        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(!reported.withLock { $0 })
        #expect(display.commandCount == commandsBeforeStop)
    }

    /// バックグラウンドに入ったら、読み進めた既読位置を保存し、保存し終えるまでアプリを止めないよう頼む。
    @Test func enteringBackgroundSavesReadPositionWithBackgroundTime() async throws {
        let transport = Self.homeTransport([2, 1])
        let backgroundTime = BackgroundTimeRecorder()
        let (model, display) = makeModel(transport: transport, backgroundTime: backgroundTime)
        defer { model.stop() }

        model.start()
        try await waitUntil { display.contentState == .loaded && model.runningTaskCount == 0 }
        model.markRead(["2"])
        #expect(display.unreadCount == 0)
        model.enterBackground()
        #expect(backgroundTime.requestedNames == ["save home marker"])
        try await waitUntil { model.runningTaskCount == 0 }

        let saves = transport.requests(to: "/api/v1/markers").filter { $0.httpMethod == "POST" }
        #expect(saves.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } == ["home%5Blast_read_id%5D=2"])
        #expect(backgroundTime.heldCount == 0)
        #expect(!model.isSubscribedToStreaming)
    }

    /// 保存している途中で頼んだ時間が尽きたら、次にバックグラウンドへ入ったときに頼み直す。
    @Test func expiredBackgroundTimeIsRequestedAgain() async throws {
        let gate = Gate()
        let home = Self.homeTransport([2, 1])
        let transport = RoutedTransport { request in
            if request.url?.path() == "/api/v1/markers", request.httpMethod == "POST" {
                try await gate.wait()
            }
            let response = try await home.send(request)
            return (response.1.statusCode, response.0)
        }
        let backgroundTime = BackgroundTimeRecorder()
        let (model, display) = makeModel(transport: transport, backgroundTime: backgroundTime)
        defer { model.stop() }

        model.start()
        try await waitUntil { display.contentState == .loaded && model.runningTaskCount == 0 }
        model.markRead(["2"])
        model.enterBackground()
        try await waitUntil { gate.waiterCount == 1 }
        backgroundTime.expireAll()
        model.enterForeground()
        model.enterBackground()

        #expect(backgroundTime.requestedNames == ["save home marker", "save home marker"])
        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(backgroundTime.heldCount == 0)
    }
}

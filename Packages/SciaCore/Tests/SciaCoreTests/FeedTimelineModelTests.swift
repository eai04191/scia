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

        model.start(purpose: .action)
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

        model.start(purpose: .action)
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

        model.start(purpose: .action)
        try await waitUntil { display.contentState != .loading }

        #expect(display.contentState == .regenerating)
    }

    /// 空のホームの補完で最新のページを読めたら、続けて読む補完が失敗しても、読めた投稿を画面に出す。
    @Test func latestPageIsShownWhenFollowingFillFails() async throws {
        let latestGate = Gate()
        let latestCount = Mutex(0)
        let sinceFails = FailOnce()
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v1/timelines/home" else { return (200, Data("{}".utf8)) }
            if request.url?.query()?.contains("since_id") == true {
                return sinceFails.shouldFail() ? (500, Data("{}".utf8)) : (200, Data("[]".utf8))
            }
            guard latestCount.withLock({ count in count += 1; return count }) > 1 else { return (200, Data("[]".utf8)) }
            try await latestGate.wait()
            return (200, try TimelineModelFixtures.body([2, 1]))
        }
        let (model, display) = makeModel(transport: transport)
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { latestGate.waiterCount == 1 }
        // 最新のページを読んでいる間に補完を求め、読み終えたあと続けて読ませる。
        let refresh = Task { await model.refresh() }
        try await waitUntil { model.fillWaiterCount == 1 && model.runningTaskCount == 1 }
        latestGate.open()
        await refresh.value

        #expect(display.statusIDs == ["2", "1"])
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

        model.start(purpose: .action)
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

    /// バックグラウンドから戻ったときは、切れていた間の補完を終えるまで、最上部にいても追従せず、一番上に見えていた行の位置を保つ。
    /// 補完を終えたあとに届いた新着は、また最上部で追従する。
    @Test func resumeFillKeepsTopRowUntilFillEnds() async throws {
        let fillIDs = Mutex<[Int]>([])
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v1/timelines/home" else { return (200, Data("{}".utf8)) }
            let query = request.url?.query() ?? ""
            let ids = query.contains("min_id") || query.contains("since_id") ? fillIDs.withLock { $0 } : [2, 1]
            return (200, try TimelineModelFixtures.body(ids))
        }
        let laterMessage = Gate()
        let connector = ScriptedConnector([.init(), .init(messages: [try TimelineModelFixtures.updateMessage(4)], firstMessageGate: laterMessage)])
        let clock = TestClock()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(2, for: TuningCatalog.insertionInterval)
        let (model, display) = makeModel(transport: transport, hub: TimelineModelFixtures.hub(connector), tuning: tuning, clock: clock)
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && display.catchUp?.attempt == 1 && display.catchUp?.phase == .idle && model.runningTaskCount == 0 }
        display.anchorID = .status("2")
        model.enterBackground()
        fillIDs.withLock { $0 = [3] }
        model.enterForeground()
        try await waitUntil { display.statusIDs == ["3", "2", "1"] && model.runningTaskCount == 0 }
        #expect(display.entriesCalls.last?.anchorID == .status("2"), "補完で最上部に追従しました")

        laterMessage.open()
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        try await waitUntil { display.statusIDs == ["4", "3", "2", "1"] }
        #expect(display.entriesCalls.last?.anchorID == nil, "補完を終えたあとも位置を保ち続けました")
    }

    /// 補完の最中に届いた新着の挿入が、補完を終えたあとになっても、位置を保って挿入する。
    @Test func arrivalDuringResumeFillInsertedAfterFillEndsKeepsTopRow() async throws {
        let fillGate = Gate()
        let fillCount = Mutex(0)
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v1/timelines/home" else { return (200, Data("{}".utf8)) }
            let query = request.url?.query() ?? ""
            guard query.contains("min_id") || query.contains("since_id") else { return (200, try TimelineModelFixtures.body([2, 1])) }
            if fillCount.withLock({ count in count += 1; return count }) > 1 {
                try await fillGate.wait()
            }
            return (200, Data("[]".utf8))
        }
        let connector = ScriptedConnector([.init(), .init(messages: [try TimelineModelFixtures.updateMessage(3)])])
        let clock = TestClock()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(2, for: TuningCatalog.insertionInterval)
        let (model, display) = makeModel(transport: transport, hub: TimelineModelFixtures.hub(connector), tuning: tuning, clock: clock)
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && display.catchUp?.attempt == 1 && display.catchUp?.phase == .idle && model.runningTaskCount == 0 }
        display.anchorID = .status("2")
        model.enterBackground()
        model.enterForeground()
        try await waitUntil { fillGate.waiterCount == 1 && clock.sleeperCount == 1 }
        fillGate.open()
        try await waitUntil { display.catchUp?.attempt == 2 && display.catchUp?.phase == .idle && model.runningTaskCount == 1 }
        clock.advance(by: .seconds(2))
        try await waitUntil { display.statusIDs == ["3", "2", "1"] && model.runningTaskCount == 0 }

        #expect(display.entriesCalls.last?.anchorID == .status("2"), "補完を終えたあとの挿入で、最上部へ追従しました")
    }

    /// 戻る前から古い投稿を読んでいて、補完の途中で読み終えても、補完で入った新着に追従しない。
    @Test func olderLoadDuringResumeFillKeepsTopRow() async throws {
        let gapGate = Gate()
        let olderGate = Gate()
        let fillCount = Mutex(0)
        let transport = RoutedTransport { request in
            guard request.url?.path() == "/api/v1/timelines/home" else { return (200, Data("{}".utf8)) }
            let query = request.url?.query() ?? ""
            if query.contains("max_id") {
                // since_idの付いたものは補完がギャップを読む読み込み、付かないものは古い投稿の読み込み。
                try await (query.contains("since_id") ? gapGate : olderGate).wait()
                return (200, Data("[]".utf8))
            }
            if query.contains("since_id") {
                let count = fillCount.withLock { count in count += 1; return count }
                return (200, try TimelineModelFixtures.body(count == 1 ? [] : [3]))
            }
            return (200, try TimelineModelFixtures.body([2, 1]))
        }
        let (model, display) = makeModel(transport: transport, hub: TimelineModelFixtures.hub(ScriptedConnector([.init(), .init()])))
        defer { model.stop() }

        model.start(purpose: .action)
        try await waitUntil { display.contentState == .loaded && display.catchUp?.attempt == 1 && display.catchUp?.phase == .idle && model.runningTaskCount == 0 }
        display.anchorID = .status("2")
        model.approachEnd()
        try await waitUntil { olderGate.waiterCount == 1 }
        model.enterBackground()
        model.enterForeground()
        try await waitUntil { gapGate.waiterCount == 1 }
        olderGate.open()
        try await waitUntil { display.statusIDs == ["3", "2", "1"] }

        #expect(display.entriesCalls.last?.anchorID == .status("2"), "古い投稿の読み込みで、補完で入った新着に追従しました")
        gapGate.open()
        try await waitUntil { model.runningTaskCount == 0 }
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

        model.start(purpose: .action)
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

        model.start(purpose: .action)
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

        model.start(purpose: .action)
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

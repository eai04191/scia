import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
@Suite(.serialized)
struct ThreadModelTests {
    /// 押した投稿は2で、その祖先は1。`failsContext`がtrueを返す間は、会話の読み込みを422で断る。
    private static func transport(failsContext: @escaping @Sendable () -> Bool = { false }) -> RoutedTransport {
        RoutedTransport { request in
            switch request.url?.path() {
            case "/api/v1/statuses/2/context":
                if failsContext() {
                    return (422, Data(#"{"error":"Unprocessable"}"#.utf8))
                }
                let ancestors = String(decoding: try TimelineModelFixtures.body([1]), as: UTF8.self)
                return (200, Data(#"{"ancestors":\#(ancestors),"descendants":[]}"#.utf8))
            default:
                return (200, Data("{}".utf8))
            }
        }
    }

    private func makeModel(transport: RoutedTransport, onUnauthorized: @escaping () -> Void = {}) throws -> (ThreadModel, RecordingTimelineDisplay) {
        let model = ThreadModel(
            focus: try TimelineModelFixtures.status(2),
            client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport),
            // つながったときの読み直しが、確かめる読み込みと重ならないよう、つながらないハブにする。つなぎ直しは時計を進めない限り起きない。
            streamingHub: TimelineModelFixtures.hub(ScriptedConnector([.init(handshake: .fail(URLError(.notConnectedToInternet)))])),
            tasks: TaskScope(),
            onUnauthorized: onUnauthorized
        )
        let display = RecordingTimelineDisplay()
        model.display = display
        return (model, display)
    }

    /// 押した投稿だけを並べて開き、会話は画面を移り終えてから、押した投稿の位置を保って並べる。
    @Test func showsContextAfterTransitionKeepingFocus() async throws {
        let (model, display) = try makeModel(transport: Self.transport())
        var deferred: [@MainActor () -> Void] = []
        model.afterTransition = { deferred.append($0) }
        var firstLoadShownCount = 0
        model.onFirstLoadShown = { firstLoadShownCount += 1 }

        model.start()
        #expect(display.statusIDs == ["2"])
        #expect(display.footerState == .loading)
        try await waitUntil { deferred.count == 1 }
        #expect(display.statusIDs == ["2"], "画面を移り終える前に並べました")

        deferred.removeFirst()()
        #expect(display.statusIDs == ["1", "2"])
        #expect(display.entriesCalls.last?.anchorID == .status("2"))
        #expect(display.footerState == .idle)
        #expect(firstLoadShownCount == 1)
    }

    /// 会話を読めなかったら、フッターに失敗を出し、再試行で読み直す。
    @Test func retryReloadsAfterFailure() async throws {
        let failsContext = Mutex(true)
        let (model, display) = try makeModel(transport: Self.transport { failsContext.withLock { $0 } })

        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        guard case .failed = display.footerState else {
            Issue.record("失敗を伝えていません: \(display.footerState)")
            return
        }

        failsContext.withLock { $0 = false }
        model.retry()
        try await waitUntil { display.footerState == .idle }
        #expect(display.statusIDs == ["1", "2"])
    }
}

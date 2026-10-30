import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
@Suite(.serialized)
struct SavedStatusesModelTests {
    /// ブックマークの一覧を、呼ばれた順に`pages`のページで返す。足りなければ最後のページを返す。
    private static func transport(_ pages: [[Status]], failsFirst: Bool = false) -> RoutedTransport {
        let index = Mutex(failsFirst ? -1 : 0)
        return RoutedTransport { _ in
            let page = index.withLock { index in
                defer { index += 1 }
                return index
            }
            guard page >= 0 else { return (422, Data(#"{"error":"Unprocessable"}"#.utf8)) }
            return (200, try TimelineModelFixtures.body(pages[min(page, pages.count - 1)]))
        }
    }

    private static func saved(_ ids: [Int]) throws -> [Status] {
        try ids.map { try TimelineModelFixtures.status($0).settingBookmarked(true) }
    }

    private func makeModel(transport: RoutedTransport) -> (SavedStatusesModel, RecordingTimelineDisplay) {
        let model = SavedStatusesModel(kind: .bookmarks, client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), tasks: TaskScope()) {}
        let display = RecordingTimelineDisplay()
        model.display = display
        return (model, display)
    }

    /// 見せ始めたら最新のページを読み、先頭に足しても、表示領域の上端にかかっている行の位置を保つ。
    @Test func showingReadsNewestKeepingCurrentAnchor() async throws {
        let (model, display) = makeModel(transport: Self.transport([try Self.saved([2, 1]), try Self.saved([3, 2, 1])]))
        defer { model.stop() }

        model.startIfNeeded()
        try await waitUntil { display.contentState == .loaded }
        #expect(display.statusIDs == ["2", "1"])
        display.anchorID = .status("2")

        model.setShown(true)
        try await waitUntil { display.statusIDs == ["3", "2", "1"] }
        #expect(display.entriesCalls.last?.anchorID == .status("2"))
        #expect(display.footerState == model.footerState)
    }

    /// 見ていない間に外したら、すぐ一覧から消す。見ている間は、付け直せるよう残す。
    @Test func unsavingPrunesOnlyWhileHidden() async throws {
        let (model, display) = makeModel(transport: Self.transport([try Self.saved([2, 1])]))
        defer { model.stop() }
        model.startIfNeeded()
        try await waitUntil { display.contentState == .loaded }

        model.setShown(true)
        try await waitUntil { model.runningTaskCount == 0 }
        // 押したときにブックマークを外し、サーバーが受け付けたら知らせる。StatusInteractionsと同じ順に送る。
        model.updateStatus("2") { $0.settingBookmarked(false) }
        model.statusDidSettle(.bookmark, try TimelineModelFixtures.status(2).settingBookmarked(false))
        #expect(display.statusIDs == ["2", "1"], "見ている間に外した行を消しました")

        model.setShown(false)
        #expect(display.statusIDs == ["1"])

        model.updateStatus("1") { $0.settingBookmarked(false) }
        model.statusDidSettle(.bookmark, try TimelineModelFixtures.status(1).settingBookmarked(false))
        #expect(display.statusIDs.isEmpty)
    }

    /// 最初の読み込みに失敗したら、モデルが失敗を覚えていて、引っぱった読み直しでやり直す。
    @Test func refreshRetriesFailedInitialLoad() async throws {
        let (model, display) = makeModel(transport: Self.transport([try Self.saved([1])], failsFirst: true))
        defer { model.stop() }

        model.startIfNeeded()
        try await waitUntil { model.runningTaskCount == 0 }
        guard case .failed = display.contentState else {
            Issue.record("最初の読み込みの失敗を伝えていません: \(display.contentState)")
            return
        }

        await model.refresh()
        #expect(display.contentState == .loaded)
        #expect(display.statusIDs == ["1"])
    }
}

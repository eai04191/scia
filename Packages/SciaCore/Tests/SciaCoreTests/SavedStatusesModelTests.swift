import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
@Suite(.serialized)
struct SavedStatusesModelTests {
    /// ブックマークを、呼ばれた順に`pages`のページで返す。足りなければ最後のページを返す。
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
        let model = SavedStatusesModel(kind: .bookmarks, client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), tasks: TaskScope())
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

    /// 見ていない間に外したら、すぐタイムラインから消す。見ている間は、付け直せるよう残す。
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

    /// 1件もないときの「再読み込み」は、最初から読み直す。ほかの端末で付けた分を、タブを開き直さずに読めるようにする。
    @Test func retryReloadsWhenEmpty() async throws {
        let (model, display) = makeModel(transport: Self.transport([[], try Self.saved([1])]))
        defer { model.stop() }

        model.startIfNeeded()
        try await waitUntil { display.contentState == .loaded }
        #expect(display.statusIDs.isEmpty)

        model.retry()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.contentState == .loaded)
        #expect(display.statusIDs == ["1"])
    }

    /// 見せ始めたときの読み込みの最中に「再読み込み」を押しても、読み込み中の表示のまま残さない。
    /// 重ねて読まないので、最初から読み直す処理は何も読まずに終わり、表示を戻すものがなくなる。
    @Test func retryDuringRefreshDoesNotLeaveLoading() async throws {
        let refreshing = Gate()
        let calls = Mutex(0)
        let later = try TimelineModelFixtures.body(try Self.saved([1]))
        let transport = RoutedTransport { _ in
            let call = calls.withLock { count in
                defer { count += 1 }
                return count
            }
            guard call > 0 else { return (200, try TimelineModelFixtures.body([Status]())) }
            try await refreshing.wait()
            return (200, later)
        }
        let (model, display) = makeModel(transport: transport)
        defer { model.stop() }
        model.startIfNeeded()
        try await waitUntil { display.contentState == .loaded }
        model.setShown(true)
        try await waitUntil { refreshing.waiterCount == 1 }

        model.retry()
        refreshing.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(display.contentState == .loaded)
        #expect(display.statusIDs == ["1"])
    }

    /// 引用した投稿のタイムラインでは、引用を取り消した行を、見ている間でも、閉じる動きで消す。取り消しは戻せないため。
    @Test func revokedQuoteIsRemovedWhileShown() async throws {
        let quoted = try TimelineModelFixtures.status(1)
        let quoting = try [3, 2].map { try TimelineModelFixtures.status($0).replacingQuote(Quote(state: "accepted", quotedStatus: quoted)) }
        let transport = Self.transport([quoting])
        let model = SavedStatusesModel(kind: .quotes(of: "1"), client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), tasks: TaskScope())
        let display = RecordingTimelineDisplay()
        model.display = display
        defer { model.stop() }
        model.startIfNeeded()
        try await waitUntil { display.contentState == .loaded }
        model.setShown(true)
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(transport.requests.first?.url?.path() == "/api/v1/statuses/1/quotes")

        model.updateStatus("3") { $0.replacingQuote(Quote(state: "revoked")) }
        model.quoteWasRevoked(by: "3")

        #expect(display.statusIDs == ["2"])
        #expect(display.entriesCalls.last?.animatesRemoval == true)
    }

    /// 読み直している間に引用を取り消したら、取り消す前の中身で遅れて届いたページから、その行を戻さない。
    @Test func refreshInFlightDoesNotRestoreRevokedQuote() async throws {
        let quoted = try TimelineModelFixtures.status(1)
        let quoting = try TimelineModelFixtures.status(2).replacingQuote(Quote(state: "accepted", quotedStatus: quoted))
        let staleResponse = Gate()
        let reads = Mutex(0)
        let transport = RoutedTransport { _ in
            let count = reads.withLock { count in
                count += 1
                return count
            }
            if count == 2 { try await staleResponse.wait() }
            return (200, try TimelineModelFixtures.body([quoting]))
        }
        let model = SavedStatusesModel(kind: .quotes(of: "1"), client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), tasks: TaskScope())
        let display = RecordingTimelineDisplay()
        model.display = display
        defer { model.stop() }
        model.startIfNeeded()
        try await waitUntil { display.contentState == .loaded }
        model.setShown(true)
        try await waitUntil { staleResponse.waiterCount == 1 }

        model.updateStatus("2") { $0.replacingQuote(Quote(state: "revoked")) }
        model.quoteWasRevoked(by: "2")
        #expect(display.statusIDs.isEmpty)
        staleResponse.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(display.statusIDs.isEmpty)
    }

    /// 最初の読み込みの間に、まだ読んでいない引用を取り消したら、遅れて届いたページから、その投稿を出さない。
    @Test func revokingBeforeFirstPageArrivesKeepsQuoteOut() async throws {
        let quoted = try TimelineModelFixtures.status(1)
        let quoting = try [3, 2].map { try TimelineModelFixtures.status($0).replacingQuote(Quote(state: "accepted", quotedStatus: quoted)) }
        let firstResponse = Gate()
        let transport = RoutedTransport { _ in
            try await firstResponse.wait()
            return (200, try TimelineModelFixtures.body(quoting))
        }
        let model = SavedStatusesModel(kind: .quotes(of: "1"), client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), tasks: TaskScope())
        let display = RecordingTimelineDisplay()
        model.display = display
        defer { model.stop() }
        model.startIfNeeded()
        try await waitUntil { firstResponse.waiterCount == 1 }

        model.quoteWasRevoked(by: "3")
        firstResponse.open()
        try await waitUntil { display.contentState == .loaded }

        #expect(display.statusIDs == ["2"])
    }

    /// 引用元の人をミュートしていると、サーバーは認められた引用にも`muted_account`を返す。その投稿は、お気に入りなどで中身を変えても、タイムラインに残す。
    @Test func quoteOfMutedAccountStaysAfterUpdate() async throws {
        let muted = try [3, 2].map { try TimelineModelFixtures.status($0).replacingQuote(Quote(state: "muted_account", quotedStatusID: "1")) }
        let model = SavedStatusesModel(kind: .quotes(of: "1"), client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: Self.transport([muted])), tasks: TaskScope())
        let display = RecordingTimelineDisplay()
        model.display = display
        defer { model.stop() }
        model.startIfNeeded()
        try await waitUntil { display.contentState == .loaded }

        model.updateStatus("3") { $0.settingFavourited(true) }

        #expect(display.statusIDs == ["3", "2"])
    }
}

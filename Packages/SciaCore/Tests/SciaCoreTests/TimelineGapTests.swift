import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 切断していた間の補完とギャップの読み込みで、投稿の重複と漏れが起きないことを確かめる。
@MainActor
struct TimelineGapTests {
    private static let pageSize = 3

    // MARK: - 状態を丸ごと比べるための道具

    /// 状態に書く投稿の行。`FakeHomeServer.status`はIDだけで決まるので、テストのサーバーで作ったものと同じになる。渡した順に並べる。
    private func entryRows(_ ids: [Int]) -> [TimelineEntry] {
        let source = FakeHomeServer(ids: [Int]())
        return ids.map { .status(source.status($0)) }
    }

    /// 状態に書く投稿の行。範囲のIDを新しい順に並べる。
    private func entryRows(_ ids: ClosedRange<Int>) -> [TimelineEntry] {
        entryRows(Array(ids.reversed()))
    }

    /// 状態に書くギャップの行。読んで縮んだギャップは、作ったときの端を`createdAs`に渡す。IDは作ったときの端で決まり、縮んでも変わらないため。
    private func gapEntry(_ newer: Int, _ older: Int, createdAs created: (newer: Int, older: Int)? = nil) -> TimelineEntry {
        let original = TimelineGap(newerID: String(created?.newer ?? newer), olderID: String(created?.older ?? older))
        return .gap(original.narrowed(newerID: String(newer), olderID: String(older)))
    }

    /// 準備の最初の読み込み。最新のページの投稿が並び、続きを古い方へ読む位置が決まるほかは、何も変わらないことを確かめる。
    private func loadFirstPage(_ store: TimelineStoreTester, _ server: FakeHomeServer, showing ids: [Int], sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await store.expectChanges(during: { store in try await store.loadInitial() }, sourceLocation: sourceLocation) {
            $0.entries = entryRows(ids)
            $0.oldestLoadedID = ids.last.map(String.init)
        }
    }

    /// 準備の補完。`11...20`を投稿してから1ページだけ読み、最新の3件と手元の投稿の間にギャップを置く。
    private func fillTenMissed(_ store: TimelineStoreTester, _ server: FakeHomeServer, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        server.post(11...20)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }, sourceLocation: sourceLocation) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
        }
    }

    // MARK: - 読めない投稿

    /// 1ページの全部が読めなくても、読めなかった投稿のIDから続きを読む。
    @Test func pageOfOnlyUnreadableStatusesDoesNotStopLoadingOlder() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [8, 9, 10])
        let store = makeStore(server)
        let unreadable = [10, 9, 8].map { UnreadableItem(id: String($0), url: nil) }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = unreadable.map(TimelineEntry.unreadable)
            $0.unreadableItems = unreadable
            $0.oldestLoadedID = "8"
        }

        let older = try await store.expectChanges(during: { store in try await store.loadOlder()?.map(\.id) }) {
            $0.entries += entryRows([7, 6, 5])
            $0.oldestLoadedID = "5"
        }
        #expect(older == ["7", "6", "5"])
        #expect(server.queries.last == TimelineQuery(maxID: "8", limit: Self.pageSize))
    }

    @Test func readableStatusReplacesUnreadableWithSameID() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [9])
        let store = makeStore(server)
        let unreadable = UnreadableItem(id: "9", url: nil)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10]) + [.unreadable(unreadable)] + entryRows([8])
            $0.unreadableItems = [unreadable]
            $0.oldestLoadedID = "8"
        }

        try await store.expectChanges(during: { store in store.receive(.update(server.status(9))) }) {
            $0.pending = [server.status(9)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries = entryRows([10, 9, 8])
            $0.unreadableItems = []
        }
    }

    @Test func storeWithOnlyUnreadableStatusesIsNotEmpty() async throws {
        let server = FakeHomeServer(ids: 8...10, unreadableIDs: [8, 9, 10])
        let store = makeStore(server)
        let unreadable = [10, 9, 8].map { UnreadableItem(id: String($0), url: nil) }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = unreadable.map(TimelineEntry.unreadable)
            $0.unreadableItems = unreadable
            $0.oldestLoadedID = "8"
        }

        #expect(store.statuses.isEmpty)
        #expect(!store.isEmpty, "読めなかった投稿しかないと、画面が空とみなして続きを読みません")
    }

    /// 末尾の読めない投稿と同じIDの投稿が届いたら、末尾より古い投稿を捨てる条件に当てはめず、置き換える。
    @Test func readableStatusReplacesUnreadableAtTail() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [8])
        let store = makeStore(server)
        let unreadable = UnreadableItem(id: "8", url: nil)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9]) + [.unreadable(unreadable)]
            $0.unreadableItems = [unreadable]
            $0.oldestLoadedID = "8"
        }

        try await store.expectChanges(during: { store in store.receive(.update(server.status(8))) }) {
            $0.pending = [server.status(8)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries = entryRows([10, 9, 8])
            $0.unreadableItems = []
        }
    }

    @Test func editedStatusReplacesUnreadable() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [9])
        let store = makeStore(server)
        let unreadable = UnreadableItem(id: "9", url: nil)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10]) + [.unreadable(unreadable)] + entryRows([8])
            $0.unreadableItems = [unreadable]
            $0.oldestLoadedID = "8"
        }

        let result = try await store.expectChanges(during: { store in store.receive(.statusUpdate(server.status(9))) }) {
            $0.entries = entryRows([10, 9, 8])
            $0.unreadableItems = []
        }
        #expect(result == .entriesChanged)
    }

    @Test func deletingUnreadableStatusRemovesIt() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [9])
        let store = makeStore(server)
        let unreadable = UnreadableItem(id: "9", url: nil)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10]) + [.unreadable(unreadable)] + entryRows([8])
            $0.unreadableItems = [unreadable]
            $0.oldestLoadedID = "8"
        }

        let result = try await store.expectChanges(during: { store in store.receive(.delete(statusID: "9")) }) {
            $0.deletedIDs = ["9"]
            $0.entries = entryRows([10, 8])
            $0.unreadableItems = []
        }
        #expect(result == .entriesChanged)
    }

    // MARK: - 求めた件数より少なく返すサーバー

    /// 件数が`limit`に届かなくても、それだけでは読み切ったと判断しない。サーバーが件数を丸めていることがあるため。
    @Test func fillDoesNotSkipStatusesWhenServerReturnsFewerThanRequested() async throws {
        let server = FakeHomeServer(ids: 1...10, maxLimit: 2)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9])
        server.post(11...14)

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows(9...14)
        }
    }

    @Test(arguments: [TimelineStore.GapDirection.fromNewer, .fromOlder])
    func gapIsNotClosedByShortPageFromCappingServer(direction: TimelineStore.GapDirection) async throws {
        let server = FakeHomeServer(ids: 1...10, maxLimit: 2)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9])
        server.post(11...30)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            // 満杯でないページの下のギャップを、続けて2回読んで縮める。
            $0.entries = entryRows(25...30) + [gapEntry(25, 10, createdAs: (29, 10))] + entryRows([10, 9])
        }
        let gap = try #require(store.gaps.first)

        try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: direction) }) {
            switch direction {
            case .fromNewer:
                $0.entries = entryRows(21...30) + [gapEntry(21, 10, createdAs: (29, 10))] + entryRows([10, 9])
            case .fromOlder:
                $0.entries = entryRows(25...30) + [gapEntry(25, 14, createdAs: (29, 10))] + entryRows(9...14)
            }
        }

        #expect(store.gaps.map(\.id) == [gap.id], "読み切っていないギャップが閉じました")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: direction)
            }
        }) {
            $0.entries = entryRows(9...30)
        }
        #expect(ids(store) == Array((9...30).reversed()))
    }

    @Test func markerGapIsKeptWhenServerReturnsFewerThanRequested() async throws {
        let server = FakeHomeServer(ids: 1...20, maxLimit: 2)
        let store = makeStore(server)

        try await store.expectChanges(during: { store in try await store.loadInitial(around: "5") }) {
            $0.entries = entryRows([20, 19]) + [gapEntry(19, 7)] + entryRows([7, 6, 5, 4])
            $0.oldestLoadedID = "4"
            $0.lastReadID = "5"
            #if DEBUG
            $0.lastSavableReadID = "5"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "5", sequence: 0)
            $0.savedReadID = "5"
        }
    }

    @Test func fillWithinOnePageLeavesNoGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...12)

        let filled = try await store.expectChanges(during: { store in try await store.fillFromLatest()?.map(\.id) }) {
            $0.entries = entryRows(8...12)
        }
        #expect(filled == ["12", "11"])

        #expect(store.gaps.isEmpty)
        #expect(ids(store) == [12, 11, 10, 9, 8])
        // 満杯でないページの下も、0件が返るまでは読み切ったと判断しない。
        #expect(Array(server.queries.suffix(2)) == [
            TimelineQuery(sinceID: "10", limit: Self.pageSize),
            TimelineQuery(maxID: "11", sinceID: "10", limit: Self.pageSize),
        ])
    }

    @Test func fillLeavesGapWhenMoreThanOnePageWasMissed() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
        }
    }

    @Test func nothingMissedChangesNothing() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])

        let filled = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) { _ in }
        #expect(filled == [])
        #expect(ids(store) == [10, 9, 8])
        #expect(store.gaps.isEmpty)
    }

    @Test func fillReadsUpToPageLimitUntilConnected() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...17)

        try await store.expectChanges(during: { store in try await store.fillFromLatest(maxPages: 3) }) {
            $0.entries = entryRows(8...17)
        }

        #expect(store.gaps.isEmpty)
        #expect(ids(store) == Array((8...17).reversed()))
    }

    /// 読み込み中の表示に使う。何ページで終わるかは分からないので、1ページ読むたびに、加わった投稿の数を積み上げて渡す。
    @Test func fillReportsAddedCountPerPage() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...17)
        var reported: [Int] = []

        try await store.expectChanges(during: { store in try await store.fillFromLatest(maxPages: 3) { reported.append($0) } }) {
            $0.entries = entryRows(8...17)
        }

        #expect(reported == [3, 6, 7])
    }

    /// 満杯でないページを取り込んだら、間が空なのを確かめる読み込みを待たずに件数を渡す。確かめるのが遅れても、読んだ分は表示に出す。
    @Test func fillReportsGapPageBeforeConfirming() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let reported = Mutex<[Int]>([])
        let reportedAtConfirmation = Mutex<[Int]?>(nil)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            let page = server.page(query)
            if query.maxID != nil, query.sinceID != nil, page.isEmpty {
                reportedAtConfirmation.withLock { $0 = reported.withLock { $0 } }
            }
            return page
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...17)

        try await store.expectChanges(during: { store in
            try await store.fillFromLatest(maxPages: 3) { count in reported.withLock { $0.append(count) } }
        }) {
            $0.entries = entryRows(8...17)
        }

        #expect(reportedAtConfirmation.withLock { $0 } == [3, 6, 7])
    }

    @Test func fillLeavesGapBeyondPageLimit() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...30)

        try await store.expectChanges(during: { store in try await store.fillFromLatest(maxPages: 2) }) {
            $0.entries = entryRows(25...30) + [gapEntry(25, 10, createdAs: (28, 10))] + entryRows([10, 9, 8])
        }
    }

    @Test func failureOnLaterFillPageKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID != nil, query.sinceID != nil {
                throw URLError(.networkConnectionLost)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)

        let filled = try await store.expectChanges(during: { store in try await store.fillFromLatest(maxPages: 3)?.map(\.id) }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
            // 補完の中で続けて読んだギャップの失敗も、ギャップを読んだときと同じく、行の中で知らせるために覚える。
            $0.failedGaps = [TimelineGap(newerID: "18", olderID: "10").id: ErrorPresentation(URLError(.networkConnectionLost))]
        }
        #expect(filled == ["20", "19", "18"])
    }

    /// ギャップを読めなかったら、行の中で知らせられるよう、どのギャップがなぜ読めなかったかを残す。読み直せたら消す。
    @Test func failedGapIsRememberedUntilItLoads() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let failsGap = Atomic(false)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if failsGap.load(ordering: .relaxed), query.maxID != nil {
                throw URLError(.networkConnectionLost)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        try await fillTenMissed(store, server)
        let gap = try #require(store.gaps.first)
        #expect(store.gapFailures.isEmpty)

        failsGap.store(true, ordering: .relaxed)
        try await store.expectChanges(during: { store in
            await #expect(throws: URLError.self) { try await store.loadGap(gap.id, from: .fromNewer) }
        }) {
            $0.failedGaps[gap.id] = ErrorPresentation(URLError(.networkConnectionLost))
        }
        #expect(store.gapFailures == [gap.id: ErrorPresentation(URLError(.networkConnectionLost))])

        failsGap.store(false, ordering: .relaxed)
        try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: .fromNewer) }) {
            $0.entries = entryRows(15...20) + [gapEntry(15, 10, createdAs: (18, 10))] + entryRows([10, 9, 8])
            $0.failedGaps[gap.id] = nil
        }
        #expect(store.gapFailures.isEmpty)
    }

    /// 満杯でないページの後の確かめる読み込みに失敗しても、読めた分は返し、残ったギャップは読めなかったことにする。
    @Test func failedConfirmationKeepsLoadedStatusesAndRemembersFailure() async throws {
        // 求めた件数より少なく返すサーバーで、確かめる読み込みを起こす。
        let server = FakeHomeServer(ids: 1...10, maxLimit: 2)
        // 準備の補完の中のギャップの読み込みでは失敗させない。補完の確かめる読み込みが失敗すると、同じギャップの失敗が先に残り、
        // あとのギャップの読み込みが失敗を残したかを見分けられないため。
        let gapLoads = Atomic(-100)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID != nil, query.sinceID != nil, gapLoads.add(1, ordering: .relaxed).newValue == 2 {
                throw URLError(.timedOut)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9])
        server.post(11...30)
        try await store.expectChanges(during: { store in try await store.fillFromLatest(maxPages: 1) }) {
            $0.entries = entryRows(25...30) + [gapEntry(25, 10, createdAs: (29, 10))] + entryRows([10, 9])
        }
        let gap = try #require(store.gaps.first)
        gapLoads.store(0, ordering: .relaxed)

        let added = try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: .fromNewer) }) {
            $0.entries = entryRows(23...30) + [gapEntry(23, 10, createdAs: (29, 10))] + entryRows([10, 9])
            $0.failedGaps[gap.id] = ErrorPresentation(URLError(.timedOut))
        }

        #expect(added?.count == 2)
        #expect(store.gaps.map(\.id) == [gap.id])
        #expect(store.gapFailures == [gap.id: ErrorPresentation(URLError(.timedOut))])
    }

    /// 取り消しは失敗ではないので、読めなかったことにしない。
    @Test func cancelledGapLoadIsNotRememberedAsFailure() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let cancels = Atomic(false)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if cancels.load(ordering: .relaxed), query.maxID != nil {
                throw CancellationError()
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        try await fillTenMissed(store, server)
        let gap = try #require(store.gaps.first)

        cancels.store(true, ordering: .relaxed)
        try await store.expectChanges(during: { store in
            await #expect(throws: CancellationError.self) { try await store.loadGap(gap.id, from: .fromNewer) }
        }) { _ in }
        #expect(store.gapFailures.isEmpty)
    }

    @Test(arguments: [TimelineStore.GapDirection.fromNewer, .fromOlder])
    func loadingGapRepeatedlyClosesItWithoutDuplicatesOrOmissions(direction: TimelineStore.GapDirection) async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        try await fillTenMissed(store, server)

        try await store.expectChanges(during: { store in
            var loads = 0
            while let gap = store.gaps.first, loads < 10 {
                _ = try await store.loadGap(gap.id, from: direction)
                loads += 1
            }
        }) {
            $0.entries = entryRows(8...20)
        }

        #expect(store.gaps.isEmpty)
        #expect(ids(store) == Array((8...20).reversed()))
    }

    @Test func loadingFromOlderKeepsGapAboveLoadedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        try await fillTenMissed(store, server)
        let gap = try #require(store.gaps.first)

        let loaded = try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: .fromOlder)?.map(\.id) }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 13, createdAs: (18, 10))] + entryRows(8...13)
        }
        #expect(loaded == ["13", "12", "11"])

        #expect(store.gaps.first?.id == gap.id, "縮んだギャップが別のものとして扱われました")
        #expect(server.queries.last == TimelineQuery(maxID: "18", minID: "10", limit: Self.pageSize))
    }

    @Test func loadingFromNewerKeepsGapBelowLoadedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        try await fillTenMissed(store, server)
        let gap = try #require(store.gaps.first)

        let loaded = try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: .fromNewer)?.map(\.id) }) {
            $0.entries = entryRows(15...20) + [gapEntry(15, 10, createdAs: (18, 10))] + entryRows([10, 9, 8])
        }
        #expect(loaded == ["17", "16", "15"])

        #expect(server.queries.last == TimelineQuery(maxID: "18", sinceID: "10", limit: Self.pageSize))
    }

    /// 接続し直してから補完が終わるまでの間に届いた新着が先に挿入されても、その下の区間を読み飛ばさない。
    @Test func streamedArrivalsDuringFillDoNotHideMissedRange() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            // 補完の読み込みだけを止める。ギャップを新しい側から読むときもsince_idが付くため、max_idの有無で区別する。
            if query.sinceID != nil, query.maxID == nil {
                await gate.wait()
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)

        let fill = try await store.expectChanges(during: { store in
            let fill = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return fill
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        server.post(21...21)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(21))) }) {
            $0.pending = [server.status(21)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(.status(server.status(21)), at: 0)
        }
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await fill.value
        }) {
            $0.entries = entryRows([21, 20, 19]) + [gapEntry(19, 10)] + entryRows([10, 9, 8])
            $0.isFilling = false
            $0.unfilledSinceID = nil
        }

        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(8...21)
        }
        #expect(ids(store) == Array((8...21).reversed()))
    }

    /// 補完に失敗した後に新着が挿入されても、次の補完は失敗したときの基準から読む。
    @Test func failedFillIsRetriedFromSameBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let fails = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, fails.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...12)

        try await store.expectChanges(during: { store in
            await #expect(throws: URLError.self) { _ = try await store.fillFromLatest() }
        }) {
            $0.unfilledSinceID = "10"
        }
        server.post(13...13)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(13))) }) {
            $0.pending = [server.status(13)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(.status(server.status(13)), at: 0)
        }
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            // 満杯のページが返ったので、その下が空かはまだ確かめず、ギャップを残す。
            $0.entries = entryRows([13, 12, 11]) + [gapEntry(11, 10)] + entryRows([10, 9, 8])
            $0.unfilledSinceID = nil
        }

        #expect(server.queries.last?.sinceID == "10")
        #expect(ids(store) == Array((8...13).reversed()))
    }

    /// ストリーミングにつながらないサーバーでは、ポーリングの補完だけが新着を届ける。空のホームでも最新のページを読む。
    @Test func fillOnEmptyTimelineLoadsLatestPage() async throws {
        let server = FakeHomeServer(ids: [])
        let store = TimelineStoreTester(pageSize: Self.pageSize) { server.page($0) }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.reachedEnd = true
        }
        #expect(store.isEmpty)
        server.post(1...3)

        let added = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows(1...3)
            $0.oldestLoadedID = "1"
            // 古い投稿が残っているかもしれないので、終端としない。
            $0.reachedEnd = false
        }

        #expect(added?.map(\.id) == ["3", "2", "1"])
        #expect(store.statuses.map(\.id) == ["3", "2", "1"])
        #expect(store.gaps.isEmpty)
    }

    /// 補完の最中に接続し直しても、同じギャップを2つ作らず、後の要求も終わった後に読む。
    @Test func overlappingFillsAreSerialized() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)

        let first = try await store.expectChanges(during: { store in
            let first = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return first
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        let second = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.refillSinceID = "10"
        }
        #expect(second == nil)
        server.post(21...21)
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await first.value
        }) {
            // 1回目は止めている間に投稿された21まで読み、2回目は21より新しい投稿を読む。
            $0.entries = entryRows([21, 20, 19]) + [gapEntry(19, 10)] + entryRows([10, 9, 8])
            $0.isFilling = false
            $0.unfilledSinceID = nil
            $0.refillSinceID = nil
        }

        #expect(Set(store.gaps.map(\.id)).count == store.gaps.count, "同じギャップが重複しています")
        #expect(server.queries.filter { $0.sinceID != nil && $0.maxID == nil }.count == 2)
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(8...21)
        }
        #expect(ids(store) == Array((8...21).reversed()))
    }

    /// 補完の読み込み中に新着が挿入されて補完が重なり、1回目が再生成中で空だったときも、間の投稿を失わない。
    @Test func overlappingFillAfterRegeneratingKeepsBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...12)

        let first = try await store.expectChanges(during: { store in
            let first = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return first
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        server.post(13...13)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(13))) }) {
            $0.pending = [server.status(13)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(.status(server.status(13)), at: 0)
        }
        let second = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.refillSinceID = "13"
        }
        #expect(second == nil)
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await first.value
        }) {
            // 1回目が再生成中で空だったので、2回目は13からではなく、読めなかった10から読み直す。
            // 再生成中だったことは、2回目が揃った結果を読んだので残らない。
            $0.entries = entryRows([13, 12, 11]) + [gapEntry(11, 10)] + entryRows([10, 9, 8])
            $0.isFilling = false
            $0.unfilledSinceID = nil
            $0.refillSinceID = nil
        }
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(8...13)
        }
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) { _ in }
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) { _ in }

        #expect(ids(store) == Array((8...13).reversed()))
    }

    /// 重なった補完の2回の読み込みの間に新着が増えても、範囲の重なるギャップを作らない。
    @Test func overlappingFillDoesNotDuplicateGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                let page = server.page(query)
                server.post(21...21)
                return page
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)

        let first = try await store.expectChanges(during: { store in
            let first = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return first
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        let second = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.refillSinceID = "10"
        }
        #expect(second == nil)
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await first.value
        }) {
            // 2回目は1回目が読んだ20より新しい21を読み、20との間のギャップは、満杯でないので確かめて閉じる。
            $0.entries = entryRows([21, 20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
            $0.isFilling = false
            $0.unfilledSinceID = nil
            $0.refillSinceID = nil
        }

        #expect(store.gaps.count == 1, "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(8...21)
        }
        #expect(ids(store) == Array((8...21).reversed()))
    }

    /// 補完に失敗した後に最新のページで読み直したら、次の補完は読み直したタイムラインの最新から読む。
    @Test func reloadAfterFailedFillDropsStaleBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let failing = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, failing.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)
        try await store.expectChanges(during: { store in
            await #expect(throws: URLError.self) { try await store.fillFromLatest() }
        }) {
            $0.unfilledSinceID = "10"
        }

        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([20, 19, 18])
            $0.oldestLoadedID = "18"
            $0.unfilledSinceID = nil
        }
        server.post(21...22)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows(18...22)
        }

        #expect(store.gaps.isEmpty, "読み込み済みの区間に重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        #expect(ids(store) == Array((18...22).reversed()))
    }

    /// 再生成中のページは揃っていないので、返った投稿の間にも投稿が残りうる。ギャップの端を進めず、後で読み切ったときに読み飛ばさない。
    @Test(arguments: [TimelineStore.GapDirection.fromNewer, .fromOlder])
    func regeneratingPageDoesNotNarrowGap(direction: TimelineStore.GapDirection) async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let partial = direction == .fromNewer ? [17, 15] : [13, 11]
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID != nil, regenerating.shouldFail() {
                return TimelinePage(statuses: partial.map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        try await fillTenMissed(store, server)
        let gap = try #require(store.gaps.first)
        #expect((gap.newerID, gap.olderID) == ("18", "10"))

        try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: direction) }) {
            // ギャップの読み込みは、再生成中だったことを残さない。残すのは最初の読み込み、古い方の読み込み、補完で、画面はその直後にだけ読む。
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows(partial) + entryRows([10, 9, 8])
        }
        let kept = try #require(store.gaps.first)
        #expect((kept.newerID, kept.olderID) == ("18", "10"), "再生成中のページでギャップの端が進みました")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: direction)
            }
        }) {
            $0.entries = entryRows(8...20)
        }
        #expect(ids(store) == Array((8...20).reversed()))
    }

    /// 補完の読み込みが再生成中で一部の投稿だけを返したら、返った中で最も新しい投稿から下をギャップにして、間の投稿を読み飛ばさない。
    /// 最も新しい投稿より上は、次の補完でそこから読む。
    @Test func regeneratingFillPageKeepsGapBelowNewest() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, regenerating.shouldFail() {
                return TimelinePage(statuses: [13, 11].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            // 13から下に置いたギャップは、満杯でないので続けて読んで閉じる。
            $0.entries = entryRows(8...13)
            $0.isRegenerating = true
            $0.unfilledSinceID = "13"
        }
        #expect(ids(store) == Array((8...13).reversed()), "再生成中の結果の間の投稿を読み飛ばしました: \(store.entries.map(\.debugLabel))")

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 13)] + entryRows(8...13)
            $0.isRegenerating = false
            $0.unfilledSinceID = nil
        }
        #expect(store.gaps.count <= 1, "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(8...20)
        }
        #expect(ids(store) == Array((8...20).reversed()))
    }

    /// ギャップの中に届いた投稿を既読にしても、その新しい側に読み込んでいない投稿があれば、未読はまだある。
    @Test func readInsideGapStillHasUnloadedUnread() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { server.page($0) }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        try await fillTenMissed(store, server)
        let gap = try #require(store.gaps.first)
        #expect((gap.newerID, gap.olderID) == ("18", "10"))

        try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: .fromOlder) }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 13, createdAs: (18, 10))] + entryRows(8...13)
        }
        try await store.expectChanges(during: { store in store.markRead(["13"]) }) {
            $0.lastReadID = "13"
            #if DEBUG
            $0.lastSavableReadID = "13"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "13", sequence: 0)
        }

        #expect(store.hasUnloadedUnread, "14から17を読み込んでいないのに未読なしになりました")
        try await store.expectChanges(during: { store in store.markRead(["18"]) }) {
            $0.lastReadID = "18"
            #if DEBUG
            $0.lastSavableReadID = "18"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "18", sequence: 0)
        }
        #expect(!store.hasUnloadedUnread)
    }

    /// 補完の最中に次の補完を受け付けた後で、今の補完が失敗しても、次の補完で受け付けた分まで読む。
    @Test func failedFillAfterOverlapIsRecoveredByNextFill() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                throw URLError(.networkConnectionLost)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...12)

        let first = try await store.expectChanges(during: { store in
            let first = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return first
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        server.post(13...13)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(13))) }) {
            $0.pending = [server.status(13)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(.status(server.status(13)), at: 0)
        }
        let second = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.refillSinceID = "13"
        }
        #expect(second == nil)
        try await store.expectChanges(during: { store in
            await gate.open()
            await #expect(throws: URLError.self) { try await first.value }
        }) {
            // 受け付けた13と読めなかった10の古い方の10を、次の補完の基準に残す。
            $0.isFilling = false
            $0.refillSinceID = nil
        }
        server.post(14...14)

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([14, 13, 12]) + [gapEntry(12, 10)] + entryRows([10, 9, 8])
            $0.unfilledSinceID = nil
        }
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(8...14)
        }
        #expect(ids(store) == Array((8...14).reversed()))
    }

    /// 重なった補完の1回目が再生成中で一部の投稿だけを返し、置いたギャップを読んでもまだ再生成中だったとき、
    /// 2回目はそのギャップに含めた範囲を読み直さず、範囲の重なるギャップを作らない。
    @Test func overlappingFillAfterRegeneratingPageDoesNotOverlapGaps() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let gapRegenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                return TimelinePage(statuses: [16, 11].map(server.status), isRegenerating: true)
            }
            if query.maxID != nil, gapRegenerating.shouldFail() {
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)

        let first = try await store.expectChanges(during: { store in
            let first = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return first
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        try await store.expectChanges(during: { store in store.receive(.update(server.status(13))) }) {
            $0.pending = [server.status(13)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(.status(server.status(13)), at: 0)
        }
        let second = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.refillSinceID = "13"
        }
        #expect(second == nil)
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await first.value
        }) {
            // 2回目は、1回目が返した最も新しい16から読む。16から下のギャップは、読んでも再生成中だったので端を動かさない。
            // 再生成中だったことは、2回目が揃った結果を読んだので残らない。
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 16)] + entryRows([16]) + [gapEntry(16, 10)]
                + entryRows([13, 11, 10, 9, 8])
            $0.isFilling = false
            $0.unfilledSinceID = nil
            $0.refillSinceID = nil
        }

        let gaps = store.gaps
        let overlapping = gaps.indices.contains { i in
            gaps.indices.contains { j in
                i != j && StatusID.isNewer(gaps[i].newerID, than: gaps[j].olderID) && StatusID.isNewer(gaps[j].newerID, than: gaps[i].olderID)
            }
        }
        #expect(!overlapping, "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(8...20)
        }
        #expect(ids(store) == Array((8...20).reversed()))
    }

    /// 最新のページで読み直したら再生成中で一部の投稿だけが返っても、返った投稿の間をギャップにして、後で読み切ったときに読み飛ばさない。
    /// 補完に失敗した基準は読み直しで捨てるので、その間の投稿は読み直したページのギャップからしか読めない。
    @Test func regeneratingReloadAfterFailedFillKeepsGapBetweenReturnedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let failing = FailOnce()
        let latestLoads = Mutex(0)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, failing.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            // 2回目の最新のページ（読み直し）だけ、再生成中で一部の投稿を返す。
            if query.maxID == nil, query.sinceID == nil, query.minID == nil, latestLoads.withLock({ count in count += 1; return count == 2 }) {
                return TimelinePage(statuses: [20, 11].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [10, 9, 8])
        server.post(11...20)
        try await store.expectChanges(during: { store in
            await #expect(throws: URLError.self) { try await store.fillFromLatest() }
        }) {
            $0.unfilledSinceID = "10"
        }

        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([20]) + [gapEntry(20, 11)] + entryRows([11])
            $0.oldestLoadedID = "11"
            // 読めなかった10は捨て、20より上を次の補完で読む。
            $0.unfilledSinceID = "20"
            $0.isRegenerating = true
        }
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.unfilledSinceID = nil
            $0.isRegenerating = false
        }
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(11...20)
        }
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries = entryRows(8...20)
            $0.oldestLoadedID = "8"
        }

        #expect(ids(store) == Array((8...20).reversed()), "再生成中の結果の間の投稿を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    /// 起動して最初の読み込みが再生成中で一部の投稿だけを返しても、返った投稿の間をギャップにする。
    @Test func regeneratingFirstLoadKeepsGapBetweenReturnedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if regenerating.shouldFail() {
                return TimelinePage(statuses: [20, 11].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([20]) + [gapEntry(20, 11)] + entryRows([11])
            $0.oldestLoadedID = "11"
            $0.unfilledSinceID = "20"
            $0.isRegenerating = true
        }
        let gap = try #require(store.gaps.first, "再生成中の結果の間にギャップがありません: \(store.entries.map(\.debugLabel))")
        #expect((gap.newerID, gap.olderID) == ("20", "11"))

        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            // ギャップの読み込みは、再生成中だったことを変えない。次の補完か読み込みで改める。
            $0.entries = entryRows(11...20)
        }
        #expect(ids(store) == Array((11...20).reversed()))
    }

    /// 古いページの読み込みが再生成中で一部の投稿だけを返しても、末尾から返った投稿までをギャップにする。
    @Test func regeneratingOlderPageKeepsGapToReturnedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID != nil, regenerating.shouldFail() {
                return TimelinePage(statuses: [17, 12].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [20, 19, 18])
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 12)] + entryRows([17, 12])
            $0.oldestLoadedID = "12"
            $0.isRegenerating = true
        }

        #expect(store.gaps.map { [$0.newerID, $0.olderID] } == [["18", "12"]], "再生成中の結果の間にギャップがありません: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(12...20)
        }
        #expect(ids(store) == Array((12...20).reversed()))
    }

    /// 既読位置のすぐ後の読み込みが再生成中で一部の投稿だけを返しても、最新のページから返った投稿の一番古いものまでをギャップにする。
    @Test func regeneratingPageAfterMarkerKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.minID != nil {
                return TimelinePage(statuses: [9, 6].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial(around: "5") }) {
            // 再生成中だったかは、最新のページで決める。既読位置の周りのページが再生成中でも、間はギャップに残してある。
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 6)] + entryRows([9, 6, 5, 4, 3])
            $0.oldestLoadedID = "3"
            $0.lastReadID = "5"
            #if DEBUG
            $0.lastSavableReadID = "5"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "5", sequence: 0)
            $0.savedReadID = "5"
        }

        #expect(store.gaps.map { [$0.newerID, $0.olderID] } == [["18", "6"]], "再生成中の結果の間にギャップがありません: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(3...20)
        }
        #expect(ids(store) == Array((3...20).reversed()))
    }

    /// 既読位置から古い方の読み込みが再生成中で一部の投稿だけを返しても、読み始めた投稿から返った投稿の一番古いものまでをギャップにする。
    @Test func regeneratingPageFromMarkerKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == "6", query.sinceID == nil, query.minID == nil {
                return TimelinePage(statuses: [5, 2].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial(around: "5") }) {
            // 再生成中だったかは、最新のページで決める。既読位置の周りのページが再生成中でも、間はギャップに残してある。
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 8)] + entryRows([8, 7, 6]) + [gapEntry(6, 2)]
                + entryRows([5, 2])
            $0.oldestLoadedID = "2"
            $0.lastReadID = "5"
            #if DEBUG
            $0.lastSavableReadID = "5"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "5", sequence: 0)
            $0.savedReadID = "5"
        }

        #expect(store.gaps.map { [$0.newerID, $0.olderID] } == [["18", "8"], ["6", "2"]], "再生成中の結果の間にギャップがありません: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(2...20)
        }
        #expect(ids(store) == Array((2...20).reversed()))
    }

    /// タイムラインが空のときの補完が再生成中で一部の投稿だけを返しても、返った投稿の間をギャップにする。
    @Test func regeneratingFillIntoEmptyListKeepsGapBetweenReturnedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let latestLoads = Mutex(0)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil {
                // 最初の読み込みは再生成中で空、続く補完は再生成中で一部の投稿を返す。
                switch latestLoads.withLock({ count in count += 1; return count }) {
                case 1: return TimelinePage(statuses: [], isRegenerating: true)
                case 2: return TimelinePage(statuses: [20, 11].map(server.status), isRegenerating: true)
                default: break
                }
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.isRegenerating = true
            $0.fillsFromLatestPage = true
        }
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([20]) + [gapEntry(20, 11)] + entryRows([11])
            $0.oldestLoadedID = "11"
            $0.unfilledSinceID = "20"
            $0.fillsFromLatestPage = false
        }

        #expect(store.gaps.map { [$0.newerID, $0.olderID] } == [["20", "11"]], "再生成中の結果の間にギャップがありません: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(11...20)
        }
        #expect(ids(store) == Array((11...20).reversed()))
    }

    // MARK: - 末尾より古い新着

    /// 古いページを読んでいる間に、末尾より古いIDの投稿が遅れて届いても、読んでいたページに入っていなければ、末尾が下がったところでタイムラインに入れる。
    /// ページはその投稿が届く前にサーバーが作ったので入っておらず、捨てるとどこからも読めないため。
    @Test func lateArrivalOlderThanTailDuringLoadOlderIsKept() async throws {
        let server = FakeHomeServer(ids: (1...20).map { $0 * 10 })
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID != nil, gated.shouldFail() {
                let page = server.page(query)
                await gate.wait()
                return page
            }
            return server.page(query)
        }
        try await loadFirstPage(store, server, showing: [200, 190, 180])
        let older = try await store.expectChanges(during: { store in
            let older = Task { try await store.loadOlder() }
            await gate.waitUntilWaiting()
            return older
        }) {
            $0.isLoading = true
        }
        server.post(155...155)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(155))) }) {
            $0.pending = [server.status(155)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            // 末尾の180より古いので、まだ並べずに取っておく。
            $0.olderArrivals = [server.status(155)]
        }
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await older.value
        }) {
            $0.entries = entryRows([200, 190, 180, 170, 160, 155, 150])
            $0.oldestLoadedID = "150"
            $0.olderArrivals = []
            $0.isLoading = false
        }

        #expect(ids(store) == [200, 190, 180, 170, 160, 155, 150], "遅れて届いた投稿が抜けました: \(store.entries.map(\.debugLabel))")
    }

    // MARK: - タイムラインが空のときの補完

    /// 最初の読み込みが空で、タイムラインが空のときの補完に失敗したあとで新着が入っても、次の補完は最新のページから読み、失敗した間を読み飛ばさない。
    @Test func failedFillIntoEmptyListIsRetriedFromLatestPage() async throws {
        let server = FakeHomeServer(ids: [Int]())
        let failing = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil, !server.ids.isEmpty, failing.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.reachedEnd = true
        }
        server.post(1...2)
        try await store.expectChanges(during: { store in
            await #expect(throws: URLError.self) { try await store.fillFromLatest() }
        }) {
            $0.fillsFromLatestPage = true
        }
        server.post(3...3)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(3))) }) {
            $0.pending = [server.status(3)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            // 古い方の終わりに着いているので、末尾より古くても取っておかずに並べる。
            $0.pending = []
            $0.entries = entryRows([3])
            $0.oldestLoadedID = "3"
        }

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.fillsFromLatestPage = false
            $0.entries = entryRows([3, 2, 1])
            $0.oldestLoadedID = "1"
            // 最新のページに投稿があったので、終わりに着いた扱いをやめる。
            $0.reachedEnd = false
        }
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.reachedEnd = true
        }

        #expect(ids(store) == [3, 2, 1], "失敗した補完の間を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    /// タイムラインが空のときの補完が最新のページを読んでいる間に、古いIDの新着が入っても、最新のページとその間をギャップにする。
    @Test func arrivalsDuringFillIntoEmptyListKeepGapBelowLatestPage() async throws {
        let server = FakeHomeServer(ids: [Int]())
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil, !server.ids.isEmpty, gated.shouldFail() {
                let page = server.page(query)
                await gate.wait()
                return page
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.reachedEnd = true
        }
        for id in [10, 20, 30, 40, 50, 60] {
            server.post(id...id)
        }
        let fill = try await store.expectChanges(during: { store in
            let fill = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return fill
        }) {
            $0.isFilling = true
            $0.fillsFromLatestPage = true
        }
        server.post(15...15)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(15))) }) {
            $0.pending = [server.status(15)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries = entryRows([15])
            $0.oldestLoadedID = "15"
        }
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await fill.value
        }) {
            $0.isFilling = false
            $0.fillsFromLatestPage = false
            $0.entries = entryRows([60, 50, 40]) + [gapEntry(40, 15)] + entryRows([15])
            $0.reachedEnd = false
        }

        try await store.expectChanges(during: { store in
            _ = try await store.loadGap(TimelineGap(newerID: "40", olderID: "15").id, from: .fromNewer)
        }) {
            // 満杯でないページだったので、もう1回読んで0件を確かめ、ギャップを閉じる。
            $0.entries = entryRows([60, 50, 40, 30, 20, 15])
        }
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries += entryRows([10])
            $0.oldestLoadedID = "10"
        }
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.reachedEnd = true
        }
        #expect(Set(ids(store)) == [10, 15, 20, 30, 40, 50, 60], "最新のページと新着の間を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    /// タイムラインが空のときの補完が最新のページを読んでいる間に、また補完を求められたら、読み終えた後に続けて読む。
    @Test func fillRequestedDuringFillIntoEmptyListRunsAfterIt() async throws {
        let server = FakeHomeServer(ids: [Int]())
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil, !server.ids.isEmpty, gated.shouldFail() {
                let page = server.page(query)
                await gate.wait()
                return page
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.reachedEnd = true
        }
        server.post(1...2)
        let fill = try await store.expectChanges(during: { store in
            let fill = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return fill
        }) {
            $0.isFilling = true
            $0.fillsFromLatestPage = true
        }
        server.post(3...3)
        let requested = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.refillsAfterLatestPage = true
        }
        #expect(requested == nil)
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await fill.value
        }) {
            $0.isFilling = false
            $0.fillsFromLatestPage = false
            $0.refillsAfterLatestPage = false
            $0.entries = entryRows([3, 2, 1])
            $0.oldestLoadedID = "1"
            $0.reachedEnd = false
        }

        #expect(ids(store) == [3, 2, 1], "読んでいる間に求められた補完を読みませんでした: \(store.entries.map(\.debugLabel))")
    }

    /// タイムラインが空のときの補完が再生成中で1件も返らなければ、そのあと新着が入っても、次の補完も最新のページから読む。
    @Test func emptyRegeneratingFillIntoEmptyListIsRetriedFromLatestPage() async throws {
        let server = FakeHomeServer(ids: [Int]())
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil, !server.ids.isEmpty, regenerating.shouldFail() {
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.reachedEnd = true
        }
        server.post(1...2)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.fillsFromLatestPage = true
            $0.isRegenerating = true
            // 再生成中の空のページは、終わりに着いたことにならない。
            $0.reachedEnd = false
        }
        server.post(3...3)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(3))) }) {
            $0.pending = [server.status(3)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries = entryRows([3])
            $0.oldestLoadedID = "3"
        }

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.fillsFromLatestPage = false
            $0.isRegenerating = false
            $0.entries = entryRows([3, 2, 1])
            $0.oldestLoadedID = "1"
        }

        #expect(ids(store) == [3, 2, 1], "再生成中で読めなかった間を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    /// タイムラインが空のときの補完が再生成中で一部の投稿だけを返したら、そのあと新着が入っても、次の補完は返った中で最も新しい投稿から読む。
    @Test func regeneratingFillIntoEmptyListReadsAboveNewestReturnedStatusNext() async throws {
        let server = FakeHomeServer(ids: [Int]())
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil, !server.ids.isEmpty, regenerating.shouldFail() {
                return TimelinePage(statuses: [30, 10].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.reachedEnd = true
        }
        for id in [10, 20, 30, 40] {
            server.post(id...id)
        }
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.unfilledSinceID = "30"
            $0.isRegenerating = true
            $0.entries = entryRows([30]) + [gapEntry(30, 10)] + entryRows([10])
            $0.oldestLoadedID = "10"
            $0.reachedEnd = false
        }
        server.post(50...50)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(50))) }) {
            $0.pending = [server.status(50)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([50]), at: 0)
        }

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.unfilledSinceID = nil
            $0.isRegenerating = false
            $0.entries = entryRows([50, 40, 30]) + [gapEntry(30, 10)] + entryRows([10])
        }
        try await store.expectChanges(during: { store in
            _ = try await store.loadGap(TimelineGap(newerID: "30", olderID: "10").id, from: .fromNewer)
        }) {
            $0.entries = entryRows([50, 40, 30, 20, 10])
        }

        #expect(Set(ids(store)) == [10, 20, 30, 40, 50], "返った投稿より上を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    /// 既読位置のすぐ後の読み込みが再生成中で、最新のページを読んだ後に増えた投稿まで返しても、その投稿までをギャップにする。
    @Test func regeneratingPageAfterMarkerWithNewerStatusesKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.minID != nil {
                server.post(21...22)
                return TimelinePage(statuses: [22, 6].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        let gap = TimelineGap(newerID: "22", olderID: "6")
        try await store.expectChanges(during: { store in try await store.loadInitial(around: "5") }) {
            // ギャップは22のすぐ下に並び、読み込み済みの20〜18もギャップの範囲に入る。
            $0.entries = entryRows([22]) + [.gap(gap)] + entryRows([20, 19, 18, 6, 5, 4, 3])
            $0.oldestLoadedID = "3"
            $0.lastReadID = "5"
            #if DEBUG
            $0.lastSavableReadID = "5"
            #endif
            $0.lastReadPosition = readPosition(5)
            $0.savedReadID = "5"
        }

        // ギャップの新しい側の端の22から読み、22より新しい投稿はないので何も変わらない。
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) { _ in }
        try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: .fromNewer) }) {
            $0.entries = entryRows([22, 21, 20, 19]) + [.gap(gap.narrowed(newerID: "19"))] + entryRows([18, 6, 5, 4, 3])
        }
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(Array((3...22).reversed()))
        }

        #expect(Set(ids(store)) == Set(3...22), "最新のページより新しい投稿の間を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    /// 削除でタイムラインが空になったまま補完が読んでいる間に、また補完を求められたら、読み終えた後に同じ基準から読み直す。
    @Test func fillRequestedDuringFillAfterDeletingEveryStatusRunsAfterIt() async throws {
        let server = FakeHomeServer(ids: [10])
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, gated.shouldFail() {
                let page = server.page(query)
                await gate.wait()
                return page
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10])
            $0.oldestLoadedID = "10"
        }
        let fill = try await store.expectChanges(during: { store in
            let fill = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return fill
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        try await store.expectChanges(during: { store in store.receive(.delete(statusID: "10")) }) {
            $0.deletedIDs.insert("10")
            $0.entries = []
        }
        server.post(20...20)
        let requested = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            // タイムラインが空なので、今の補完が読んでいる基準から読み直す。
            $0.refillSinceID = "10"
        }
        #expect(requested == nil)
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await fill.value
        }) {
            $0.isFilling = false
            $0.unfilledSinceID = nil
            $0.refillSinceID = nil
            $0.entries = entryRows([20])
        }

        #expect(ids(store) == [20], "読んでいる間に求められた補完を読みませんでした: \(store.entries.map(\.debugLabel))")
    }

    /// 削除でタイムラインが空になっても、末尾の位置を残す。古いIDの新着が末尾にならず、その上の投稿を読み飛ばさない。
    @Test func deletingEveryStatusKeepsTailPosition() async throws {
        let server = FakeHomeServer(ids: (1...5).map { $0 * 10 })
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([50, 40, 30])
            $0.oldestLoadedID = "30"
        }
        try await store.expectChanges(during: { store in
            for id in ["50", "40", "30"] {
                _ = store.receive(.delete(statusID: id))
            }
        }) {
            $0.deletedIDs = ["50", "40", "30"]
            $0.entries = []
        }
        server.post(5...5)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(5))) }) {
            $0.pending = [server.status(5)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            // 消した投稿も含めた末尾の30より古いので、まだ並べずに取っておく。
            $0.pending = []
            $0.olderArrivals = [server.status(5)]
        }
        server.post(60...60)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(60))) }) {
            $0.pending = [server.status(60)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries = entryRows([60])
        }

        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            // 古い方のページで読んだ5まで末尾が下がり、取っておいた5は読み込み済みになる。
            $0.entries += entryRows([20, 10, 5])
            $0.oldestLoadedID = "5"
            $0.olderArrivals = []
        }
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.reachedEnd = true
        }

        #expect(Set(ids(store)) == [60, 20, 10, 5], "削除した投稿より古い投稿を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    // MARK: - 端の投稿が消えたギャップ

    /// ギャップの新しい側の端の投稿が消えても、補完はその端から読み、同じ範囲にギャップをもう1つ作らない。
    @Test func fillAfterDeletingNewerEndOfGapDoesNotOverlapGaps() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if regenerating.shouldFail() {
                return TimelinePage(statuses: [20, 11].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([20]) + [gapEntry(20, 11)] + entryRows([11])
            $0.oldestLoadedID = "11"
            $0.unfilledSinceID = "20"
            $0.isRegenerating = true
        }
        try await store.expectChanges(during: { store in store.receive(.delete(statusID: "20")) }) {
            $0.deletedIDs.insert("20")
            $0.entries.removeFirst()
        }
        server.post(21...21)

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.unfilledSinceID = nil
            $0.isRegenerating = false
            $0.entries = entryRows([21]) + [gapEntry(20, 11)] + entryRows([11])
        }

        #expect(!hasOverlappingGaps(store), "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
    }

    /// 空のタイムラインの補完と古い方の読み込みが並行して、どちらも作り直し中の応答を受けても、範囲の一部が重なるギャップを残さない。
    @Test func latestPageAndOlderPageDuringRegenerationDoNotOverlapGaps() async throws {
        let server = FakeHomeServer(ids: (1...20).map { $0 * 10 })
        let latestCount = Mutex(0)
        let gate = FetchGate()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil {
                switch latestCount.withLock({ count in count += 1; return count }) {
                case 1:
                    return TimelinePage(statuses: [], isRegenerating: true)
                case 2:
                    await gate.wait()
                    return TimelinePage(statuses: [200, 50].map(server.status), isRegenerating: true)
                default:
                    break
                }
            }
            if query.maxID == "100" {
                return TimelinePage(statuses: [90, 50, 10].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.fillsFromLatestPage = true
            $0.isRegenerating = true
        }
        let fill = try await store.expectChanges(during: { store in
            let fill = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return fill
        }) {
            $0.isFilling = true
        }
        try await store.expectChanges(during: { store in store.receive(.update(server.status(100))) }) {
            $0.pending = [server.status(100)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries = entryRows([100])
            $0.oldestLoadedID = "100"
        }
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries = entryRows([100]) + [gapEntry(100, 10)] + entryRows([90, 50, 10])
            $0.oldestLoadedID = "10"
        }
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await fill.value
        }) {
            $0.isFilling = false
            $0.fillsFromLatestPage = false
            $0.unfilledSinceID = "200"
            // 最新のページの200〜50と、50から末尾の10までのギャップが、100〜10のギャップとまとまる。IDは新しい側の端が最も新しいものを引き継ぐ。
            $0.entries = entryRows([200]) + [.gap(TimelineGap(newerID: "200", olderID: "50").widened(olderID: "10"))] + entryRows([100, 90, 50, 10])
        }

        #expect(!hasOverlappingGaps(store), "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
    }

    /// ギャップを読んでいる間に、ほかの読み込みのギャップとまとまって範囲が広がっても、読んだ範囲の外を読み込み済みにしない。
    @Test func gapWidenedWhileLoadingKeepsUnreadRange() async throws {
        let server = FakeHomeServer(ids: [200, 150, 130, 120, 110, 100, 90, 80, 70, 60, 50])
        let latestCount = Mutex(0)
        let latestGate = FetchGate()
        let gapGate = FetchGate()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, query.sinceID == nil, query.minID == nil {
                switch latestCount.withLock({ count in count += 1; return count }) {
                case 1:
                    return TimelinePage(statuses: [], isRegenerating: true)
                case 2:
                    await latestGate.wait()
                    return TimelinePage(statuses: [150, 50].map(server.status), isRegenerating: true)
                default:
                    break
                }
            }
            if query.maxID == "200", query.sinceID == nil, query.minID == nil {
                return TimelinePage(statuses: [server.status(100)], isRegenerating: true)
            }
            if query.maxID == "200", query.minID == "100" {
                let page = server.page(query)
                await gapGate.wait()
                return page
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.fillsFromLatestPage = true
            $0.isRegenerating = true
        }
        let fill = try await store.expectChanges(during: { store in
            let fill = Task { try await store.fillFromLatest() }
            await latestGate.waitUntilWaiting()
            return fill
        }) {
            $0.isFilling = true
        }
        try await store.expectChanges(during: { store in store.receive(.update(server.status(200))) }) {
            $0.pending = [server.status(200)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries = entryRows([200])
            $0.oldestLoadedID = "200"
        }
        let gap = TimelineGap(newerID: "200", olderID: "100")
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries = entryRows([200]) + [.gap(gap)] + entryRows([100])
            $0.oldestLoadedID = "100"
        }
        // 200から100までのギャップを古い側から読み始め、その応答を待つ間に、最新のページのギャップとまとまって50まで広がる。
        let loading = try await store.expectChanges(during: { store in
            let loading = Task { try await store.loadGap(gap.id, from: .fromOlder) }
            await gapGate.waitUntilWaiting()
            return loading
        }) {
            $0.loadingGapIDs = [gap.id]
        }
        let widened = gap.widened(olderID: "50")
        try await store.expectChanges(during: { store in
            await latestGate.open()
            _ = try await fill.value
        }) {
            $0.isFilling = false
            $0.fillsFromLatestPage = false
            $0.unfilledSinceID = "150"
            $0.entries = entryRows([200]) + [.gap(widened)] + entryRows([150, 100, 50])
            $0.oldestLoadedID = "50"
        }
        try await store.expectChanges(during: { store in
            await gapGate.open()
            _ = try await loading.value
        }) {
            $0.loadingGapIDs = []
            // 読み始めたときより広がったギャップは、端を動かさない。
            $0.entries = entryRows([200]) + [.gap(widened)] + entryRows([150, 130, 120, 110, 100, 50])
        }

        try await store.expectChanges(during: { store in
            for _ in 0..<10 {
                guard let gap = store.gaps.first else { break }
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(server.ids.sorted(by: >))
        }
        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            // ギャップの読み込みは再生成中かを書き換えないので、古い方を読んだここで戻る。
            $0.isRegenerating = false
            $0.reachedEnd = true
        }
        #expect(ids(store) == server.ids.sorted(by: >))
    }

    /// ギャップの古い側の端の投稿が消えても、古い方はその端から読み、同じ範囲にギャップをもう1つ作らない。
    @Test func loadOlderAfterDeletingOlderEndOfGapDoesNotOverlapGaps() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let latestRegenerating = FailOnce()
        let olderRegenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.maxID == nil, latestRegenerating.shouldFail() {
                return TimelinePage(statuses: [20, 11].map(server.status), isRegenerating: true)
            }
            if query.maxID != nil, olderRegenerating.shouldFail() {
                let page = server.page(query)
                return TimelinePage(statuses: [page.statuses.first, page.statuses.last].compactMap(\.self), isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([20]) + [gapEntry(20, 11)] + entryRows([11])
            $0.oldestLoadedID = "11"
            $0.unfilledSinceID = "20"
            $0.isRegenerating = true
        }
        try await store.expectChanges(during: { store in store.receive(.delete(statusID: "11")) }) {
            $0.deletedIDs.insert("11")
            $0.entries.removeLast()
        }

        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            // 消えた11から読み、11から8までをギャップにする。20から11までのギャップとは端が接するだけで、まとめない。
            $0.entries = entryRows([20]) + [gapEntry(20, 11), gapEntry(11, 8)] + entryRows([10, 8])
            $0.oldestLoadedID = "8"
        }

        #expect(!hasOverlappingGaps(store), "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromNewer)
            }
        }) {
            $0.entries = entryRows(Array((8...20).reversed()).filter { $0 != 11 })
        }
    }

    @Test func regeneratingShortPageKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            let page = server.page(query)
            // 最初のギャップの読み込みだけ、再生成中で空の結果にする。
            if query.maxID != nil, regenerating.shouldFail() {
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return page
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...20)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            // 満杯のページなので、続きはギャップの読み込みに任せる。
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
        }
        let gap = try #require(store.gaps.first)

        let loaded = try await store.expectChanges(during: { store in try await store.loadGap(gap.id, from: .fromNewer) }) { _ in }
        #expect(loaded == [])
        #expect(store.gaps.map(\.id) == [gap.id], "再生成中の空の結果でギャップが閉じました")
    }

    @Test func regeneratingFillKeepsBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, regenerating.shouldFail() {
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...12)

        let filled = try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.isRegenerating = true
            $0.unfilledSinceID = "10"
        }
        #expect(filled == [])
        server.post(13...13)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(13))) }) {
            $0.pending = [server.status(13)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([13]), at: 0)
        }
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.isRegenerating = false
            $0.unfilledSinceID = nil
            // 満杯のページなので、11と10の間が空かは、ギャップを読むまで分からない。
            $0.entries = entryRows([13, 12, 11]) + [gapEntry(11, 10)] + entryRows([10, 9, 8])
        }

        #expect(ids(store) == Array((8...13).reversed()))
    }

    @Test func deleteDuringFetchIsNotUndoneByStalePage() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil {
                await gate.wait()
            }
            return server.page(query)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...12)

        let fill = try await store.expectChanges(during: { store in
            let fill = Task { try await store.fillFromLatest() }
            await gate.waitUntilWaiting()
            return fill
        }) {
            $0.isFilling = true
            $0.unfilledSinceID = "10"
        }
        try await store.expectChanges(during: { store in store.receive(.delete(statusID: "12")) }) {
            $0.deletedIDs.insert("12")
        }
        try await store.expectChanges(during: { store in
            await gate.open()
            _ = try await fill.value
        }) {
            $0.isFilling = false
            $0.unfilledSinceID = nil
            $0.entries = entryRows([11, 10, 9, 8])
        }
    }

    #if DEBUG
    /// 検証用のダミーは見れば手元で既読になるが、サーバーへは見た中で最も新しい本物の投稿を保存する。
    @Test func localOnlyStatusesAreNotSavedAsReadPosition() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        // 検証用のIDは状態の外に持つので、状態は変わらない。
        try await store.expectChanges(during: { store in store.debugLocalOnlyIDs = ["100"] }) { _ in }
        try await store.expectChanges(during: { store in store.receive(.update(server.status(100))) }) {
            $0.pending = [server.status(100)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([100]), at: 0)
        }

        try await store.expectChanges(during: { store in store.markRead(["100", "10", "9"]) }) {
            $0.lastReadID = "100"
            $0.lastSavableReadID = "10"
            $0.lastReadPosition = readPosition(100)
        }

        #expect(store.unreadCount == 0)
        #expect(store.readIDToSave == "10")
    }

    /// 検証用に最新の投稿を忘れると、次の補完で取り戻し、1ページを超えた分はギャップになる。
    @Test func forgettingNewestIsRecoveredByFill() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...20)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
        }

        try await store.expectChanges(during: { store in store.debugForgetNewest(3) }) {
            // 忘れた範囲のギャップも消す。
            $0.entries = entryRows([10, 9, 8])
        }

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
        }
    }
    #endif

    // MARK: - 投稿の応答で入れた自分の投稿

    /// 投稿の応答で入れた自分の投稿は、ストリーミングで同じ投稿が届いても重ねない。
    @Test func postedStatusIsNotDuplicatedByStreaming() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...11)

        let posted = try await store.expectChanges(during: { store in store.receivePosted(server.status(11)) }) {
            $0.pending = [server.status(11)]
            $0.unconfirmedPostedIDs = ["11"]
        }
        #expect(posted == .pendingStarted)
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([11]), at: 0)
        }
        let streamed = try await store.expectChanges(during: { store in store.receive(.update(server.status(11))) }) {
            // 並びは変わらないが、ストリーミングで届いたことは確かめた。
            $0.unconfirmedPostedIDs = []
        }
        #expect(streamed == .none)
    }

    /// ストリーミングで届く前の自分の投稿を、補完の基準にしない。
    /// 自分の投稿より前に他の人が投稿し、まだストリーミングで届いていない投稿を、読み飛ばさないため。
    @Test func fillDoesNotSkipStatusesOlderThanUnconfirmedPostedStatus() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...12)
        try await store.expectChanges(during: { store in store.receivePosted(server.status(12)) }) {
            $0.pending = [server.status(12)]
            $0.unconfirmedPostedIDs = ["12"]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([12]), at: 0)
        }

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            // 補完で読めたので、届いたと確かめたことにする。
            $0.unconfirmedPostedIDs = []
            $0.entries = entryRows([12, 11, 10, 9, 8])
        }
    }

    /// ストリーミングで届いたら、ほかの投稿と同じく補完の基準にする。
    @Test func postedStatusConfirmedByStreamingBecomesFillBase() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...11)
        try await store.expectChanges(during: { store in store.receivePosted(server.status(11)) }) {
            $0.pending = [server.status(11)]
            $0.unconfirmedPostedIDs = ["11"]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([11]), at: 0)
        }
        try await store.expectChanges(during: { store in store.receive(.update(server.status(11))) }) {
            $0.unconfirmedPostedIDs = []
        }

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) { _ in }

        #expect(server.queries.last == TimelineQuery(sinceID: "11", limit: Self.pageSize))
    }

    /// 補完で読めたら、そこまでの間は読み終えているので、ストリーミングを待たずに補完の基準にする。
    @Test func postedStatusLoadedByFillBecomesFillBase() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...11)
        try await store.expectChanges(during: { store in store.receivePosted(server.status(11)) }) {
            $0.pending = [server.status(11)]
            $0.unconfirmedPostedIDs = ["11"]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([11]), at: 0)
        }
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.unconfirmedPostedIDs = []
        }

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) { _ in }

        #expect(server.queries.last == TimelineQuery(sinceID: "11", limit: Self.pageSize))
    }

    /// 確かめた投稿が1件もないタイムラインには、応答の投稿を入れずにストリーミングを待つ。
    /// 入れると、補完の基準がないのにタイムラインが空でなくなり、切れていた間の投稿と応答の投稿の間を読まなくなるため。
    @Test func postedStatusIntoEmptyTimelineDoesNotLoseRangeOnReconnect() async throws {
        let server = FakeHomeServer(ids: [])
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.reachedEnd = true
        }
        server.post(1...1)
        let posted = try await store.expectChanges(during: { store in store.receivePosted(server.status(1)) }) { _ in }
        #expect(posted == .none)
        try await store.expectChanges(during: { store in store.flushPending() }) { _ in }
        server.post(2...10)

        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
            $0.reachedEnd = false
        }
        try await store.expectChanges(during: { store in
            while !store.reachedEnd {
                _ = try await store.loadOlder()
            }
        }) {
            $0.entries = entryRows(Array((1...10).reversed()))
            $0.oldestLoadedID = "1"
            $0.reachedEnd = true
        }
    }

    /// 最初の読み込みに失敗したタイムラインに入れると、空でなくなり、読み込み直す代わりに続きを読むようになるため、入れない。
    @Test func postedStatusIsNotInsertedBeforeInitialLoad() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = TimelineStoreTester(pageSize: Self.pageSize) { _ in throw URLError(.networkConnectionLost) }
        try await store.expectChanges(during: { store in _ = try? await store.loadInitial() }) { _ in }

        let posted = try await store.expectChanges(during: { store in store.receivePosted(server.status(11)) }) { _ in }
        #expect(posted == .none)
        #expect(store.isEmpty)
    }

    // MARK: - 既読位置から読み始める

    @Test func markerInLatestPageNeedsNoExtraRequests() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)

        try await store.expectChanges(during: { store in try await store.loadInitial(around: "9") }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
            $0.lastReadID = "9"
            #if DEBUG
            $0.lastSavableReadID = "9"
            #endif
            $0.lastReadPosition = readPosition(9)
            $0.savedReadID = "9"
        }

        #expect(server.queries.count == 1)
        #expect(store.unreadCount == 1)
        #expect(store.readIDToSave == nil, "サーバーにある位置をもう一度保存しようとしています")
    }

    @Test func markerOlderThanLatestPageLoadsAroundItWithGap() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let store = makeStore(server)

        try await store.expectChanges(during: { store in try await store.loadInitial(around: "5") }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 8)] + entryRows([8, 7, 6, 5, 4, 3])
            $0.oldestLoadedID = "3"
            $0.lastReadID = "5"
            #if DEBUG
            $0.lastSavableReadID = "5"
            #endif
            $0.lastReadPosition = readPosition(5)
            $0.savedReadID = "5"
        }
        #expect(server.queries == [
            TimelineQuery(limit: Self.pageSize),
            TimelineQuery(minID: "5", limit: Self.pageSize),
            TimelineQuery(maxID: "6", limit: Self.pageSize),
        ])
        #expect(store.unreadCount == 6)
        #expect(store.hasUnloadedUnread)

        try await store.expectChanges(during: { store in
            while let gap = store.gaps.first {
                _ = try await store.loadGap(gap.id, from: .fromOlder)
            }
        }) {
            $0.entries = entryRows(Array((3...20).reversed()))
        }
        #expect(!store.hasUnloadedUnread)
    }

    /// 新着は今の並びに差し込むが、全件を並べ直したときと同じ並びになる。ギャップの上下、遅れて届いて積んだ投稿、読めなかった行の置き換えを含めて確かめる。
    @Test func insertedArrivalsMatchFullReorder() async throws {
        let server = FakeHomeServer(ids: 1...20, unreadableIDs: [4])
        let store = makeStore(server)
        let unreadable = UnreadableItem(id: "4", url: nil)
        try await store.expectChanges(during: { store in try await store.loadInitial(around: "5") }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 8)] + entryRows([8, 7, 6, 5]) + [.unreadable(unreadable)] + entryRows([3])
            $0.unreadableItems = [unreadable]
            $0.oldestLoadedID = "3"
            $0.lastReadID = "5"
            #if DEBUG
            $0.lastSavableReadID = "5"
            #endif
            $0.lastReadPosition = readPosition(5)
            $0.savedReadID = "5"
        }

        try await store.expectChanges(during: { store in
            for id in [22, 10, 4, 12] {
                _ = store.receive(.update(server.status(id)))
            }
        }) {
            $0.pending = [22, 10, 4, 12].map(server.status)
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            // 10と12は一番上の22の上に届いた順に積み、4は読めなかった行の位置に入れる。
            $0.entries = entryRows([12, 10, 22, 20, 19, 18]) + [gapEntry(18, 8)] + entryRows([8, 7, 6, 5, 4, 3])
            $0.unreadableItems = []
            $0.lateArrivalSequence = 2
            $0.lateArrivalPositions = ["10": readPosition(22, 1), "12": readPosition(22, 2)]
        }

        let edited = Status(id: "19", createdAt: Date(timeIntervalSince1970: 19), account: server.status(19).account, content: "<p>edited</p>", spoilerText: "", url: nil)
        let result = try await store.expectChanges(during: { store in store.receive(.statusUpdate(edited)) }) {
            $0.entries[4] = .status(edited)
        }
        #expect(result == .entriesChanged)
    }

    @Test func markerJustBelowLatestPageLeavesNoGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)

        try await store.expectChanges(during: { store in try await store.loadInitial(around: "5") }) {
            $0.entries = entryRows([10, 9, 8, 7, 6, 5, 4, 3])
            $0.oldestLoadedID = "3"
            $0.lastReadID = "5"
            #if DEBUG
            $0.lastSavableReadID = "5"
            #endif
            $0.lastReadPosition = readPosition(5)
            $0.savedReadID = "5"
        }
    }

    @Test func readPositionIsSavedOnlyWhenItAdvances() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial(around: "8") }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
            $0.lastReadID = "8"
            #if DEBUG
            $0.lastSavableReadID = "8"
            #endif
            $0.lastReadPosition = readPosition(8)
            $0.savedReadID = "8"
        }

        try await store.expectChanges(during: { store in store.markRead(["9"]) }) {
            $0.lastReadID = "9"
            #if DEBUG
            $0.lastSavableReadID = "9"
            #endif
            $0.lastReadPosition = readPosition(9)
        }
        #expect(store.readIDToSave == "9")
        try await store.expectChanges(during: { store in store.markSaved("9") }) {
            $0.savedReadID = "9"
        }
        #expect(store.readIDToSave == nil)

        // 他の端末で先へ読み進めていたら、その位置まで既読にする。
        try await store.expectChanges(during: { store in store.applySavedMarker("10") }) {
            $0.lastReadID = "10"
            #if DEBUG
            $0.lastSavableReadID = "10"
            #endif
            $0.lastReadPosition = readPosition(10)
            $0.savedReadID = "10"
        }
        #expect(store.readIDToSave == nil)
        try await store.expectChanges(during: { store in store.applySavedMarker("7") }) { _ in }
    }

    /// 切断と補完、ギャップの読み込み、古いページの読み込みを、決まった乱数で混ぜても、サーバーと同じ並びになる。
    /// 求めた件数より少なく返すサーバーでも同じ。
    /// 読めない投稿が混ざっていても同じ。読めない投稿は、読めた投稿と同じ位置に並ぶ。
    @Test(arguments: 0..<20, [nil, 2] as [Int?])
    func randomizedSessionsMatchServer(seed: UInt64, maxLimit: Int?) async throws {
        var random = SplitMix64(seed: seed)
        let server = FakeHomeServer(ids: 1...30, maxLimit: maxLimit, unreadableIDs: Set((1...100).filter { $0 % 7 == 0 }))
        // 操作の中身が乱数で決まり、変化を前もって書けないため、包みを通さずにストアを作る。確かめるのは、最後にサーバーと同じ並びになることだけ。
        // scialint:disable:next timeline_store_without_tester
        let store = TimelineStore(pageSize: Self.pageSize) { query in server.page(query) }
        _ = try await store.loadInitial()
        var nextID = 31

        for _ in 0..<12 {
            switch random.next() % 4 {
            case 0:
                // 切断中に投稿が増え、接続し直して補完する。
                let count = Int(random.next() % 10)
                if count > 0 {
                    server.post(nextID...(nextID + count - 1))
                    nextID += count
                }
                _ = try await store.fillFromLatest()
            case 1:
                // 接続中に届いた新着を挿入する。
                server.post(nextID...nextID)
                _ = store.receive(.update(server.status(nextID)))
                _ = store.flushPending()
                nextID += 1
            case 2:
                if let gap = store.gaps.randomElement(using: &random) {
                    _ = try await store.loadGap(gap.id, from: random.next() % 2 == 0 ? .fromNewer : .fromOlder)
                }
            default:
                _ = try await store.loadOlder()
            }
            let shown = itemIDs(store.entries)
            #expect(Set(shown).count == shown.count, "重複があります: \(shown)")
            #expect(shown == shown.sorted(by: >), "IDの順になっていません: \(shown)")
        }

        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: random.next() % 2 == 0 ? .fromNewer : .fromOlder)
        }
        let shown = itemIDs(store.entries)
        let oldest = try #require(shown.last)
        #expect(shown == server.ids.filter { $0 >= oldest }.sorted(by: >), "漏れがあります")
    }

    // MARK: - 遅れて届いた投稿

    /// 遅れて届いて一番上に積んだ投稿があっても、補完と古いページの読み込みは、IDで最も新しい投稿と最も古い投稿を境に読む。
    @Test func lateArrivalOnTopDoesNotShiftPagingBaselines() async throws {
        let server = FakeHomeServer(ids: Array(1...7) + [10, 12, 14])
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([14, 12, 10])
            $0.oldestLoadedID = "10"
        }
        server.post(11...11)
        try await store.expectChanges(during: { store in store.receive(.update(server.status(11))) }) {
            $0.pending = [server.status(11)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([11]), at: 0)
            $0.lateArrivalSequence = 1
            $0.lateArrivalPositions = ["11": readPosition(14, 1)]
        }

        server.post(15...15)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries.insert(contentsOf: entryRows([15]), at: 0)
        }
        #expect(server.queries.last?.sinceID == "14")

        try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries += entryRows([7, 6, 5])
            $0.oldestLoadedID = "5"
        }
        #expect(server.queries.last?.maxID == "10")
    }

    /// ギャップの範囲のIDの投稿が遅れて届いても一番上に積み、ギャップは新しい側の端の投稿のすぐ下に残す。
    @Test func lateArrivalInsideGapRangeStacksOnTopAndKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = entryRows([10, 9, 8])
            $0.oldestLoadedID = "8"
        }
        server.post(11...20)
        try await store.expectChanges(during: { store in try await store.fillFromLatest() }) {
            $0.entries = entryRows([20, 19, 18]) + [gapEntry(18, 10)] + entryRows([10, 9, 8])
        }

        try await store.expectChanges(during: { store in store.receive(.update(server.status(15))) }) {
            $0.pending = [server.status(15)]
        }
        try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            $0.entries.insert(contentsOf: entryRows([15]), at: 0)
            $0.lateArrivalSequence = 1
            $0.lateArrivalPositions = ["15": readPosition(20, 1)]
        }
    }

    /// 状態に書く既読位置や遅れて届いた投稿の位置。
    private func readPosition(_ anchorID: Int, _ sequence: Int = 0) -> TimelineStore.DisplayPosition {
        TimelineStore.DisplayPosition(anchorID: String(anchorID), sequence: sequence)
    }

    private func makeStore(_ server: FakeHomeServer) -> TimelineStoreTester {
        TimelineStoreTester(pageSize: Self.pageSize) { query in server.page(query) }
    }

    private func ids(_ store: TimelineStoreTester) -> [Int] {
        store.statuses.compactMap { Int($0.id) }
    }

    private func hasOverlappingGaps(_ store: TimelineStoreTester) -> Bool {
        let gaps = store.gaps
        return gaps.indices.contains { i in
            gaps.indices.contains { j in
                i != j && StatusID.isNewer(gaps[i].newerID, than: gaps[j].olderID) && StatusID.isNewer(gaps[j].newerID, than: gaps[i].olderID)
            }
        }
    }

    /// 読めなかった投稿も含めた並び。
    private func itemIDs(_ entries: [TimelineEntry]) -> [Int] {
        entries.compactMap { entry in
            switch entry {
            case .status(let status): Int(status.id)
            case .unreadable(let item): Int(item.id)
            case .gap, .notification, .pinned, .account, .notificationRequest, .search: nil
            }
        }
    }
}

/// MastodonのホームタイムラインAPIのページングを再現する。IDは整数で、大きいほど新しい。
final class FakeHomeServer: Sendable {
    private let state: Mutex<(ids: [Int], queries: [TimelineQuery])>
    /// 求められた`limit`より少なく返すサーバーを再現する。nilなら`limit`どおりに返す。
    private let maxLimit: Int?
    /// 読めない投稿として返すID。
    private let unreadableIDs: Set<Int>

    init(ids: [Int], maxLimit: Int? = nil, unreadableIDs: Set<Int> = []) {
        state = Mutex((ids, []))
        self.maxLimit = maxLimit
        self.unreadableIDs = unreadableIDs
    }

    convenience init(ids: ClosedRange<Int>, maxLimit: Int? = nil, unreadableIDs: Set<Int> = []) {
        self.init(ids: Array(ids), maxLimit: maxLimit, unreadableIDs: unreadableIDs)
    }

    var ids: [Int] { state.withLock { $0.ids } }
    var queries: [TimelineQuery] { state.withLock { $0.queries } }

    func post(_ ids: ClosedRange<Int>) {
        state.withLock { $0.ids.append(contentsOf: ids) }
    }

    /// `min_id`があれば、その直後から古い順に`limit`件を取る。なければ新しい側から取る。どちらも新しい順で返す。
    func page(_ query: TimelineQuery) -> TimelinePage {
        let ids = state.withLock { state in
            state.queries.append(query)
            return state.ids
        }
        let upper: Int = query.maxID.flatMap { Int($0) } ?? Int.max
        let lower: Int = max(query.sinceID.flatMap { Int($0) } ?? Int.min, query.minID.flatMap { Int($0) } ?? Int.min)
        let inRange = ids.filter { lower < $0 && $0 < upper }
        let limit = min(query.limit, maxLimit ?? query.limit)
        let picked = query.minID != nil
            ? Array(inRange.sorted().prefix(limit))
            : Array(inRange.sorted(by: >).prefix(limit))
        let sorted = picked.sorted(by: >)
        return TimelinePage(
            statuses: sorted.filter { !unreadableIDs.contains($0) }.map(status),
            unreadable: sorted.filter { unreadableIDs.contains($0) }.map { UnreadableItem(id: String($0), url: nil) },
            isRegenerating: false
        )
    }

    func status(_ id: Int) -> Status {
        Status(
            id: String(id),
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: Self.avatar),
            content: "<p>\(id)</p>",
            spoilerText: "",
            url: nil
        )
    }

    private static let avatar: URL = {
        guard let url = URL(string: "https://example.social/avatars/alice.png") else {
            preconditionFailure("アバターのURLを組み立てられません")
        }
        return url
    }()
}

extension TimelineEntry {
    /// テストで並びを読みやすく比べるための表記。
    var debugLabel: String {
        switch self {
        case .status(let status): status.id
        case .gap(let gap): "gap(\(gap.newerID)...\(gap.olderID))"
        case .notification(let notification): "notification(\(notification.id))"
        case .pinned(let status): "pinned(\(status.id))"
        case .unreadable(let item): "unreadable(\(item.id))"
        case .account(let account): "account(\(account.id))"
        case .notificationRequest(let request): "notificationRequest(\(request.id))"
        case .search(let row): "search(\(row.id))"
        }
    }
}

/// 読み込みを途中で止めておくための門。
actor FetchGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            isWaiting = true
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilWaiting() async {
        if isWaiting { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

/// 1回目だけ失敗させる。
final class FailOnce: Sendable {
    private let hasFailed = Mutex(false)

    func shouldFail() -> Bool {
        hasFailed.withLock { hasFailed in
            defer { hasFailed = true }
            return !hasFailed
        }
    }
}

import Foundation
import Synchronization
import Testing
@testable import SciaCore

/// 切断していた間の補完とギャップの読み込みで、投稿の重複と漏れが起きないことを確かめる。
@MainActor
struct TimelineGapTests {
    private static let pageSize = 3

    // MARK: - 読めない投稿

    /// 1ページの全部が読めなくても、読めなかった投稿のIDから続きを読む。
    @Test func pageOfOnlyUnreadableStatusesDoesNotStopLoadingOlder() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [8, 9, 10])
        let store = makeStore(server)
        _ = try await store.loadInitial()

        #expect(store.entries.map(\.debugLabel) == ["unreadable(10)", "unreadable(9)", "unreadable(8)"])
        #expect(!store.reachedEnd)

        #expect(try await store.loadOlder()?.map(\.id) == ["7", "6", "5"])
        #expect(server.queries.last == TimelineQuery(maxID: "8", limit: Self.pageSize))
    }

    @Test func readableStatusReplacesUnreadableWithSameID() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [9])
        let store = makeStore(server)
        _ = try await store.loadInitial()
        #expect(store.entries.map(\.debugLabel) == ["10", "unreadable(9)", "8"])

        _ = store.receive(.update(server.status(9)))
        _ = store.flushPending()

        #expect(store.entries.map(\.debugLabel) == ["10", "9", "8"])
    }

    @Test func storeWithOnlyUnreadableStatusesIsNotEmpty() async throws {
        let server = FakeHomeServer(ids: 8...10, unreadableIDs: [8, 9, 10])
        let store = makeStore(server)
        _ = try await store.loadInitial()

        #expect(store.statuses.isEmpty)
        #expect(!store.isEmpty, "読めなかった投稿しかないと、画面が空とみなして続きを読みません")
    }

    /// 末尾の読めない投稿と同じIDの投稿が届いたら、末尾より古い投稿を捨てる条件に当てはめず、置き換える。
    @Test func readableStatusReplacesUnreadableAtTail() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [8])
        let store = makeStore(server)
        _ = try await store.loadInitial()
        #expect(store.entries.map(\.debugLabel) == ["10", "9", "unreadable(8)"])

        _ = store.receive(.update(server.status(8)))
        _ = store.flushPending()

        #expect(store.entries.map(\.debugLabel) == ["10", "9", "8"])
    }

    @Test func editedStatusReplacesUnreadable() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [9])
        let store = makeStore(server)
        _ = try await store.loadInitial()

        #expect(store.receive(.statusUpdate(server.status(9))) == .entriesChanged)

        #expect(store.entries.map(\.debugLabel) == ["10", "9", "8"])
    }

    @Test func deletingUnreadableStatusRemovesIt() async throws {
        let server = FakeHomeServer(ids: 1...10, unreadableIDs: [9])
        let store = makeStore(server)
        _ = try await store.loadInitial()

        #expect(store.receive(.delete(statusID: "9")) == .entriesChanged)

        #expect(store.entries.map(\.debugLabel) == ["10", "8"])
    }

    // MARK: - 求めた件数より少なく返すサーバー

    /// 件数が`limit`に届かなくても、それだけでは読み切ったと判断しない。サーバーが件数を丸めていることがあるため。
    @Test func fillDoesNotSkipStatusesWhenServerReturnsFewerThanRequested() async throws {
        let server = FakeHomeServer(ids: 1...10, maxLimit: 2)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...14)

        _ = try await store.fillFromLatest()

        #expect(store.entries.map(\.debugLabel) == ["14", "13", "12", "11", "10", "9"])
    }

    @Test(arguments: [TimelineStore.GapDirection.fromNewer, .fromOlder])
    func gapIsNotClosedByShortPageFromCappingServer(direction: TimelineStore.GapDirection) async throws {
        let server = FakeHomeServer(ids: 1...10, maxLimit: 2)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...30)
        _ = try await store.fillFromLatest()
        let gap = try #require(store.gaps.first)

        _ = try await store.loadGap(gap.id, from: direction)

        #expect(store.gaps.map(\.id) == [gap.id], "読み切っていないギャップが閉じました")
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: direction)
        }
        #expect(ids(store) == Array((9...30).reversed()))
    }

    @Test func markerGapIsKeptWhenServerReturnsFewerThanRequested() async throws {
        let server = FakeHomeServer(ids: 1...20, maxLimit: 2)
        let store = makeStore(server)

        _ = try await store.loadInitial(around: "5")

        #expect(store.entries.map(\.debugLabel) == ["20", "19", "gap(19...7)", "7", "6", "5", "4"])
    }

    @Test func fillWithinOnePageLeavesNoGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...12)

        #expect(try await store.fillFromLatest()?.map(\.id) == ["12", "11"])

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
        _ = try await store.loadInitial()
        server.post(11...20)

        _ = try await store.fillFromLatest()

        #expect(store.entries.map(\.debugLabel) == ["20", "19", "18", "gap(18...10)", "10", "9", "8"])
    }

    @Test func nothingMissedChangesNothing() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()

        #expect(try await store.fillFromLatest() == [])
        #expect(ids(store) == [10, 9, 8])
        #expect(store.gaps.isEmpty)
    }

    @Test func fillReadsUpToPageLimitUntilConnected() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...17)

        _ = try await store.fillFromLatest(maxPages: 3)

        #expect(store.gaps.isEmpty)
        #expect(ids(store) == Array((8...17).reversed()))
    }

    /// 読み込み中の表示に使う。何ページで終わるかは分からないので、1ページ読むたびに、加わった投稿の数を積み上げて渡す。
    @Test func fillReportsAddedCountPerPage() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...17)
        var reported: [Int] = []

        _ = try await store.fillFromLatest(maxPages: 3) { reported.append($0) }

        #expect(reported == [3, 6, 7])
    }

    /// 満杯でないページを取り込んだら、間が空なのを確かめる読み込みを待たずに件数を渡す。確かめるのが遅れても、読んだ分は表示に出す。
    @Test func fillReportsGapPageBeforeConfirming() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let reported = Mutex<[Int]>([])
        let reportedAtConfirmation = Mutex<[Int]?>(nil)
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            let page = server.page(query)
            if query.maxID != nil, query.sinceID != nil, page.isEmpty {
                reportedAtConfirmation.withLock { $0 = reported.withLock { $0 } }
            }
            return page
        }
        _ = try await store.loadInitial()
        server.post(11...17)

        _ = try await store.fillFromLatest(maxPages: 3) { count in reported.withLock { $0.append(count) } }

        #expect(reportedAtConfirmation.withLock { $0 } == [3, 6, 7])
    }

    @Test func fillLeavesGapBeyondPageLimit() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...30)

        _ = try await store.fillFromLatest(maxPages: 2)

        #expect(store.entries.map(\.debugLabel) == ["30", "29", "28", "27", "26", "25", "gap(25...10)", "10", "9", "8"])
    }

    @Test func failureOnLaterFillPageKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.maxID != nil, query.sinceID != nil {
                throw URLError(.networkConnectionLost)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)

        #expect(try await store.fillFromLatest(maxPages: 3)?.map(\.id) == ["20", "19", "18"])

        #expect(store.entries.map(\.debugLabel) == ["20", "19", "18", "gap(18...10)", "10", "9", "8"])
    }

    /// ギャップを読めなかったら、行の中で知らせられるよう、どのギャップがなぜ読めなかったかを残す。読み直せたら消す。
    @Test func failedGapIsRememberedUntilItLoads() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let failsGap = Atomic(false)
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if failsGap.load(ordering: .relaxed), query.maxID != nil {
                throw URLError(.networkConnectionLost)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest(maxPages: 1)
        let gap = try #require(store.gaps.first)
        #expect(store.gapFailures.isEmpty)

        failsGap.store(true, ordering: .relaxed)
        await #expect(throws: URLError.self) { try await store.loadGap(gap.id, from: .fromNewer) }
        #expect(store.gapFailures == [gap.id: ErrorPresentation(URLError(.networkConnectionLost))])

        failsGap.store(false, ordering: .relaxed)
        _ = try await store.loadGap(gap.id, from: .fromNewer)
        #expect(store.gapFailures.isEmpty)
    }

    /// 満杯でないページの後の確かめる読み込みに失敗しても、読めた分は返し、残ったギャップは読めなかったことにする。
    @Test func failedConfirmationKeepsLoadedStatusesAndRemembersFailure() async throws {
        // 求めた件数より少なく返すサーバーで、確かめる読み込みを起こす。
        let server = FakeHomeServer(ids: 1...10, maxLimit: 2)
        let gapLoads = Atomic(0)
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.maxID != nil, query.sinceID != nil, gapLoads.add(1, ordering: .relaxed).newValue == 2 {
                throw URLError(.timedOut)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...30)
        _ = try await store.fillFromLatest(maxPages: 1)
        let gap = try #require(store.gaps.first)
        gapLoads.store(0, ordering: .relaxed)

        let added = try await store.loadGap(gap.id, from: .fromNewer)

        #expect(added?.count == 2)
        #expect(store.gaps.map(\.id) == [gap.id])
        #expect(store.gapFailures == [gap.id: ErrorPresentation(URLError(.timedOut))])
    }

    /// 取り消しは失敗ではないので、読めなかったことにしない。
    @Test func cancelledGapLoadIsNotRememberedAsFailure() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let cancels = Atomic(false)
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if cancels.load(ordering: .relaxed), query.maxID != nil {
                throw CancellationError()
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest(maxPages: 1)
        let gap = try #require(store.gaps.first)

        cancels.store(true, ordering: .relaxed)
        await #expect(throws: CancellationError.self) { try await store.loadGap(gap.id, from: .fromNewer) }
        #expect(store.gapFailures.isEmpty)
    }

    @Test(arguments: [TimelineStore.GapDirection.fromNewer, .fromOlder])
    func loadingGapRepeatedlyClosesItWithoutDuplicatesOrOmissions(direction: TimelineStore.GapDirection) async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()

        var loads = 0
        while let gap = store.gaps.first, loads < 10 {
            _ = try await store.loadGap(gap.id, from: direction)
            loads += 1
        }

        #expect(store.gaps.isEmpty)
        #expect(ids(store) == Array((8...20).reversed()))
    }

    @Test func loadingFromOlderKeepsGapAboveLoadedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()
        let gap = try #require(store.gaps.first)

        #expect(try await store.loadGap(gap.id, from: .fromOlder)?.map(\.id) == ["13", "12", "11"])

        #expect(store.entries.map(\.debugLabel) == ["20", "19", "18", "gap(18...13)", "13", "12", "11", "10", "9", "8"])
        #expect(store.gaps.first?.id == gap.id, "縮んだギャップが別のものとして扱われました")
        #expect(server.queries.last == TimelineQuery(maxID: "18", minID: "10", limit: Self.pageSize))
    }

    @Test func loadingFromNewerKeepsGapBelowLoadedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()
        let gap = try #require(store.gaps.first)

        #expect(try await store.loadGap(gap.id, from: .fromNewer)?.map(\.id) == ["17", "16", "15"])

        #expect(store.entries.map(\.debugLabel) == ["20", "19", "18", "17", "16", "15", "gap(15...10)", "10", "9", "8"])
        #expect(server.queries.last == TimelineQuery(maxID: "18", sinceID: "10", limit: Self.pageSize))
    }

    /// 接続し直してから補完が終わるまでの間に届いた新着が先に挿入されても、その下の区間を読み飛ばさない。
    @Test func streamedArrivalsDuringFillDoNotHideMissedRange() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            // 補完の読み込みだけを止める。ギャップを新しい側から読むときもsince_idが付くため、max_idの有無で区別する。
            if query.sinceID != nil, query.maxID == nil {
                await gate.wait()
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)

        let fill = Task { try await store.fillFromLatest() }
        await gate.waitUntilWaiting()
        server.post(21...21)
        _ = store.receive(.update(server.status(21)))
        _ = store.flushPending()
        await gate.open()
        _ = try await fill.value

        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        #expect(ids(store) == Array((8...21).reversed()))
    }

    /// 補完に失敗した後に新着が挿入されても、次の補完は失敗したときの基準から読む。
    @Test func failedFillIsRetriedFromSameBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let fails = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, fails.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...12)

        await #expect(throws: URLError.self) { _ = try await store.fillFromLatest() }
        server.post(13...13)
        _ = store.receive(.update(server.status(13)))
        _ = store.flushPending()
        _ = try await store.fillFromLatest()

        #expect(server.queries.last?.sinceID == "10")
        #expect(ids(store) == Array((8...13).reversed()))
    }

    /// ストリーミングにつながらないサーバーでは、ポーリングの補完だけが新着を届ける。空のホームでも最新のページを読む。
    @Test func fillOnEmptyTimelineLoadsLatestPage() async throws {
        let server = FakeHomeServer(ids: [])
        let store = TimelineStore(pageSize: Self.pageSize) { server.page($0) }
        _ = try await store.loadInitial()
        #expect(store.isEmpty && store.reachedEnd)
        server.post(1...3)

        let added = try await store.fillFromLatest()

        #expect(added?.map(\.id) == ["3", "2", "1"])
        #expect(store.statuses.map(\.id) == ["3", "2", "1"])
        #expect(store.gaps.isEmpty)
        #expect(!store.reachedEnd, "古い投稿が残っているかもしれないのに、終端としています")
    }

    /// 補完の最中に接続し直しても、同じギャップを2つ作らず、後の要求も終わった後に読む。
    @Test func overlappingFillsAreSerialized() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)

        let first = Task { try await store.fillFromLatest() }
        await gate.waitUntilWaiting()
        #expect(try await store.fillFromLatest() == nil)
        server.post(21...21)
        await gate.open()
        _ = try await first.value

        #expect(Set(store.gaps.map(\.id)).count == store.gaps.count, "同じギャップが重複しています")
        #expect(server.queries.filter { $0.sinceID != nil && $0.maxID == nil }.count == 2)
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        #expect(ids(store) == Array((8...21).reversed()))
    }

    /// 補完の読み込み中に新着が挿入されて補完が重なり、1回目が再生成中で空だったときも、間の投稿を失わない。
    @Test func overlappingFillAfterRegeneratingKeepsBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...12)

        let first = Task { try await store.fillFromLatest() }
        await gate.waitUntilWaiting()
        server.post(13...13)
        _ = store.receive(.update(server.status(13)))
        _ = store.flushPending()
        #expect(try await store.fillFromLatest() == nil)
        await gate.open()
        _ = try await first.value
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        _ = try await store.fillFromLatest()
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }

        #expect(ids(store) == Array((8...13).reversed()))
    }

    /// 重なった補完の2回の読み込みの間に新着が増えても、範囲の重なるギャップを作らない。
    @Test func overlappingFillDoesNotDuplicateGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                let page = server.page(query)
                server.post(21...21)
                return page
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)

        let first = Task { try await store.fillFromLatest() }
        await gate.waitUntilWaiting()
        #expect(try await store.fillFromLatest() == nil)
        await gate.open()
        _ = try await first.value

        #expect(store.gaps.count == 1, "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        #expect(ids(store) == Array((8...21).reversed()))
    }

    /// 補完に失敗した後に最新のページで読み直したら、次の補完は読み直した一覧の最新から読む。
    @Test func reloadAfterFailedFillDropsStaleBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let failing = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, failing.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)
        await #expect(throws: URLError.self) { try await store.fillFromLatest() }

        _ = try await store.loadInitial()
        server.post(21...22)
        _ = try await store.fillFromLatest()

        #expect(store.gaps.isEmpty, "読み込み済みの区間に重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        #expect(ids(store) == Array((18...22).reversed()))
    }

    /// 再生成中のページは揃っていないので、返った投稿の間にも投稿が残りうる。ギャップの端を進めず、後で読み切ったときに読み飛ばさない。
    @Test(arguments: [TimelineStore.GapDirection.fromNewer, .fromOlder])
    func regeneratingPageDoesNotNarrowGap(direction: TimelineStore.GapDirection) async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.maxID != nil, regenerating.shouldFail() {
                let partial = direction == .fromNewer ? [17, 15] : [13, 11]
                return TimelinePage(statuses: partial.map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()
        let gap = try #require(store.gaps.first)
        #expect((gap.newerID, gap.olderID) == ("18", "10"))

        _ = try await store.loadGap(gap.id, from: direction)
        let kept = try #require(store.gaps.first)
        #expect((kept.newerID, kept.olderID) == ("18", "10"), "再生成中のページでギャップの端が進みました")
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: direction)
        }
        #expect(ids(store) == Array((8...20).reversed()))
    }

    /// 補完の読み込みが再生成中で一部の投稿だけを返したら、返った中で最も新しい投稿から下をギャップにして、間の投稿を読み飛ばさない。
    /// 最も新しい投稿より上は、次の補完でそこから読む。
    @Test func regeneratingFillPageKeepsGapBelowNewest() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, regenerating.shouldFail() {
                return TimelinePage(statuses: [13, 11].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)

        _ = try await store.fillFromLatest()
        #expect(ids(store) == Array((8...13).reversed()), "再生成中の結果の間の投稿を読み飛ばしました: \(store.entries.map(\.debugLabel))")

        _ = try await store.fillFromLatest()
        #expect(store.gaps.count <= 1, "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        #expect(ids(store) == Array((8...20).reversed()))
    }

    /// ギャップの中に届いた投稿を既読にしても、その新しい側に読み込んでいない投稿があれば、未読はまだある。
    @Test func readInsideGapStillHasUnloadedUnread() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = TimelineStore(pageSize: Self.pageSize) { server.page($0) }
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()
        let gap = try #require(store.gaps.first)
        #expect((gap.newerID, gap.olderID) == ("18", "10"))

        _ = try await store.loadGap(gap.id, from: .fromOlder)
        store.markRead(["13"])

        #expect(store.hasUnloadedUnread, "14から17を読み込んでいないのに未読なしになりました")
        store.markRead(["18"])
        #expect(!store.hasUnloadedUnread)
    }

    /// 補完の最中に次の補完を受け付けた後で、今の補完が失敗しても、次の補完で受け付けた分まで読む。
    @Test func failedFillAfterOverlapIsRecoveredByNextFill() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let gated = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                throw URLError(.networkConnectionLost)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...12)

        let first = Task { try await store.fillFromLatest() }
        await gate.waitUntilWaiting()
        server.post(13...13)
        _ = store.receive(.update(server.status(13)))
        _ = store.flushPending()
        #expect(try await store.fillFromLatest() == nil)
        await gate.open()
        await #expect(throws: URLError.self) { try await first.value }
        server.post(14...14)

        _ = try await store.fillFromLatest()
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
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
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil, gated.shouldFail() {
                await gate.wait()
                return TimelinePage(statuses: [16, 11].map(server.status), isRegenerating: true)
            }
            if query.maxID != nil, gapRegenerating.shouldFail() {
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)

        let first = Task { try await store.fillFromLatest() }
        await gate.waitUntilWaiting()
        _ = store.receive(.update(server.status(13)))
        _ = store.flushPending()
        #expect(try await store.fillFromLatest() == nil)
        await gate.open()
        _ = try await first.value

        let gaps = store.gaps
        let overlapping = gaps.indices.contains { i in
            gaps.indices.contains { j in
                i != j && StatusID.isNewer(gaps[i].newerID, than: gaps[j].olderID) && StatusID.isNewer(gaps[j].newerID, than: gaps[i].olderID)
            }
        }
        #expect(!overlapping, "範囲の重なるギャップがあります: \(store.entries.map(\.debugLabel))")
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        #expect(ids(store) == Array((8...20).reversed()))
    }

    /// 最新のページで読み直したら再生成中で一部の投稿だけが返っても、返った投稿の間をギャップにして、後で読み切ったときに読み飛ばさない。
    /// 補完に失敗した基準は読み直しで捨てるので、その間の投稿は読み直したページのギャップからしか読めない。
    @Test func regeneratingReloadAfterFailedFillKeepsGapBetweenReturnedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let failing = FailOnce()
        let latestLoads = Mutex(0)
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, failing.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            // 2回目の最新のページ（読み直し）だけ、再生成中で一部の投稿を返す。
            if query.maxID == nil, query.sinceID == nil, query.minID == nil, latestLoads.withLock({ count in count += 1; return count == 2 }) {
                return TimelinePage(statuses: [20, 11].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...20)
        await #expect(throws: URLError.self) { try await store.fillFromLatest() }

        _ = try await store.loadInitial()
        #expect(store.isRegenerating)
        _ = try await store.fillFromLatest()
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        _ = try await store.loadOlder()

        #expect(ids(store) == Array((8...20).reversed()), "再生成中の結果の間の投稿を読み飛ばしました: \(store.entries.map(\.debugLabel))")
    }

    /// 起動して最初の読み込みが再生成中で一部の投稿だけを返しても、返った投稿の間をギャップにする。
    @Test func regeneratingFirstLoadKeepsGapBetweenReturnedStatuses() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let regenerating = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if regenerating.shouldFail() {
                return TimelinePage(statuses: [20, 11].map(server.status), isRegenerating: true)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        let gap = try #require(store.gaps.first, "再生成中の結果の間にギャップがありません: \(store.entries.map(\.debugLabel))")
        #expect((gap.newerID, gap.olderID) == ("20", "11"))

        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        #expect(ids(store) == Array((11...20).reversed()))
    }

    @Test func regeneratingShortPageKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            let page = server.page(query)
            // 最初のギャップの読み込みだけ、再生成中で空の結果にする。
            if query.maxID != nil, regenerating.shouldFail() {
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return page
        }
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()
        let gap = try #require(store.gaps.first)

        #expect(try await store.loadGap(gap.id, from: .fromNewer) == [])
        #expect(store.gaps.map(\.id) == [gap.id], "再生成中の空の結果でギャップが閉じました")
    }

    @Test func regeneratingFillKeepsBaseline() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let regenerating = FailOnce()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, regenerating.shouldFail() {
                return TimelinePage(statuses: [], isRegenerating: true)
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...12)

        #expect(try await store.fillFromLatest() == [])
        #expect(store.isRegenerating, "補完が再生成中の結果を受けたことが残っていません")
        server.post(13...13)
        _ = store.receive(.update(server.status(13)))
        _ = store.flushPending()
        _ = try await store.fillFromLatest()

        #expect(!store.isRegenerating)
        #expect(ids(store) == Array((8...13).reversed()))
    }

    @Test func deleteDuringFetchIsNotUndoneByStalePage() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let gate = FetchGate()
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil, query.maxID == nil {
                await gate.wait()
            }
            return server.page(query)
        }
        _ = try await store.loadInitial()
        server.post(11...12)

        let fill = Task { try await store.fillFromLatest() }
        await gate.waitUntilWaiting()
        _ = store.receive(.delete(statusID: "12"))
        await gate.open()
        _ = try await fill.value

        #expect(ids(store) == [11, 10, 9, 8])
    }

    #if DEBUG
    /// 検証用のダミーは見れば手元で既読になるが、サーバーへは見た中で最も新しい本物の投稿を保存する。
    @Test func localOnlyStatusesAreNotSavedAsReadPosition() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        store.debugLocalOnlyIDs = ["100"]
        _ = store.receive(.update(server.status(100)))
        _ = store.flushPending()

        store.markRead(["100", "10", "9"])

        #expect(store.lastReadID == "100")
        #expect(store.unreadCount == 0)
        #expect(store.readIDToSave == "10")
    }

    /// 検証用に最新の投稿を忘れると、次の補完で取り戻し、1ページを超えた分はギャップになる。
    @Test func forgettingNewestIsRecoveredByFill() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()

        store.debugForgetNewest(3)
        #expect(store.entries.map(\.debugLabel) == ["10", "9", "8"], "忘れた範囲のギャップが残っています")

        _ = try await store.fillFromLatest()
        #expect(store.entries.map(\.debugLabel) == ["20", "19", "18", "gap(18...10)", "10", "9", "8"])
    }
    #endif

    // MARK: - 投稿の応答で入れた自分の投稿

    /// 投稿の応答で入れた自分の投稿は、ストリーミングで同じ投稿が届いても重ねない。
    @Test func postedStatusIsNotDuplicatedByStreaming() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...11)

        #expect(store.receivePosted(server.status(11)) == .pendingStarted)
        _ = store.flushPending()
        #expect(store.receive(.update(server.status(11))) == .none)

        #expect(ids(store) == [11, 10, 9, 8])
    }

    /// ストリーミングで届く前の自分の投稿を、補完の基準にしない。
    /// 自分の投稿より前に他の人が投稿し、まだストリーミングで届いていない投稿を、読み飛ばさないため。
    @Test func fillDoesNotSkipStatusesOlderThanUnconfirmedPostedStatus() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...12)
        _ = store.receivePosted(server.status(12))
        _ = store.flushPending()

        _ = try await store.fillFromLatest()

        #expect(ids(store) == [12, 11, 10, 9, 8])
        #expect(store.gaps.isEmpty)
    }

    /// ストリーミングで届いたら、ほかの投稿と同じく補完の基準にする。
    @Test func postedStatusConfirmedByStreamingBecomesFillBase() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...11)
        _ = store.receivePosted(server.status(11))
        _ = store.flushPending()
        _ = store.receive(.update(server.status(11)))

        _ = try await store.fillFromLatest()

        #expect(server.queries.last == TimelineQuery(sinceID: "11", limit: Self.pageSize))
    }

    /// 補完で読めたら、そこまでの間は読み終えているので、ストリーミングを待たずに補完の基準にする。
    @Test func postedStatusLoadedByFillBecomesFillBase() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...11)
        _ = store.receivePosted(server.status(11))
        _ = store.flushPending()
        _ = try await store.fillFromLatest()

        _ = try await store.fillFromLatest()

        #expect(server.queries.last == TimelineQuery(sinceID: "11", limit: Self.pageSize))
    }

    /// 確かめた投稿が1件もない一覧には、応答の投稿を入れずにストリーミングを待つ。
    /// 入れると、補完の基準がないのに一覧が空でなくなり、切れていた間の投稿と応答の投稿の間を読まなくなるため。
    @Test func postedStatusIntoEmptyTimelineDoesNotLoseRangeOnReconnect() async throws {
        let server = FakeHomeServer(ids: [])
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(1...1)
        _ = store.receivePosted(server.status(1))
        _ = store.flushPending()
        server.post(2...10)

        _ = try await store.fillFromLatest()
        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromNewer)
        }
        while !store.reachedEnd {
            _ = try await store.loadOlder()
        }

        #expect(ids(store) == Array((1...10).reversed()))
    }

    /// 最初の読み込みに失敗した一覧に入れると、空でなくなり、読み込み直す代わりに続きを読むようになるため、入れない。
    @Test func postedStatusIsNotInsertedBeforeInitialLoad() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = TimelineStore(pageSize: Self.pageSize) { _ in throw URLError(.networkConnectionLost) }
        _ = try? await store.loadInitial()

        #expect(store.receivePosted(server.status(11)) == .none)
        #expect(store.isEmpty)
    }

    // MARK: - 既読位置から読み始める

    @Test func markerInLatestPageNeedsNoExtraRequests() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)

        _ = try await store.loadInitial(around: "9")

        #expect(ids(store) == [10, 9, 8])
        #expect(server.queries.count == 1)
        #expect(store.lastReadID == "9")
        #expect(store.unreadCount == 1)
        #expect(store.readIDToSave == nil, "サーバーにある位置をもう一度保存しようとしています")
    }

    @Test func markerOlderThanLatestPageLoadsAroundItWithGap() async throws {
        let server = FakeHomeServer(ids: 1...20)
        let store = makeStore(server)

        _ = try await store.loadInitial(around: "5")

        #expect(store.entries.map(\.debugLabel) == ["20", "19", "18", "gap(18...8)", "8", "7", "6", "5", "4", "3"])
        #expect(server.queries == [
            TimelineQuery(limit: Self.pageSize),
            TimelineQuery(minID: "5", limit: Self.pageSize),
            TimelineQuery(maxID: "6", limit: Self.pageSize),
        ])
        #expect(store.unreadCount == 6)
        #expect(store.hasUnloadedUnread)

        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: .fromOlder)
        }
        #expect(ids(store) == Array((3...20).reversed()))
        #expect(!store.hasUnloadedUnread)
    }

    /// 新着は今の並びに差し込むが、全件を並べ直したときと同じ並びになる。ギャップの上下、遅れて届いて積んだ投稿、読めなかった行の置き換えを含めて確かめる。
    @Test func insertedArrivalsMatchFullReorder() async throws {
        let server = FakeHomeServer(ids: 1...20, unreadableIDs: [4])
        let store = makeStore(server)
        _ = try await store.loadInitial(around: "5")
        #expect(store.entries.map(\.debugLabel) == ["20", "19", "18", "gap(18...8)", "8", "7", "6", "5", "unreadable(4)", "3"])

        for id in [22, 10, 4, 12] {
            _ = store.receive(.update(server.status(id)))
        }
        _ = store.flushPending()
        let inserted = store.entries.map(\.debugLabel)
        #expect(inserted == ["12", "10", "22", "20", "19", "18", "gap(18...8)", "8", "7", "6", "5", "4", "3"])

        let edited = Status(id: "19", createdAt: Date(timeIntervalSince1970: 19), account: server.status(19).account, content: "<p>edited</p>", spoilerText: "", url: nil)
        #expect(store.receive(.statusUpdate(edited)) == .entriesChanged)
        #expect(store.entries.map(\.debugLabel) == inserted)
    }

    @Test func markerJustBelowLatestPageLeavesNoGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)

        _ = try await store.loadInitial(around: "5")

        #expect(store.entries.map(\.debugLabel) == ["10", "9", "8", "7", "6", "5", "4", "3"])
    }

    @Test func readPositionIsSavedOnlyWhenItAdvances() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial(around: "8")

        store.markRead(["9"])
        #expect(store.readIDToSave == "9")
        store.markSaved("9")
        #expect(store.readIDToSave == nil)

        // 他の端末で先へ読み進めていたら、その位置まで既読にする。
        store.applySavedMarker("10")
        #expect(store.lastReadID == "10")
        #expect(store.readIDToSave == nil)
        store.applySavedMarker("7")
        #expect(store.lastReadID == "10")
    }

    /// 切断と補完、ギャップの読み込み、古いページの読み込みを、決まった乱数で混ぜても、サーバーと同じ並びになる。
    /// 求めた件数より少なく返すサーバーでも同じ。
    /// 読めない投稿が混ざっていても同じ。読めない投稿は、読めた投稿と同じ位置に並ぶ。
    @Test(arguments: 0..<20, [nil, 2] as [Int?])
    func randomizedSessionsMatchServer(seed: UInt64, maxLimit: Int?) async throws {
        var random = SplitMix64(seed: seed)
        let server = FakeHomeServer(ids: 1...30, maxLimit: maxLimit, unreadableIDs: Set((1...100).filter { $0 % 7 == 0 }))
        let store = makeStore(server)
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
            let shown = itemIDs(store)
            #expect(Set(shown).count == shown.count, "重複があります: \(shown)")
            #expect(shown == shown.sorted(by: >), "IDの順になっていません: \(shown)")
        }

        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: random.next() % 2 == 0 ? .fromNewer : .fromOlder)
        }
        let shown = itemIDs(store)
        let oldest = try #require(shown.last)
        #expect(shown == server.ids.filter { $0 >= oldest }.sorted(by: >), "漏れがあります")
    }

    // MARK: - 遅れて届いた投稿

    /// 遅れて届いて一番上に積んだ投稿があっても、補完と古いページの読み込みは、IDで最も新しい投稿と最も古い投稿を境に読む。
    @Test func lateArrivalOnTopDoesNotShiftPagingBaselines() async throws {
        let server = FakeHomeServer(ids: Array(1...7) + [10, 12, 14])
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...11)
        _ = store.receive(.update(server.status(11)))
        _ = store.flushPending()
        #expect(ids(store) == [11, 14, 12, 10])

        server.post(15...15)
        _ = try await store.fillFromLatest()
        #expect(server.queries.last?.sinceID == "14")
        #expect(ids(store) == [15, 11, 14, 12, 10])

        _ = try await store.loadOlder()
        #expect(server.queries.last?.maxID == "10")
        #expect(ids(store) == [15, 11, 14, 12, 10, 7, 6, 5])
    }

    /// ギャップの範囲のIDの投稿が遅れて届いても一番上に積み、ギャップは新しい側の端の投稿のすぐ下に残す。
    @Test func lateArrivalInsideGapRangeStacksOnTopAndKeepsGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...20)
        _ = try await store.fillFromLatest()
        let gap = try #require(store.gaps.first)

        _ = store.receive(.update(server.status(15)))
        _ = store.flushPending()

        #expect(store.entries.map(\.debugLabel) == ["15", "20", "19", "18", TimelineEntry.gap(gap).debugLabel, "10", "9", "8"])
    }

    private func makeStore(_ server: FakeHomeServer) -> TimelineStore {
        TimelineStore(pageSize: Self.pageSize) { query in server.page(query) }
    }

    private func ids(_ store: TimelineStore) -> [Int] {
        store.statuses.compactMap { Int($0.id) }
    }

    /// 読めなかった投稿も含めた並び。
    private func itemIDs(_ store: TimelineStore) -> [Int] {
        store.entries.compactMap { entry in
            switch entry {
            case .status(let status): Int(status.id)
            case .unreadable(let item): Int(item.id)
            case .gap, .notification, .pinned: nil
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

/// 試行ごとに同じ列を返す乱数。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
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

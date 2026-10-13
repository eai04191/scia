import Foundation
import Synchronization
import Testing
@testable import SciaCore

/// 切断していた間の補完とギャップの読み込みで、投稿の重複と漏れが起きないことを確かめる。
@MainActor
struct TimelineGapTests {
    private static let pageSize = 3

    @Test func fillWithinOnePageLeavesNoGap() async throws {
        let server = FakeHomeServer(ids: 1...10)
        let store = makeStore(server)
        _ = try await store.loadInitial()
        server.post(11...12)

        #expect(try await store.fillFromLatest()?.map(\.id) == ["12", "11"])

        #expect(store.gaps.isEmpty)
        #expect(ids(store) == [12, 11, 10, 9, 8])
        #expect(server.queries.last == TimelineQuery(sinceID: "10", limit: Self.pageSize))
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
        server.post(13...13)
        _ = store.receive(.update(server.status(13)))
        _ = store.flushPending()
        _ = try await store.fillFromLatest()

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
    @Test(arguments: 0..<20)
    func randomizedSessionsMatchServer(seed: UInt64) async throws {
        var random = SplitMix64(seed: seed)
        let server = FakeHomeServer(ids: 1...30)
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
            let shown = ids(store)
            #expect(Set(shown).count == shown.count, "重複があります: \(shown)")
            #expect(shown == shown.sorted(by: >), "IDの順になっていません: \(shown)")
        }

        while let gap = store.gaps.first {
            _ = try await store.loadGap(gap.id, from: random.next() % 2 == 0 ? .fromNewer : .fromOlder)
        }
        let shown = ids(store)
        let oldest = try #require(shown.last)
        #expect(shown == server.ids.filter { $0 >= oldest }.sorted(by: >), "漏れがあります")
    }

    private func makeStore(_ server: FakeHomeServer) -> TimelineStore {
        TimelineStore(pageSize: Self.pageSize) { query in server.page(query) }
    }

    private func ids(_ store: TimelineStore) -> [Int] {
        store.statuses.compactMap { Int($0.id) }
    }
}

/// MastodonのホームタイムラインAPIのページングを再現する。IDは整数で、大きいほど新しい。
final class FakeHomeServer: Sendable {
    private let state: Mutex<(ids: [Int], queries: [TimelineQuery])>

    init(ids: ClosedRange<Int>) {
        state = Mutex((Array(ids), []))
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
        let picked = query.minID != nil
            ? Array(inRange.sorted().prefix(query.limit))
            : Array(inRange.sorted(by: >).prefix(query.limit))
        return TimelinePage(statuses: picked.sorted(by: >).map(status), isRegenerating: false)
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

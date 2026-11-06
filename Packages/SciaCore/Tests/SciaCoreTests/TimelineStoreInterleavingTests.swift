import Foundation
import Testing
@testable import SciaCore

/// 読み込み、補完、ギャップの読み込み、ストリーミング、切断を乱数で決めた順に重ね、投稿の重複と漏れが起きないことを確かめる。
///
/// 決まった手順を書くテストは、書いた人が思いついた順序しか試せない。ここでは、サーバーへの要求を1件ずつ止めておき、
/// どの要求にどの順で、どんな応答（件数を減らす、再生成中、失敗）を返すかと、その間に起きるストリーミングのイベントを乱数で決める。
/// 1手ごとに、いつでも成り立つべき性質を確かめ、最後に、つなぎ直して読み切れば、サーバーの投稿がちょうど揃うことを確かめる。
/// 手は、アプリが`TimelineStore`を呼ぶ順に合わせる（ストリーミングは最初の読み込みを終えてからつなぐ、など）。
/// 失敗したら、最初に失敗した乱数のseedと手順を残す。環境変数`SCIA_INTERLEAVING_SEED`にseedを入れると、そのseedだけを走らせる。
@MainActor
struct TimelineStoreInterleavingTests {
    private static let pageSize = 3
    private static let steps = 40
    private static let seeds: Range<UInt64> = 0..<500

    @Test func randomInterleavingsKeepEveryStatus() async throws {
        if let seed = ProcessInfo.processInfo.environment["SCIA_INTERLEAVING_SEED"].flatMap(UInt64.init) {
            if let failure = await Self.run(seed: seed) {
                Issue.record("\(failure)")
            }
            return
        }
        var first: Failure?
        var failedCount = 0
        for seed in Self.seeds {
            guard let failure = await Self.run(seed: seed) else { continue }
            first = first ?? failure
            failedCount += 1
        }
        if let first {
            Issue.record("\(Self.seeds.count)回のうち\(failedCount)回で失敗しました。\(first)")
        }
    }

    // MARK: - 1回の試行

    private struct Failure: CustomStringConvertible {
        let seed: UInt64
        let reason: String
        let trace: [String]
        let entries: [String]

        var description: String {
            "seed \(seed)で\(reason)\n並び: \(entries.joined(separator: " "))\n手順:\n" + trace.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        }
    }

    private static func run(seed: UInt64) async -> Failure? {
        var random = SplitMix64(seed: seed)
        let server = InterleavingServer(initialCount: Int.random(in: 0...15, using: &random))
        let store = TimelineStore(pageSize: pageSize, now: { Date(timeIntervalSince1970: 0) }) { query in
            try await server.fetch(query)
        }
        var trace: [String] = []
        let client = ClientState()

        func failure(_ reason: String) -> Failure {
            Failure(seed: seed, reason: reason, trace: trace, entries: store.entries.map(\.debugLabel))
        }

        let marker = Bool.random(using: &random) ? server.ids.sorted().randomElement(using: &random).map(String.init) : nil
        trace.append("loadInitial(around: \(marker ?? "nil"))")
        server.start {
            if try await store.loadInitial(around: marker) != nil { client.hasLoadedInitial = true }
        }
        await server.settled()

        for _ in 0..<steps {
            let action = Action.random(using: &random)
            switch action {
            case .respond:
                guard !server.requests.isEmpty else { continue }
                let index = Int.random(in: server.requests.indices, using: &random)
                let response = Response.random(using: &random)
                trace.append("respond(\(server.requests[index].label), \(response))")
                server.respond(index, with: response, using: &random)
            case .fill:
                guard client.hasLoadedInitial else { continue }
                let maxPages = Int.random(in: 1...3, using: &random)
                trace.append("fillFromLatest(maxPages: \(maxPages))")
                server.start { _ = try await store.fillFromLatest(maxPages: maxPages) }
            case .loadOlder:
                guard client.hasLoadedInitial else { continue }
                trace.append("loadOlder")
                server.start { _ = try await store.loadOlder() }
            case .loadGap:
                guard client.hasLoadedInitial, let gap = store.gaps.randomElement(using: &random) else { continue }
                let direction: TimelineStore.GapDirection = Bool.random(using: &random) ? .fromNewer : .fromOlder
                trace.append("loadGap(\(TimelineEntry.gap(gap).debugLabel), \(direction))")
                server.start { _ = try await store.loadGap(gap.id, from: direction) }
            case .reload:
                // アプリは、最初の読み込みに失敗したときだけ、最初の読み込みからやり直す。
                guard !client.hasLoadedInitial else { continue }
                trace.append("loadInitial")
                server.start {
                    if try await store.loadInitial() != nil { client.hasLoadedInitial = true }
                }
            case .post:
                let id = server.post()
                trace.append("post(\(id))\(client.isConnected ? "" : " 切断中")")
                if client.isConnected {
                    _ = store.receive(.update(server.status(id)))
                }
            case .latePost:
                // ほかのサーバーから遅れて届く投稿。切断中に投稿されると、Mastodonの補完では読めないので、つないでいるときだけ起こす。
                guard client.isConnected, let id = server.postLate(using: &random) else { continue }
                trace.append("latePost(\(id))")
                _ = store.receive(.update(server.status(id)))
            case .delete:
                // 切断中の削除は、Mastodonの補完では知る手段がないので、つないでいるときだけ起こす。
                guard client.isConnected, let id = server.ids.sorted().randomElement(using: &random) else { continue }
                trace.append("delete(\(id))")
                server.delete(id)
                _ = store.receive(.delete(statusID: String(id)))
            case .flush:
                guard client.hasLoadedInitial else { continue }
                trace.append("flushPending")
                _ = store.flushPending()
            case .disconnect:
                guard client.isConnected else { continue }
                trace.append("disconnect")
                client.isConnected = false
            case .reconnect:
                // アプリは、最初の読み込みを終えてからストリーミングにつなぎ、つないだら切れていた間を補完する。
                guard client.hasLoadedInitial, !client.isConnected else { continue }
                trace.append("reconnect")
                client.isConnected = true
                server.start { _ = try await store.fillFromLatest() }
            }
            await server.settled()
            if let reason = violation(in: store, server: server) {
                return failure(reason)
            }
        }

        trace.append("--- 読み切る ---")
        await settleEverything(store: store, server: server)
        if let reason = violation(in: store, server: server) {
            return failure(reason)
        }
        let loaded = store.statuses.compactMap { Int($0.id) }
        if !store.gaps.isEmpty {
            return failure("読み切ったあとにギャップが残りました")
        }
        let missing = server.ids.subtracting(loaded)
        if !missing.isEmpty {
            return failure("読み切っても、サーバーの投稿\(missing.sorted(by: >))がタイムラインにありません")
        }
        return nil
    }

    /// 止めている要求に正しく答え、補完、ギャップ、古い方を読み切る。
    private static func settleEverything(store: TimelineStore, server: InterleavingServer) async {
        await server.drain()
        if store.isEmpty {
            await server.complete { _ = try await store.loadInitial() }
        }
        _ = store.flushPending()
        for _ in 0..<100 {
            await server.complete { _ = try await store.fillFromLatest() }
            while let gap = store.gaps.first {
                await server.complete { _ = try await store.loadGap(gap.id, from: .fromNewer) }
            }
            let before = store.statuses.count
            await server.complete { _ = try await store.fillFromLatest() }
            if store.gaps.isEmpty, store.statuses.count == before { break }
        }
        while !store.reachedEnd, !store.isEmpty {
            let before = store.statuses.count
            await server.complete { _ = try await store.loadOlder() }
            if store.statuses.count == before, !store.reachedEnd { break }
        }
        _ = store.flushPending()
    }

    /// どの時点でも成り立つべき性質のうち、破れているものを返す。
    private static func violation(in store: TimelineStore, server: InterleavingServer) -> String? {
        let ids = store.statuses.map(\.id)
        if Set(ids).count != ids.count {
            return "同じ投稿が2回並びました"
        }
        if let deleted = ids.compactMap(Int.init).first(where: { server.deletedIDs.contains($0) }) {
            return "削除した投稿\(deleted)が並んでいます"
        }
        let gaps = store.gaps.compactMap { gap in Int(gap.olderID).flatMap { older in Int(gap.newerID).map { (older: older, newer: $0, gap: gap) } } }
        if let reversed = gaps.first(where: { $0.older >= $0.newer }) {
            return "ギャップ\(TimelineEntry.gap(reversed.gap).debugLabel)の両端が逆です"
        }
        for (index, lhs) in gaps.enumerated() {
            for rhs in gaps[(index + 1)...] where max(lhs.older, rhs.older) + 1 < min(lhs.newer, rhs.newer) {
                return "ギャップ\(TimelineEntry.gap(lhs.gap).debugLabel)と\(TimelineEntry.gap(rhs.gap).debugLabel)が重なりました"
            }
        }
        return nil
    }

    // MARK: - 手と応答

    /// アプリの側の状態。アプリと同じ順でしか手を打たないようにする。
    @MainActor
    private final class ClientState {
        var hasLoadedInitial = false
        var isConnected = false
    }

    private enum Action {
        case respond, fill, loadOlder, loadGap, reload, post, latePost, delete, flush, disconnect, reconnect

        /// 要求に答える手を多めにし、読み込みが進むようにする。
        static func random(using random: inout SplitMix64) -> Action {
            let weighted: [(Action, Int)] = [
                (.respond, 8), (.fill, 2), (.loadOlder, 1), (.loadGap, 2), (.reload, 1),
                (.post, 3), (.latePost, 1), (.delete, 1), (.flush, 2), (.disconnect, 1), (.reconnect, 1),
            ]
            var roll = Int.random(in: 0..<weighted.map(\.1).reduce(0, +), using: &random)
            for (action, weight) in weighted {
                if roll < weight { return action }
                roll -= weight
            }
            return .respond
        }
    }

    enum Response: CustomStringConvertible {
        /// 求めた件数どおりに返す。
        case full
        /// 求めた件数より少なく返す。件数を丸めるサーバーと同じく、返すのは正しい端からの一部。
        case short
        /// ホームを再生成中で、投稿の一部だけを持つタイムラインから返す。
        case regenerating
        case failure

        static func random(using random: inout SplitMix64) -> Response {
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<5: .full
            case 5..<7: .short
            case 7..<9: .regenerating
            default: .failure
            }
        }

        var description: String {
            switch self {
            case .full: "full"
            case .short: "short"
            case .regenerating: "regenerating"
            case .failure: "failure"
            }
        }
    }
}

/// 要求を止めておき、テストが選んだ順と応答で返すホームのサーバー。IDは整数で、大きいほど新しい。
/// 応答は要求を受けた時点の投稿から作る。サーバーが受けてすぐ処理し、返るまでの間に投稿や削除が起きた場合と同じになる。
@MainActor
final class InterleavingServer {
    struct Request {
        let query: TimelineQuery
        /// 要求を受けた時点の投稿。
        let snapshot: Set<Int>
        let continuation: CheckedContinuation<TimelinePage, any Error>

        var label: String {
            [("max", query.maxID), ("since", query.sinceID), ("min", query.minID)]
                .compactMap { name, value in value.map { "\(name):\($0)" } }
                .joined(separator: ",")
        }
    }

    private(set) var ids: Set<Int>
    private(set) var deletedIDs: Set<Int> = []
    private(set) var requests: [Request] = []
    /// 始めて、まだ終わっていない操作の数。
    private var running = 0
    private var settleWaiter: CheckedContinuation<Void, Never>?
    private var nextID: Int

    /// 投稿のIDは10ずつ空け、遅れて届く投稿に古いIDを振れるようにする。
    init(initialCount: Int) {
        ids = Set((0..<initialCount).map { ($0 + 1) * 10 })
        nextID = (initialCount + 1) * 10
    }

    func fetch(_ query: TimelineQuery) async throws -> TimelinePage {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(query: query, snapshot: ids, continuation: continuation))
            notifyIfSettled()
        }
    }

    /// 操作を始める。失敗は、アプリと同じく呼び出し元で捨てる。
    func start(_ operation: @escaping @MainActor () async throws -> Void) {
        running += 1
        Task { @MainActor in
            try? await operation()
            running -= 1
            notifyIfSettled()
        }
    }

    /// 始めた操作が、どれも終わったかサーバーの応答を待つまで待つ。操作は応答のほかに待つものがなく、1つの操作は一度に1件しか要求しないため、
    /// 終わっていない操作の数と止めている要求の数が揃えば、テストが答えるまで何も進まない。
    func settled() async {
        guard !isSettled else { return }
        await withCheckedContinuation { settleWaiter = $0 }
    }

    /// 止めている要求に正しく答え続け、始めた操作をすべて終える。
    func drain() async {
        await settled()
        while !requests.isEmpty {
            var unused = SplitMix64(seed: 0)
            respond(0, with: .full, using: &unused)
            await settled()
        }
    }

    /// 操作を始め、正しく答えて終えるまで待つ。
    func complete(_ operation: @escaping @MainActor () async throws -> Void) async {
        start(operation)
        await drain()
    }

    private var isSettled: Bool { running == requests.count }

    private func notifyIfSettled() {
        guard isSettled, let settleWaiter else { return }
        self.settleWaiter = nil
        settleWaiter.resume()
    }

    func respond(_ index: Int, with response: TimelineStoreInterleavingTests.Response, using random: inout SplitMix64) {
        let request = requests.remove(at: index)
        switch response {
        case .failure:
            request.continuation.resume(throwing: URLError(.notConnectedToInternet))
        case .full:
            request.continuation.resume(returning: page(request.query, from: request.snapshot, isRegenerating: false))
        case .short:
            let full = picks(request.query, from: request.snapshot)
            let count = full.count < 2 ? full.count : Int.random(in: 1..<full.count, using: &random)
            request.continuation.resume(returning: page(of: Array(full.prefix(count)), isRegenerating: false))
        case .regenerating:
            let partial = Set(request.snapshot.sorted().filter { _ in Bool.random(using: &random) })
            request.continuation.resume(returning: page(request.query, from: partial, isRegenerating: true))
        }
    }

    func post() -> Int {
        let id = nextID
        nextID += 10
        ids.insert(id)
        return id
    }

    /// 今ある投稿より古いIDの投稿を足す。使えるIDがなければnil。
    func postLate(using random: inout SplitMix64) -> Int? {
        guard let newest = ids.max(), newest > 2 else { return nil }
        let id = Int.random(in: 1..<newest, using: &random)
        guard !ids.contains(id), !deletedIDs.contains(id) else { return nil }
        ids.insert(id)
        return id
    }

    func delete(_ id: Int) {
        ids.remove(id)
        deletedIDs.insert(id)
    }

    /// Mastodonのページングと同じく、`min_id`があればその直後から、なければ新しい側から`limit`件を、サーバーが返す端の順に取る。
    private func picks(_ query: TimelineQuery, from ids: Set<Int>) -> [Int] {
        let upper = query.maxID.flatMap { Int($0) } ?? Int.max
        let lower = max(query.sinceID.flatMap { Int($0) } ?? Int.min, query.minID.flatMap { Int($0) } ?? Int.min)
        let inRange = ids.filter { lower < $0 && $0 < upper }
        return query.minID != nil
            ? Array(inRange.sorted().prefix(query.limit))
            : Array(inRange.sorted(by: >).prefix(query.limit))
    }

    private func page(_ query: TimelineQuery, from ids: Set<Int>, isRegenerating: Bool) -> TimelinePage {
        page(of: picks(query, from: ids), isRegenerating: isRegenerating)
    }

    private func page(of ids: [Int], isRegenerating: Bool) -> TimelinePage {
        TimelinePage(statuses: ids.sorted(by: >).map(status), isRegenerating: isRegenerating)
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

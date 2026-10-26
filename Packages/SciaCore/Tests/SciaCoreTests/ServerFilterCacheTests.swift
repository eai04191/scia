import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct ServerFilterCacheTests {
    /// 読まれた回数を数え、`holds`なら`release()`まで返さない。返す一覧は、読まれた時点の`titles`で作る。
    private final class Server: Sendable {
        private let state: Mutex<(requests: Int, titles: [String], failing: Bool)>
        let gate: Gate?

        init(titles: [String], holds: Bool = false) {
            state = Mutex((0, titles, false))
            gate = holds ? Gate() : nil
        }

        var requests: Int { state.withLock { $0.requests } }

        func setTitles(_ titles: [String]) {
            state.withLock { $0.titles = titles }
        }

        func fail(_ failing: Bool) {
            state.withLock { $0.failing = failing }
        }

        func fetch() async throws -> [ServerFilter] {
            // 読まれた時点の中身で返す。止めている間に中身を変えても、この読み込みは古い中身を返す。
            let (titles, failing) = state.withLock { state in
                state.requests += 1
                return (state.titles, state.failing)
            }
            if let gate { try await gate.wait() }
            if failing { throw URLError(.notConnectedToInternet) }
            return titles.map { ServerFilter(id: $0, title: $0, context: [.home], filterAction: .hide, expiresAt: nil, keywords: []) }
        }
    }

    private func makeCache(_ server: Server) -> ServerFilterCache {
        ServerFilterCache { try await server.fetch() }
    }

    /// 読んでいなければ、求められたときに読む。読んだ一覧は覚え、次は送らずに返す。
    @Test func latestLoadsOnceAndRemembers() async throws {
        let server = Server(titles: ["a"])
        let cache = makeCache(server)

        #expect(cache.filters == nil)
        #expect(try await cache.latest().map(\.title) == ["a"])
        #expect(try await cache.latest().map(\.title) == ["a"])
        #expect(cache.filters?.map(\.title) == ["a"])
        #expect(server.requests == 1)
    }

    /// メニューを開くたびの読み直しは、読み直している途中なら重ねて送らない。読み終えるまでは、覚えている一覧をそのまま返す。
    @Test func refreshDoesNotOverlapAndKeepsKnownFilters() async throws {
        let server = Server(titles: ["a"])
        let cache = makeCache(server)
        _ = try await cache.latest()
        server.setTitles(["a", "b"])

        cache.refresh()
        cache.refresh()
        #expect(cache.filters?.map(\.title) == ["a"])
        #expect(try await cache.latest().map(\.title) == ["a", "b"])
        #expect(server.requests == 2)
    }

    /// フィルターを変えたあとの読み直しは、変える前に始めた読み直しの応答で古い一覧に戻さない。待っている側は、新しい読み直しの結果を受け取る。
    @Test func reloadSupersedesEarlierReload() async throws {
        let server = Server(titles: ["old"], holds: true)
        let cache = makeCache(server)
        cache.refresh()
        try await waitUntil { server.requests == 1 }
        let waiting = Task { try await cache.latest() }

        server.setTitles(["new"])
        cache.reload()
        try await waitUntil { server.requests == 2 }
        try #require(server.gate).open()

        #expect(try await waiting.value.map(\.title) == ["new"])
        #expect(cache.filters?.map(\.title) == ["new"])
    }

    /// 読めなかったら、覚えている一覧を残して投げる。
    @Test func failureKeepsKnownFilters() async throws {
        let server = Server(titles: ["a"])
        let cache = makeCache(server)
        _ = try await cache.latest()
        server.fail(true)

        cache.reload()
        await #expect(throws: URLError.self) { try await cache.latest() }
        #expect(cache.filters?.map(\.title) == ["a"])
    }

    /// リクエストごとに別の門で止め、届く順を決められる。`responses`のn番目が、n番目のリクエストの結果になる。nilなら失敗する。
    private final class OrderedServer: Sendable {
        let gates: [Gate]
        private let responses: [[String]?]
        private let count = Mutex(0)

        init(_ responses: [[String]?]) {
            self.responses = responses
            gates = responses.map { _ in Gate() }
        }

        var requests: Int { count.withLock { $0 } }

        func fetch() async throws -> [ServerFilter] {
            let index = count.withLock { count in
                defer { count += 1 }
                return count
            }
            try await gates[index].wait()
            guard let titles = responses[index] else { throw URLError(.notConnectedToInternet) }
            return titles.map { ServerFilter(id: $0, title: $0, context: [.home], filterAction: .hide, expiresAt: nil, keywords: []) }
        }
    }

    /// 待っている間に後から始めた読み直しが先に届いても、先に始めた読み直しの古い一覧を返さない。
    @Test func latestReturnsNewerReloadEvenWhenItFinishesFirst() async throws {
        let server = OrderedServer([["old"], ["new"]])
        let cache = ServerFilterCache { try await server.fetch() }
        cache.refresh()
        try await waitUntil { server.requests == 1 }
        let waiting = Task { try await cache.latest() }
        cache.reload()
        try await waitUntil { server.requests == 2 }

        server.gates[1].open()
        try await waitUntil { cache.filters != nil }
        server.gates[0].open()

        #expect(try await waiting.value.map(\.title) == ["new"])
        #expect(cache.filters?.map(\.title) == ["new"])
    }

    /// 先に始めた読み直しが失敗しても、後から始めた読み直しが読めていれば、その一覧を返す。
    @Test func latestIgnoresFailureOfSupersededReload() async throws {
        let server = OrderedServer([nil, ["new"]])
        let cache = ServerFilterCache { try await server.fetch() }
        cache.refresh()
        try await waitUntil { server.requests == 1 }
        let waiting = Task { try await cache.latest() }
        cache.reload()
        try await waitUntil { server.requests == 2 }

        server.gates[0].open()
        server.gates[1].open()

        #expect(try await waiting.value.map(\.title) == ["new"])
    }

    /// 止めたら、走っている読み直しを取り消し、以後は読まない。ログアウトのあとに前のアカウントで通信し続けないため。
    @Test func closeCancelsReloadAndStopsLoading() async throws {
        let server = OrderedServer([["a"], ["b"]])
        let cache = ServerFilterCache { try await server.fetch() }
        cache.refresh()
        try await waitUntil { server.requests == 1 }
        let waiting = Task { try await cache.latest() }

        cache.close()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        cache.reload()
        #expect(server.requests == 1)
    }
}

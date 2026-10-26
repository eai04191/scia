import Foundation
import Synchronization
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct AccountCacheTests {
    /// 求められたIDの組を記録し、知っているアカウントを返す。`holds`なら、`release()`まで返さない。
    private final class Server: Sendable {
        private let state: Mutex<(requests: [[String]], failing: Bool, waiters: [CheckedContinuation<Void, Never>], held: [CheckedContinuation<Void, Never>])>
        private let holds: Bool

        init(holds: Bool = false) {
            state = Mutex(([], false, [], []))
            self.holds = holds
        }

        var requests: [[String]] { state.withLock { $0.requests } }

        func fail(_ failing: Bool) {
            state.withLock { $0.failing = failing }
        }

        func fetch(_ ids: [String]) async throws -> [Account] {
            let failing = state.withLock { $0.failing }
            if holds {
                // 止めておく登録を済ませてから届いたことを知らせ、知らせを受けた側の`release()`に漏れなく拾わせる。
                await withCheckedContinuation { continuation in
                    resumeWaiters(afterRecording: ids, holding: continuation)
                }
            } else {
                resumeWaiters(afterRecording: ids, holding: nil)
            }
            if failing {
                throw URLError(.notConnectedToInternet)
            }
            // "missing"で始まるIDは、見つからないアカウントとして返さない。
            return ids.filter { !$0.hasPrefix("missing") }.map { Account(id: $0, username: "user\($0)", acct: "user\($0)", displayName: "", avatar: nil) }
        }

        private func resumeWaiters(afterRecording ids: [String], holding continuation: CheckedContinuation<Void, Never>?) {
            let waiters = state.withLock { state in
                state.requests.append(ids)
                if let continuation { state.held.append(continuation) }
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }

        /// リクエストが`count`回届くまで待つ。
        func waitForRequests(_ count: Int) async {
            while state.withLock({ $0.requests.count }) < count {
                await withCheckedContinuation { continuation in
                    let resumeNow = state.withLock { state in
                        guard state.requests.count < count else { return true }
                        state.waiters.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
        }

        func release() {
            let held = state.withLock { state in
                defer { state.held = [] }
                return state.held
            }
            held.forEach { $0.resume() }
        }
    }

    private func makeCache(_ server: Server, limit: Int = 40) -> AccountCache {
        AccountCache(limit: limit) { ids in try await server.fetch(ids) }
    }

    /// 相手ごとに送らず、上限の数ずつまとめて読む。同じIDを重ねて求めても、1回だけ読む。
    @Test func loadsInBatchesUpToTheLimit() async {
        let server = Server()
        let cache = makeCache(server, limit: 2)

        let loaded = await cache.load(["1", "2", "3", "1"])

        // 塊ごとに別々に読み始めるため、届く順は決まらない。
        #expect(Set(server.requests) == [["1", "2"], ["3"]])
        #expect(server.requests.count == 2)
        #expect(loaded.keys.sorted() == ["1", "2", "3"])
        #expect(cache.account("2")?.acct == "user2")
    }

    /// 読み込み済みのアカウントは読まず、足りない分だけ読む。
    @Test func skipsAccountsAlreadyLoaded() async {
        let server = Server()
        let cache = makeCache(server)
        _ = await cache.load(["1", "2"])

        let loaded = await cache.load(["2", "3"])

        #expect(server.requests == [["1", "2"], ["3"]])
        #expect(loaded.keys.sorted() == ["2", "3"])
    }

    /// 読み込み中のアカウントを続けて求められたら、二重に送らず、その読み込みを待つ。
    @Test func waitsForAccountsBeingLoaded() async {
        let server = Server(holds: true)
        let cache = makeCache(server)
        let first = Task { await cache.load(["1"]) }
        await server.waitForRequests(1)

        let second = Task { await cache.load(["1", "2"]) }
        await server.waitForRequests(2)
        server.release()

        #expect(await first.value.keys.sorted() == ["1"])
        #expect(await second.value.keys.sorted() == ["1", "2"])
        #expect(server.requests == [["1"], ["2"]])
    }

    /// 見つからなかったアカウントと、失敗した読み込みのアカウントは返さず、次に求められたときに読み直す。
    @Test func retriesAccountsThatCouldNotBeLoaded() async {
        let server = Server()
        let cache = makeCache(server)
        server.fail(true)

        #expect(await cache.load(["1"]).isEmpty)
        #expect(await cache.load(["missing-2"]).isEmpty)

        server.fail(false)
        #expect(await cache.load(["1", "missing-2"]).keys.sorted() == ["1"])
        #expect(server.requests == [["1"], ["missing-2"], ["1", "missing-2"]])
    }

    /// 探して見つかったアカウントは、探した値ごとに覚え、次は探さずに返す。ハンドルは大文字と小文字を区別しない。
    /// 見つかったアカウントはIDでも引ける。
    @Test func resolvedAccountIsRememberedByLookup() async throws {
        let cache = makeCache(Server())
        let searches = Mutex(0)
        let found = Account(id: "7", username: "alice", acct: "alice@remote.example", displayName: "", avatar: nil)
        let search: @Sendable () async throws -> Account? = {
            searches.withLock { $0 += 1 }
            return found
        }

        #expect(try await cache.resolve(.acct("Alice@Remote.example"), search: search)?.id == "7")
        #expect(try await cache.resolve(.acct("alice@remote.example"), search: search)?.id == "7")
        #expect(searches.withLock { $0 } == 1)
        #expect(cache.account("7")?.acct == "alice@remote.example")
    }

    /// 探している途中の値を続けて探したら、二重に検索せず、その検索を待つ。
    @Test func resolvingSameLookupWaitsForSearchInFlight() async throws {
        let cache = makeCache(Server())
        let gate = Gate()
        let searches = Mutex(0)
        let url = try #require(URL(string: "https://remote.example/@alice"))
        let search: @Sendable () async throws -> Account? = {
            searches.withLock { $0 += 1 }
            try await gate.wait()
            return Account(id: "7", username: "alice", acct: "alice@remote.example", displayName: "", avatar: nil)
        }

        let first = Task { try await cache.resolve(.profileURL(url), search: search) }
        try await waitUntil { gate.waiterCount == 1 }
        let second = Task { try await cache.resolve(.profileURL(url), search: search) }
        gate.open()

        #expect(try await first.value?.id == "7")
        #expect(try await second.value?.id == "7")
        #expect(searches.withLock { $0 } == 1)
    }

    /// 見つからなかったときと、検索が失敗したときは覚えず、次に探し直す。
    @Test func unresolvedLookupIsSearchedAgain() async throws {
        let cache = makeCache(Server())
        let searches = Mutex(0)
        let search: @Sendable () async throws -> Account? = {
            let count = searches.withLock { state in
                state += 1
                return state
            }
            if count == 1 { throw URLError(.notConnectedToInternet) }
            return nil
        }

        await #expect(throws: URLError.self) { try await cache.resolve(.acct("nobody"), search: search) }
        #expect(try await cache.resolve(.acct("nobody"), search: search) == nil)
        #expect(try await cache.resolve(.acct("nobody"), search: search) == nil)
        #expect(searches.withLock { $0 } == 3)
    }
}

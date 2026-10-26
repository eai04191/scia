import Foundation
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct RelationshipCacheTests {
    /// 求められたIDの組を記録し、フォロー中の関係を返す。`holds`なら、`release()`まで返さない。
    private final class Server: Sendable {
        private let state: Mutex<(requests: [[String]], failing: Bool, following: Bool, waiters: [CheckedContinuation<Void, Never>], held: [CheckedContinuation<Void, Never>])>
        private let holds: Bool

        init(holds: Bool = false) {
            state = Mutex(([], false, true, [], []))
            self.holds = holds
        }

        var requests: [[String]] { state.withLock { $0.requests } }

        func fail(_ failing: Bool) {
            state.withLock { $0.failing = failing }
        }

        /// 次から返す関係のフォロー中かどうか。
        func setFollowing(_ following: Bool) {
            state.withLock { $0.following = following }
        }

        func fetch(_ ids: [String]) async throws -> [Relationship] {
            let (failing, following) = state.withLock { ($0.failing, $0.following) }
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
            return ids.filter { !$0.hasPrefix("missing") }.map { Relationship(id: $0, following: following) }
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

    private func makeCache(_ server: Server, limit: Int = 40) -> RelationshipCache {
        RelationshipCache(limit: limit) { ids in try await server.fetch(ids) }
    }

    /// 相手ごとに送らず、上限の数ずつまとめて読む。同じIDを重ねて求めても、1回だけ読む。
    @Test func reloadsInBatchesUpToTheLimit() async throws {
        let server = Server()
        let cache = makeCache(server, limit: 2)

        cache.reload(["1", "2", "3", "1"])

        #expect(try await cache.relationship("1")?.following == true)
        #expect(try await cache.relationship("3")?.following == true)
        // 塊ごとに別々に読み始めるため、届く順は決まらない。
        #expect(Set(server.requests) == [["1", "2"], ["3"]])
        #expect(server.requests.count == 2)
        #expect(cache["2"]?.following == true)
    }

    /// 覚えている関係も読み直す。読み終えるまでは、覚えている関係をそのまま返す。
    @Test func reloadRefreshesKnownRelationshipsAndKeepsThemMeanwhile() async throws {
        let server = Server(holds: true)
        let cache = makeCache(server)
        cache["1"] = Relationship(id: "1", following: true)
        server.setFollowing(false)

        cache.reload(["1"])
        await server.waitForRequests(1)
        #expect(cache["1"]?.following == true)

        server.release()
        #expect(try await cache.relationship("1")?.following == false)
    }

    /// 読み直している途中のIDを続けて求められたら、二重に送らず、その読み直しを待つ。
    @Test func waitsForRelationshipsBeingReloaded() async throws {
        let server = Server(holds: true)
        let cache = makeCache(server)
        cache.reload(["1"])
        await server.waitForRequests(1)

        cache.reload(["1", "2"])
        await server.waitForRequests(2)
        let first = Task { try await cache.relationship("1") }
        server.release()

        #expect(try await first.value?.id == "1")
        #expect(try await cache.relationship("2")?.id == "2")
        #expect(server.requests == [["1"], ["2"]])
    }

    /// 覚えていない相手は、求められたときに読む。覚えていて読み直していない相手は、送らずに返す。
    @Test func relationshipLoadsOnlyUnknownAccounts() async throws {
        let server = Server()
        let cache = makeCache(server)
        cache["1"] = Relationship(id: "1", following: false)

        #expect(try await cache.relationship("1")?.following == false)
        #expect(try await cache.relationship("2")?.following == true)
        #expect(server.requests == [["2"]])
    }

    /// サーバーが返さなかった相手はnil。読めなかったら、覚えている関係を残して投げる。
    @Test func missingIsNilAndFailureKeepsKnownRelationship() async throws {
        let server = Server()
        let cache = makeCache(server)
        cache["1"] = Relationship(id: "1", following: true)

        #expect(try await cache.relationship("missing-2") == nil)

        server.fail(true)
        cache.reload(["1"])
        await #expect(throws: URLError.self) {
            try await cache.relationship("1")
        }
        #expect(cache["1"]?.following == true)
    }

    /// 覚えていた相手が応答に入らなかったら（削除の予定や凍結）、その関係を忘れる。
    @Test func reloadForgetsRelationshipsMissingFromResponse() async throws {
        let server = Server()
        let cache = makeCache(server)
        cache["missing-1"] = Relationship(id: "missing-1", following: true)

        cache.reload(["missing-1", "2"])

        #expect(try await cache.relationship("2")?.following == true)
        #expect(cache["missing-1"] == nil)
    }

    /// 読み直しを頼んだあとに関係を変えたら、遅れて届いた読み直しの応答で古い関係に戻さない。
    @Test func reloadDoesNotOverwriteRelationshipWrittenMeanwhile() async throws {
        let server = Server(holds: true)
        let cache = makeCache(server)
        server.setFollowing(false)
        cache.reload(["1", "2"])
        await server.waitForRequests(1)

        cache["1"] = Relationship(id: "1", following: true)
        server.release()

        #expect(try await cache.relationship("2")?.following == false)
        #expect(cache["1"]?.following == true)
    }

    /// 止めたら、走っている読み直しを取り消し、以後は読まない。ログアウトのあとに前のアカウントで通信し続けないため。
    @Test func closeCancelsReloadAndStopsLoading() async throws {
        let server = Server(holds: true)
        let cache = makeCache(server)
        cache.reload(["1"])
        await server.waitForRequests(1)
        let waiting = Task { try await cache.relationship("1") }

        cache.close()
        server.release()
        _ = try? await waiting.value
        cache.reload(["2"])
        #expect(try await cache.relationship("2") == nil)
        #expect(server.requests == [["1"]])
    }
}

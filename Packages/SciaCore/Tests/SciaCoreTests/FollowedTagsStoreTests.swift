import Foundation
import SciaCore
import SciaTesting
import Testing

/// 「フォロー中のハッシュタグ」の持ち方を確かめる。決まりはdocs/tabs.mdの「フォロー中のハッシュタグ」にある。
@MainActor
struct FollowedTagsStoreTests {
    @MainActor
    private final class Server {
        var tags: [Hashtag] = []
        var gate: Gate?
        var failure: (any Error)?

        func fetch() async throws -> [Hashtag] {
            let tags = tags
            if let gate { try await gate.wait() }
            if let failure { throw failure }
            return tags
        }
    }

    /// 読んだハッシュタグで置き換え、そろえた名前が同じタグは1度だけ並べる。
    @Test func loadReplacesAndDeduplicates() async throws {
        let server = Server()
        server.tags = [Hashtag(name: "Cat"), Hashtag(name: "dog"), Hashtag(name: "cat")]
        let store = FollowedTagsStore { try await server.fetch() }

        #expect(try await store.load())

        #expect(store.tags.map(\.name) == ["Cat", "dog"])
        #expect(store.isLoaded)
    }

    /// アプリの中でフォローしたタグは先頭に入れ、外したタグはそろえた名前で除く。並んでいるタグをフォローしても増やさない。
    @Test func followPrependsAndUnfollowRemoves() async throws {
        let server = Server()
        server.tags = [Hashtag(name: "dog")]
        let store = FollowedTagsStore { try await server.fetch() }
        _ = try await store.load()

        store.didFollow(Hashtag(name: "cat"))
        store.didFollow(Hashtag(name: "ＤＯＧ"))
        #expect(store.tags.map(\.name) == ["cat", "dog"])

        store.didUnfollow("CAT")
        #expect(store.tags.map(\.name) == ["dog"])
    }

    /// 読んでいる間に変えたフォローは、読み始めた時点の応答で打ち消さず、応答を入れたあとにやり直す。
    @Test func changesDuringLoadSurviveTheResponse() async throws {
        let server = Server()
        server.tags = [Hashtag(name: "dog"), Hashtag(name: "bird")]
        let gate = Gate()
        server.gate = gate
        let store = FollowedTagsStore { try await server.fetch() }

        let loading = Task { try await store.load() }
        try await waitUntil { store.isLoading }
        store.didFollow(Hashtag(name: "cat"))
        store.didUnfollow("bird")
        // 読み込み中に重ねて読もうとしても、読まない。
        #expect(try await store.load() == false)
        gate.open()

        #expect(try await loading.value)
        #expect(store.tags.map(\.name) == ["cat", "dog"])
    }

    /// ほかで読み直したハッシュタグ（ハッシュタグのメニューが読んだもの）を受け取って置き換える。読み込み中は、その読み込みに任せて受け取らない。
    @Test func receiveReplacesUnlessLoading() async throws {
        let server = Server()
        server.tags = [Hashtag(name: "dog")]
        let gate = Gate()
        server.gate = gate
        let store = FollowedTagsStore { try await server.fetch() }

        let loading = Task { try await store.load() }
        try await waitUntil { store.isLoading }
        #expect(!store.receive([Hashtag(name: "cat")]))
        gate.open()
        _ = try await loading.value
        #expect(store.tags.map(\.name) == ["dog"])

        #expect(store.receive([Hashtag(name: "cat"), Hashtag(name: "CAT")]))
        #expect(store.tags.map(\.name) == ["cat"])
    }

    /// 読めなければ投げ、前のハッシュタグを残す。
    @Test func failureKeepsPreviousTags() async throws {
        let server = Server()
        server.tags = [Hashtag(name: "dog")]
        let store = FollowedTagsStore { try await server.fetch() }
        _ = try await store.load()

        server.failure = URLError(.notConnectedToInternet)
        await #expect(throws: URLError.self) { try await store.load() }
        #expect(store.tags.map(\.name) == ["dog"])
    }
}

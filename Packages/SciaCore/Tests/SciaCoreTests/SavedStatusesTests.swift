import Foundation
import Synchronization
import Testing
@testable import SciaCore

struct LinkHeaderTests {
    @Test func readsNextAndPrevFromMastodonHeader() throws {
        let header = LinkHeader(#"<https://mastodon.example/api/v1/favourites?limit=2&max_id=23716836>; rel="next", <https://mastodon.example/api/v1/favourites?limit=2&min_id=23716978>; rel="prev""#)

        #expect(header.next?.absoluteString == "https://mastodon.example/api/v1/favourites?limit=2&max_id=23716836")
        #expect(header.queryValue("max_id", of: "next") == "23716836")
        #expect(header.queryValue("min_id", of: "prev") == "23716978")
    }

    /// `rel`は引用符がなくても、大文字でも、複数の値を並べても読む。URLの中の`,`で要素を区切らない。
    @Test func readsUnquotedAndMultipleRels() {
        let header = LinkHeader(#"<https://example.social/a?tags=x,y&max_id=5>;REL=next ; title="t", <https://example.social/b>; rel="prev last""#)

        #expect(header.queryValue("max_id", of: "next") == "5")
        #expect(header.links["prev"]?.absoluteString == "https://example.social/b")
        #expect(header.links["last"]?.absoluteString == "https://example.social/b")
    }

    @Test func ignoresBrokenValue() {
        #expect(LinkHeader("").links.isEmpty)
        #expect(LinkHeader("https://example.social; rel=next").links.isEmpty)
        #expect(LinkHeader("<https://example.social>").next == nil)
    }
}

struct SavedStatusesClientTests {
    private func makeClient(_ transport: StubTransport) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport
        )
    }

    /// 続きの位置は`Link`ヘッダーの`next`の`max_id`だけを使い、送り先はログインしたサーバーの決まったパスにする。
    @Test func bookmarksReadNextPositionFromLinkHeader() async throws {
        let link = #"<https://other.example/api/v1/bookmarks?max_id=900&limit=40>; rel="next", <https://example.social/api/v1/bookmarks?min_id=950>; rel="prev""#
        let transport = StubTransport([try .fixture("home_timeline", headers: ["Link": link]), .json("[]", statusCode: 200)])
        let client = try makeClient(transport)

        let first = try await client.bookmarks(maxID: nil, limit: 40)
        #expect(first.statuses.map(\.id) == ["113000000000000003", "113000000000000002"])
        #expect(first.nextMaxID == "900")

        let second = try await client.bookmarks(maxID: "900", limit: 40)
        #expect(second.statuses.isEmpty)
        #expect(second.nextMaxID == nil)

        let urls = await transport.requests.compactMap(\.url)
        #expect(urls.map { $0.host() } == ["example.social", "example.social"])
        #expect(urls.map { $0.path() } == ["/api/v1/bookmarks", "/api/v1/bookmarks"])
        let queries = urls.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        #expect(queries[0] == [URLQueryItem(name: "limit", value: "40")])
        #expect(queries[1] == [URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "max_id", value: "900")])
    }

    @Test func favouritesUseFavouritesPath() async throws {
        let transport = StubTransport([.json("[]", statusCode: 200)])

        _ = try await makeClient(transport).favourites(maxID: nil, limit: 20)

        #expect(await transport.requests.first?.url?.path() == "/api/v1/favourites")
    }
}

@MainActor
struct SavedStatusesStoreTests {
    private static func status(_ id: String, bookmarked: Bool = true, favourited: Bool = false, accountID: String = "2", reblog: Status? = nil) -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: accountID, username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "<p>\(id)</p>",
            spoilerText: "",
            url: nil,
            favourited: favourited,
            bookmarked: bookmarked,
            reblog: reblog
        )
    }

    private static func page(_ ids: [String], next: String?, unreadable: [String] = []) -> SavedStatusesPage {
        SavedStatusesPage(statuses: ids.map { status($0) }, unreadable: unreadable.map { UnreadableItem(id: $0, url: nil) }, nextMaxID: next)
    }

    /// 返すページを順に出し、渡された`max_id`を記録する。
    private final class Pages: Sendable {
        private let state: Mutex<(pages: [SavedStatusesPage], maxIDs: [String?])>

        init(_ pages: [SavedStatusesPage]) {
            state = Mutex((pages, []))
        }

        var maxIDs: [String?] { state.withLock { $0.maxIDs } }

        func next(_ maxID: String?) throws -> SavedStatusesPage {
            try state.withLock { state in
                state.maxIDs.append(maxID)
                guard !state.pages.isEmpty else { throw URLError(.badServerResponse) }
                return state.pages.removeFirst()
            }
        }
    }

    private func makeStore(_ pages: Pages, kind: SavedStatusesKind = .bookmarks) -> SavedStatusesStore {
        SavedStatusesStore(kind: kind) { try pages.next($0) }
    }

    private func ids(_ store: SavedStatusesStore) -> [TimelineEntry.ID] {
        store.entries.map(\.id)
    }

    /// 並びはサーバーの順のままにし、IDの順に並べ直さない。続きは前のページの位置から読む。
    @Test func keepsServerOrderAndReadsOlderFromNextPosition() async throws {
        let pages = Pages([Self.page(["5", "9", "1"], next: "c1", unreadable: ["7"]), Self.page(["8", "2"], next: nil)])
        let store = makeStore(pages)

        try await store.loadInitial()
        #expect(ids(store) == [.status("5"), .status("9"), .status("1"), .unreadable("7")])
        #expect(!store.reachedEnd)

        #expect(try await store.loadOlder())
        #expect(ids(store) == [.status("5"), .status("9"), .status("1"), .unreadable("7"), .status("8"), .status("2")])
        #expect(store.reachedEnd)
        #expect(pages.maxIDs == [nil, "c1"])

        #expect(try await !store.loadOlder())
        #expect(pages.maxIDs.count == 2)
    }

    /// 続きに同じ投稿が入っていても、重ねて並べない。
    @Test func olderPageSkipsKnownStatuses() async throws {
        let store = makeStore(Pages([Self.page(["5", "4"], next: "c1"), Self.page(["4", "3"], next: "c2")]))

        try await store.loadInitial()
        try await store.loadOlder()

        #expect(ids(store) == [.status("5"), .status("4"), .status("3")])
    }

    /// 同じ位置を返し続けるサーバーで、同じページを読み続けない。
    @Test func stopsWhenNextPositionDoesNotMove() async throws {
        let store = makeStore(Pages([Self.page(["5"], next: "c1"), Self.page(["4"], next: "c1")]))

        try await store.loadInitial()
        try await store.loadOlder()

        #expect(store.reachedEnd)
    }

    /// 開き直したときは、手元にある行より前の分だけを先頭に足し、手元の行と続きの位置はそのままにする。
    @Test func refreshPrependsOnlyNewerEntries() async throws {
        let pages = Pages([Self.page(["5", "4"], next: "c1"), Self.page(["7", "6", "5", "4"], next: "c9"), Self.page(["3"], next: nil)])
        let store = makeStore(pages)

        try await store.loadInitial()
        #expect(try await store.refreshNewest())
        #expect(ids(store) == [.status("7"), .status("6"), .status("5"), .status("4")])

        try await store.loadOlder()
        #expect(pages.maxIDs == [nil, nil, "c1"])
    }

    /// 先頭が外したまま残した行でも、その下の手元の行で重なりを見つける。
    @Test func refreshFindsOverlapBelowUnsavedHead() async throws {
        let store = makeStore(Pages([Self.page(["5", "4"], next: "c1"), Self.page(["6", "4"], next: "c2")]))

        try await store.loadInitial()
        store.updateStatus("5") { $0.settingBookmarked(false) }
        try await store.refreshNewest()

        #expect(ids(store) == [.status("6"), .status("5"), .status("4")])
    }

    /// 手元の行が最新のページに1つもなければ、間が埋まらないので、読んだページで置き換える。
    @Test func refreshReplacesWhenNoOverlap() async throws {
        let pages = Pages([Self.page(["5", "4"], next: "c1"), Self.page(["9", "8"], next: "c8"), Self.page(["7"], next: nil)])
        let store = makeStore(pages)

        try await store.loadInitial()
        try await store.refreshNewest()
        #expect(ids(store) == [.status("9"), .status("8")])

        try await store.loadOlder()
        #expect(pages.maxIDs == [nil, nil, "c8"])
    }

    /// 重なりがなくて置き換えるときも、見ている間に外して残した行は、読んだページの下に残す。
    @Test func refreshReplacingKeepsUnsavedRows() async throws {
        let store = makeStore(Pages([Self.page(["5"], next: nil), Self.page([], next: nil)]))

        try await store.loadInitial()
        store.updateStatus("5") { $0.settingBookmarked(false) }
        store.markUnsaved(Self.status("5", bookmarked: false))
        try await store.refreshNewest()

        #expect(ids(store) == [.status("5")])
        #expect(store.pruneUnsaved())
        #expect(store.isEmpty)
    }

    /// 読み込みの最中に付けた投稿は、読んだページになくても、読み込みが済んだところで先頭に入れる。
    @Test func savedDuringLoadIsInsertedAfterLoad() async throws {
        let gate = FetchGate()
        let page = Self.page(["5"], next: nil)
        let store = SavedStatusesStore(kind: .bookmarks) { _ in
            await gate.wait()
            return page
        }

        let load = Task { try await store.loadInitial() }
        await gate.waitUntilWaiting()
        #expect(!store.insertSaved(Self.status("8")))
        await gate.open()
        _ = try await load.value

        #expect(ids(store) == [.status("8"), .status("5")])
    }

    /// 削除した投稿は、付けた操作の結果があとから届いても入れない。
    @Test func deletedStatusIsNotInsertedBySettle() async throws {
        let store = makeStore(Pages([Self.page(["5"], next: nil)]))
        try await store.loadInitial()

        store.removeStatus("8")
        #expect(!store.insertSaved(Self.status("8")))
        #expect(ids(store) == [.status("5")])
    }

    @Test func refreshBeforeInitialLoadDoesNothing() async throws {
        let pages = Pages([])
        let store = makeStore(pages)

        #expect(try await !store.refreshNewest())
        #expect(pages.maxIDs.isEmpty)
    }

    /// アプリの中で付けた投稿は先頭に入れる。ブーストから付けたら元の投稿を入れる。読み込む前と、すでにある投稿は入れない。
    @Test func insertsSavedStatusAtTop() async throws {
        let store = makeStore(Pages([Self.page(["5"], next: nil)]))
        #expect(!store.insertSaved(Self.status("1")))

        try await store.loadInitial()
        let boost = Self.status("100", bookmarked: false, reblog: Self.status("8"))
        #expect(store.insertSaved(boost))
        #expect(!store.insertSaved(Self.status("5")))
        #expect(!store.insertSaved(Self.status("6", bookmarked: false)))

        #expect(ids(store) == [.status("8"), .status("5")])
    }

    /// 外した行は残し、外すのをサーバーが受け付けたあとに離れたら消す。お気に入りの一覧はお気に入りの印で見る。
    @Test func unsavedRowsStayUntilPruned() async throws {
        let store = makeStore(Pages([SavedStatusesPage(statuses: [Self.status("5", bookmarked: false, favourited: true), Self.status("4", bookmarked: false, favourited: true)], nextMaxID: nil)]), kind: .favourites)
        try await store.loadInitial()

        #expect(store.updateStatus("5") { $0.settingFavourited(false) })
        #expect(ids(store) == [.status("5"), .status("4")])
        #expect(store.statuses.first?.favourited == false)

        store.markUnsaved(Self.status("5", favourited: false))
        #expect(store.pruneUnsaved())
        #expect(ids(store) == [.status("4")])
        #expect(!store.pruneUnsaved())
    }

    /// 外す操作の結果を待っている間は、印が外れていても消さない。外すのに失敗して印を戻したら、行もそのまま残る。
    @Test func unsavedRowAwaitingResultIsNotPruned() async throws {
        let store = makeStore(Pages([Self.page(["5", "4"], next: nil)]))
        try await store.loadInitial()

        store.updateStatus("4") { $0.settingBookmarked(false) }
        #expect(!store.pruneUnsaved())
        store.updateStatus("4") { $0.settingBookmarked(true) }

        #expect(ids(store) == [.status("5"), .status("4")])
        #expect(store.statuses.map(\.bookmarked) == [true, true])
    }

    /// 付け直した行は、消さずに同じ場所に残す。
    @Test func resavedRowStaysInPlace() async throws {
        let store = makeStore(Pages([Self.page(["5", "4"], next: nil)]))
        try await store.loadInitial()

        store.updateStatus("4") { $0.settingBookmarked(false) }
        store.markUnsaved(Self.status("4", bookmarked: false))
        store.updateStatus("4") { $0.settingBookmarked(true) }
        #expect(!store.insertSaved(Self.status("4")))
        #expect(!store.pruneUnsaved())

        #expect(ids(store) == [.status("5"), .status("4")])
    }

    /// アプリの中で先頭に入れた行では重なりを探さない。ほかの端末でその前に付けた行が、その下にあっても読み落とさないため。
    /// 先頭に入れた行は、サーバーの順の位置へ移す。
    @Test func refreshDoesNotStopAtLocallyInsertedRow() async throws {
        let store = makeStore(Pages([Self.page(["A", "B"], next: nil), Self.page(["C", "D", "A", "B"], next: nil)]))
        try await store.loadInitial()

        #expect(store.insertSaved(Self.status("C")))
        try await store.refreshNewest()

        #expect(ids(store) == [.status("C"), .status("D"), .status("A"), .status("B")])
    }

    /// 削除した投稿とミュートかブロックした相手の投稿は除き、あとから読んでも戻さない。
    @Test func removedAndExcludedStatusesStayOut() async throws {
        let first = SavedStatusesPage(statuses: [Self.status("5"), Self.status("4", accountID: "muted"), Self.status("3")], nextMaxID: "c1")
        let store = makeStore(Pages([first, SavedStatusesPage(statuses: [Self.status("5"), Self.status("2", accountID: "muted"), Self.status("1")], nextMaxID: "c9")]))
        try await store.loadInitial()

        #expect(store.removeStatus("3"))
        #expect(store.excludeAccount("muted"))
        #expect(ids(store) == [.status("5")])

        try await store.loadInitial()
        #expect(ids(store) == [.status("5"), .status("1")])
        #expect(!store.insertSaved(Self.status("9", accountID: "muted")))
    }
}

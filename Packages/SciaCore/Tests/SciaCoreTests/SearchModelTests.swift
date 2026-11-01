import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
@Suite(.serialized)
struct SearchModelTests {
    /// 検索の1回の問い合わせ。
    struct Query: Sendable {
        let type: String?
        let resolve: String?
        let limit: Int
        let offset: Int

        init(_ request: URLRequest) {
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            type = value("type")
            resolve = value("resolve")
            limit = value("limit").flatMap(Int.init) ?? 0
            offset = value("offset").flatMap(Int.init) ?? 0
        }
    }

    /// 問い合わせごとに`respond`の結果を返す。nilなら422で断る。
    nonisolated private static func transport(_ respond: @escaping @Sendable (Query) throws -> Data?) -> RoutedTransport {
        RoutedTransport { request in
            guard let body = try respond(Query(request)) else { return (422, Data(#"{"error":"Unprocessable"}"#.utf8)) }
            return (200, body)
        }
    }

    nonisolated private static func body(accounts: [Int] = [], statuses: [Int] = [], hashtags: [String] = []) throws -> Data {
        let statusesJSON = String(decoding: try TimelineModelFixtures.body(statuses), as: UTF8.self)
        let url = try #require(Bundle.module.url(forResource: "account", withExtension: "json", subdirectory: "Fixtures"))
        let template = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let accountsJSON = try accounts.map { number in
            var account = template
            account["id"] = "a\(number)"
            account["username"] = "user\(number)"
            account["acct"] = "user\(number)@remote.example"
            return String(decoding: try JSONSerialization.data(withJSONObject: account), as: UTF8.self)
        }
        let hashtagsJSON = hashtags.map { #"{"name":"\#($0)","url":"https://example.social/tags/x","history":[]}"# }
        return Data(#"{"accounts":[\#(accountsJSON.joined(separator: ","))],"statuses":\#(statusesJSON),"hashtags":[\#(hashtagsJSON.joined(separator: ","))]}"#.utf8)
    }

    private func makeModel(_ text: String, scope: SearchModel.Scope = .all, carriedAccounts: [Account] = [], carriedHashtags: [Hashtag] = [], transport: RoutedTransport) throws -> (SearchModel, RecordingTimelineDisplay) {
        let input = try #require(SearchInput(text))
        let model = SearchModel(input: input, scope: scope, carriedAccounts: carriedAccounts, carriedHashtags: carriedHashtags, client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), tasks: TaskScope()) {}
        let display = RecordingTimelineDisplay()
        model.display = display
        return (model, display)
    }

    private static func rows(_ display: RecordingTimelineDisplay) -> [String] {
        display.entries.map { entry in
            switch entry {
            case .account(let account): "@\(account.id)"
            case .status(let status): "s\(status.id)"
            case .search(.heading(let category)): "[\(category.rawValue)]"
            case .search(.hashtag(let hashtag)): "#\(hashtag.name)"
            case .search(.showAll(let category)): "all-\(category.rawValue)"
            case .search(.failed(let category, _)): "failed-\(category.rawValue)"
            default: "?"
            }
        }
    }

    /// 種類を分けて並行に読み、ユーザー、ハッシュタグ、投稿の順に見出しを付けて並べる。ユーザーとハッシュタグは5件までにし、多ければ「すべて見る」を出す。
    @Test func allScopeOrdersSectionsAndLimitsPreviews() async throws {
        let transport = Self.transport { query in
            switch query.type {
            case "accounts": try Self.body(accounts: Array(1...6))
            case "hashtags": try Self.body(hashtags: ["a", "b"])
            case "statuses": try Self.body(statuses: [3, 2, 1])
            default: nil
            }
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }

        model.start()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(Self.rows(display) == ["[accounts]", "@a1", "@a2", "@a3", "@a4", "@a5", "all-accounts", "[hashtags]", "#a", "#b", "[statuses]", "s3", "s2", "s1"])
        #expect(display.contentState == .loaded)
        let queries = transport.requests.map(Query.init)
        #expect(Set(queries.compactMap(\.type)) == ["accounts", "hashtags", "statuses"])
        // 知らない相手のサーバーのユーザーを探すのは、ユーザーだけ。
        #expect(queries.first { $0.type == "accounts" }?.resolve == "true")
        #expect(queries.first { $0.type == "hashtags" }?.resolve == "false")
        #expect(queries.first { $0.type == "accounts" }?.limit == SearchModel.previewCount + 1)
    }

    /// 投稿の続きは、読めた件数ではなく頼んだ件数を足した`offset`で読む。重なった投稿は除き、0件が返るまで続きがあるとする。
    @Test func statusesPageByRequestedOffset() async throws {
        let transport = Self.transport { query in
            guard query.type == "statuses" else { return try Self.body() }
            return switch query.offset {
            // サーバーがミュートした人の投稿を除いて、頼んだ件数より少なく返す。
            case 0: try Self.body(statuses: [10, 9])
            case query.limit: try Self.body(statuses: [9, 8])
            default: try Self.body()
            }
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.footerState == .idle)

        model.approachEnd()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(Self.rows(display) == ["[statuses]", "s10", "s9", "s8"])
        #expect(display.footerState == .idle)

        model.approachEnd()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.footerState == .reachedEnd)
        let offsets = transport.requests.map(Query.init).filter { $0.type == "statuses" }.map(\.offset)
        #expect(offsets == [0, 20, 40])
    }

    /// 0件の種類は見出しごと出さない。全文検索のないサーバーで、毎回空の投稿の見出しを出さないため。
    @Test func emptyCategoriesAreHidden() async throws {
        let transport = Self.transport { query in
            query.type == "accounts" ? try Self.body(accounts: [1]) : try Self.body()
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(Self.rows(display) == ["[accounts]", "@a1"])
        #expect(display.footerState == .reachedEnd)
    }

    /// 3つとも0件なら、行のない一覧を読み終えた状態にし、見つからなかったことを出す。
    @Test func nothingFound() async throws {
        let (model, display) = try makeModel("猫", transport: Self.transport { _ in try Self.body() })
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(display.entries.isEmpty)
        #expect(display.contentState == .loaded)
        // 全面に出す見つからなかった文と、フッターの終わりの文を重ねない。
        #expect(display.footerState == .idle)
    }

    /// 1つの種類が失敗しても、ほかの結果は見せ、失敗した種類の見出しの下に失敗の行を出す。押すとその種類だけ読み直す。
    @Test func failedCategoryShowsRowAndRetries() async throws {
        let failsAccounts = Mutex(true)
        let transport = Self.transport { query in
            switch query.type {
            case "accounts": failsAccounts.withLock { $0 } ? nil : try Self.body(accounts: [1])
            case "statuses": try Self.body(statuses: [1])
            default: try Self.body()
            }
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(Self.rows(display) == ["[accounts]", "failed-accounts", "[statuses]", "s1"])

        failsAccounts.withLock { $0 = false }
        model.retry(.accounts)
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(Self.rows(display) == ["[accounts]", "@a1", "[statuses]", "s1"])
        #expect(transport.requests.map(Query.init).filter { $0.type == "statuses" }.count == 1, "失敗していない種類まで読み直しました")
    }

    /// URLは、種類を分けずに1回で読み込ませ、投稿が1つに決まれば知らせる。続きは読まない。
    @Test func urlResolvesOnceAndReportsUniqueStatus() async throws {
        let transport = Self.transport { query in
            query.type == nil && query.resolve == "true" ? try Self.body(statuses: [7]) : nil
        }
        let (model, display) = try makeModel("https://remote.example/@bob/7", transport: transport)
        defer { model.stop() }
        var found: [SearchModel.Found] = []
        model.onFound = { found.append($0) }

        model.start()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(transport.requests.count == 1)
        #expect(found == [.status(try TimelineModelFixtures.status(7))])
        #expect(Self.rows(display) == ["[statuses]", "s7"])
        #expect(display.footerState == .reachedEnd)

        // 引っぱって読み直しても、もう一度は開かない。
        await model.refresh()
        #expect(found.count == 1)
    }

    /// ハンドルは、名前の一致するユーザーが結果にあれば知らせる。前方一致しただけのユーザーでは知らせない。
    @Test func handleReportsMatchingAccount() async throws {
        let transport = Self.transport { query in
            query.type == "accounts" ? try Self.body(accounts: [12, 1]) : try Self.body()
        }
        let (model, _) = try makeModel("@user1@remote.example", transport: transport)
        defer { model.stop() }
        var found: [String] = []
        model.onFound = { if case .account(let account) = $0 { found.append(account.id) } }

        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(found == ["a1"])
    }

    /// 「すべて見る」の一覧は、見出しを付けずにその種類だけを並べ、続きを読む。
    @Test func onlyScopeListsOneCategory() async throws {
        let transport = Self.transport { query in
            guard query.type == "hashtags" else { return nil }
            return query.offset == 0 ? try Self.body(hashtags: ["a", "b"]) : try Self.body()
        }
        let (model, display) = try makeModel("猫", scope: .only(.hashtags), transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(Self.rows(display) == ["#a", "#b"])
        #expect(transport.requests.map(Query.init).map(\.limit) == [40])

        model.approachEnd()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.footerState == .reachedEnd)
    }

    /// 読み終えるまでは、行がなくても読み込み中にする。見つからなかったと出さない。
    @Test func loadingUntilResultsArrive() async throws {
        let gate = Gate()
        let transport = RoutedTransport { _ in
            try await gate.wait()
            return (200, try Self.body(statuses: [1]))
        }
        let (model, display) = try makeModel("https://remote.example/@bob/1", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { transport.requests.count == 1 }
        #expect(display.contentState == .loading)
        // フッターの終わりの文は、行がなければ見つからなかったことを出すため、読み終えるまで出さない。
        #expect(display.footerState == .idle)

        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.contentState == .loaded)
    }

    /// 最初の読み込みの途中に引っぱって読み直しても、読み込み中のまま止まらない。
    @Test func refreshWhileLoadingFinishes() async throws {
        let gate = Gate()
        let transport = RoutedTransport { request in
            try await gate.wait()
            return (200, Query(request).type == "statuses" ? try Self.body(statuses: [1]) : try Self.body())
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { transport.requests.count == 3 }

        let refreshing = Task { await model.refresh() }
        gate.open()
        await refreshing.value
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.contentState == .loaded)
        #expect(display.statusIDs == ["1"])
    }

    /// URLの読み込みに失敗したら、再試行もURLとして読み込ませる。種類ごとの検索では、投稿のURLを読み込まないため。
    @Test func retryingURLResolvesAgain() async throws {
        let fails = Mutex(true)
        let transport = Self.transport { query in
            guard query.type == nil, query.resolve == "true", !fails.withLock({ $0 }) else { return nil }
            return try Self.body(statuses: [7])
        }
        let (model, display) = try makeModel("https://remote.example/@bob/7", transport: transport)
        defer { model.stop() }
        var found = 0
        model.onFound = { _ in found += 1 }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        guard case .failed = display.contentState else {
            Issue.record("失敗を伝えていません: \(display.contentState)")
            return
        }

        fails.withLock { $0 = false }
        model.retry()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(display.statusIDs == ["7"])
        #expect(found == 1)
        #expect(transport.requests.map(Query.init).allSatisfy { $0.type == nil })
    }

    /// 続きの読み込みに失敗したあとでも、読み直せたら失敗の表示を消す。
    @Test func refreshClearsPagingFailure() async throws {
        let failsNext = Mutex(true)
        let transport = Self.transport { query in
            guard query.type == "statuses" else { return try Self.body() }
            if query.offset > 0 { return failsNext.withLock { $0 } ? nil : try Self.body() }
            return try Self.body(statuses: [2, 1])
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        model.approachEnd()
        try await waitUntil { model.runningTaskCount == 0 }
        guard case .failed = display.footerState else {
            Issue.record("続きの失敗を伝えていません: \(display.footerState)")
            return
        }

        await model.refresh()
        #expect(display.footerState == .idle)
    }

    /// 確定してから最初の結果がそろうまでは、確定した操作の結果として動きで見せる。そろったあとに読み直して届いた結果は、動かさずに、行を基準にせずスクロール位置を保つ。
    /// 先に届いた種類の上にあとから届いた種類が入っても、最上部の行が画面の外へ出ないようにするため。
    @Test func firstArrivalsTransitionAndLaterArrivalsKeepOffset() async throws {
        let transport = Self.transport { query in
            query.type == "hashtags" ? try Self.body(hashtags: ["a"]) : try Self.body(accounts: query.type == "accounts" ? [1] : [])
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        display.anchorID = .search("heading-hashtags")
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(Self.rows(display) == ["[accounts]", "@a1", "[hashtags]", "#a"])
        #expect(display.entriesCalls.allSatisfy { $0.isTransition })

        let settled = display.entriesCalls.count
        await model.refresh()
        let later = display.entriesCalls.dropFirst(settled)
        #expect(!later.isEmpty)
        #expect(later.allSatisfy { !$0.isTransition && $0.anchorID == nil && $0.keepsOffset })
    }

    /// 確定した直後は、打っている途中の候補のユーザーとハッシュタグを、その種類の結果が届くまで見出しの下に出す。
    /// 候補の一覧に残っていた行のうち、引き継がない行（「“語”を検索」など）は閉じる動きで消す。
    @Test func carriedRowsStayUntilTheirCategoryArrives() async throws {
        let gate = Gate()
        let transport = RoutedTransport { request in
            let query = Query(request)
            if query.type == "accounts" { try await gate.wait() }
            return (200, query.type == "accounts" ? try Self.body(accounts: [1]) : try Self.body())
        }
        let url = try #require(Bundle.module.url(forResource: "account", withExtension: "json", subdirectory: "Fixtures"))
        let account = try MastodonDecoder.make().decode(Account.self, from: Data(contentsOf: url))
        let hashtag = try MastodonDecoder.make().decode(Hashtag.self, from: Data(#"{"name":"neko","url":"https://example.social/tags/neko","history":[]}"#.utf8))
        let (model, display) = try makeModel("猫", carriedAccounts: [account], carriedHashtags: [hashtag], transport: transport)
        defer { model.stop() }
        model.start()

        #expect(Self.rows(display) == ["[accounts]", "@\(account.id)", "[hashtags]", "#neko"])
        #expect(display.entriesCalls.first?.isTransition == true)
        #expect(display.contentState == .loaded)
        // ハッシュタグは0件で届いたので、引き継いだ行も見出しごと消す。ユーザーは届くまで残す。
        try await waitUntil { transport.requests.count == 3 && Self.rows(display) == ["[accounts]", "@\(account.id)"] }

        gate.open()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(Self.rows(display) == ["[accounts]", "@a1"])
    }

    /// 一覧を付け替えたら、今の結果をその一覧に並べ直す。
    @Test func attachRendersCurrentResults() async throws {
        let transport = Self.transport { query in
            query.type == "statuses" ? try Self.body(statuses: [2, 1]) : try Self.body()
        }
        let (model, _) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }

        let other = RecordingTimelineDisplay()
        model.display = nil
        model.attach(other)
        #expect(other.statusIDs == ["2", "1"])
        #expect(other.contentState == .loaded)
    }

    /// 削除した投稿とミュートした人の投稿は、閉じる動きで除く。
    @Test func removalsAnimate() async throws {
        let transport = Self.transport { query in
            query.type == "statuses" ? try Self.body(statuses: [2, 1]) : try Self.body()
        }
        let (model, display) = try makeModel("猫", transport: transport)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.runningTaskCount == 0 }

        model.removeStatus("2")
        #expect(display.statusIDs == ["1"])
        #expect(display.entriesCalls.last?.animatesRemoval == true)
        model.excludeAccount("2")
        #expect(display.statusIDs.isEmpty)
    }
}

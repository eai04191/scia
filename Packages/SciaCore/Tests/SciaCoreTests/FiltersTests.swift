import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// フィルターを作る、変える、消す。決まりはdocs/filters.mdの「作る、変える、消す」にある。
@MainActor
@Suite(.serialized)
struct FiltersTests {
    private static let original = ServerFilter(
        id: "7", title: "猫", context: [.home, .public], filterAction: .warn, expiresAt: Date(timeIntervalSince1970: 2_000),
        keywords: [
            ServerFilter.Keyword(id: "70", keyword: "cat", wholeWord: true),
            ServerFilter.Keyword(id: "71", keyword: "neko", wholeWord: false),
            ServerFilter.Keyword(id: "72", keyword: "kitten", wholeWord: true),
        ],
        statuses: [ServerFilter.FilteredStatus(id: "9", statusId: "113000000000000001")]
    )

    nonisolated private static func body(id: String, title: String) -> Data {
        Data(##"{"id":"\##(id)","title":"\##(title)","context":["home"],"filter_action":"hide","expires_at":null,"keywords":[],"statuses":[]}"##.utf8)
    }

    private func client(_ transport: RoutedTransport) -> MastodonClient {
        MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)
    }

    private func form(_ request: URLRequest?) throws -> [URLQueryItem] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request?.httpBody), as: UTF8.self)
        return components.queryItems ?? []
    }

    // MARK: - 下書き

    /// 新しいフィルターは、名前を入れるまで保存できない。空のままのキーワードは送らず、変えたことにも数えない。
    @Test func newDraftNeedsTitleAndSkipsBlankKeywords() {
        var draft = FilterDraft()
        #expect(!draft.canSave)
        #expect(!draft.hasChanges)

        draft.title = "  猫 "
        draft.addKeyword()
        draft.keywords[1].keyword = "cat"
        draft.keywords[1].wholeWord = false

        #expect(draft.canSave)
        #expect(draft.hasChanges)
        #expect(draft.trimmedTitle == "猫")
        #expect(draft.newKeywords == [ServerFilter.KeywordDraft(keyword: "cat", wholeWord: false)])
        #expect(Set(draft.keywords.map(\.id)).count == 2)

        draft.contexts = []
        #expect(!draft.canSave)
    }

    /// 変えるときは、変えたキーワード、消したキーワード、足したキーワードだけを送る。サーバーにあるキーワードを空にしたら消す。
    @Test func editingDraftSendsOnlyKeywordChanges() {
        var draft = FilterDraft(editing: Self.original)
        #expect(!draft.hasChanges)
        #expect(draft.expiry == .keep)
        #expect(draft.keywordChanges.isEmpty)

        draft.keywords[0].wholeWord = false
        draft.keywords[1].keyword = " "
        draft.keywords.remove(at: 2)
        draft.addKeyword()
        draft.addKeyword()
        draft.keywords[2].keyword = "ねこ"

        #expect(draft.hasChanges)
        #expect(draft.keywordChanges == [
            ServerFilter.KeywordChange(id: "70", keyword: "cat", wholeWord: false),
            ServerFilter.KeywordChange(id: "71", keyword: "neko", wholeWord: false, removes: true),
            ServerFilter.KeywordChange(id: "72", keyword: "kitten", wholeWord: true, removes: true),
            ServerFilter.KeywordChange(id: nil, keyword: "ねこ", wholeWord: true),
        ])
    }

    /// このアプリが知らない対象は、変えても落とさずに送り返す。
    @Test func unknownContextSurvivesEditing() {
        let filter = ServerFilter(id: "1", title: "f", context: [.other("lists"), .account, .home], filterAction: .hide, keywords: [])
        #expect(FilterDraft(editing: filter).orderedContexts == [.home, .account, .other("lists")])
    }

    // MARK: - 送る形

    /// 変えるときは、キーワードの項目を揃えて送る。期限は、そのままなら送らず、外すなら空で送る。
    @Test func updateSendsKeywordsWithTheSameFields() async throws {
        let transport = RoutedTransport { _ in (200, Self.body(id: "7", title: "猫")) }
        let changes = [
            ServerFilter.KeywordChange(id: "70", keyword: "cat", wholeWord: false),
            ServerFilter.KeywordChange(id: "71", keyword: "neko", wholeWord: false, removes: true),
            ServerFilter.KeywordChange(id: nil, keyword: "ねこ", wholeWord: true),
        ]

        try await RequestPurpose.$current.withValue(.action) {
            _ = try await client(transport).updateFilter("7", title: "猫", context: [.home, .thread], action: .blur, expiry: .keep, keywords: changes)
            _ = try await client(transport).updateFilter("7", title: "猫", context: [.home], action: .warn, expiry: .never, keywords: [])
            _ = try await client(transport).updateFilter("7", title: "猫", context: [.home], action: .warn, expiry: .after(.seconds(1_800)), keywords: [])
        }

        #expect(transport.requests.map(\.httpMethod) == ["PUT", "PUT", "PUT"])
        #expect(transport.requests.map { $0.url?.path() } == Array(repeating: "/api/v2/filters/7", count: 3))
        #expect(try form(transport.requests[0]) == [
            URLQueryItem(name: "title", value: "猫"),
            URLQueryItem(name: "filter_action", value: "blur"),
            URLQueryItem(name: "context[]", value: "home"),
            URLQueryItem(name: "context[]", value: "thread"),
            URLQueryItem(name: "keywords_attributes[][id]", value: "70"),
            URLQueryItem(name: "keywords_attributes[][keyword]", value: "cat"),
            URLQueryItem(name: "keywords_attributes[][whole_word]", value: "false"),
            URLQueryItem(name: "keywords_attributes[][_destroy]", value: "false"),
            URLQueryItem(name: "keywords_attributes[][id]", value: "71"),
            URLQueryItem(name: "keywords_attributes[][keyword]", value: "neko"),
            URLQueryItem(name: "keywords_attributes[][whole_word]", value: "false"),
            URLQueryItem(name: "keywords_attributes[][_destroy]", value: "true"),
            URLQueryItem(name: "keywords_attributes[][id]", value: ""),
            URLQueryItem(name: "keywords_attributes[][keyword]", value: "ねこ"),
            URLQueryItem(name: "keywords_attributes[][whole_word]", value: "true"),
            URLQueryItem(name: "keywords_attributes[][_destroy]", value: "false"),
        ])
        #expect(try form(transport.requests[1]).last == URLQueryItem(name: "expires_in", value: ""))
        #expect(try form(transport.requests[2]).last == URLQueryItem(name: "expires_in", value: "1800"))
    }

    // MARK: - モデル

    /// 読んだフィルターも、作ったり変えたりしたフィルターも、名前の順に並べる。作ると変えるは、受け付けたことを知らせる。
    @Test func savingCreatesOrReplaces() async throws {
        let transport = RoutedTransport { request in
            switch request.httpMethod {
            case "POST": (200, Self.body(id: "3", title: "ab"))
            case "PUT": (200, Self.body(id: "1", title: "0"))
            default: (200, Data("[\(String(decoding: Self.body(id: "1", title: "b"), as: UTF8.self)),\(String(decoding: Self.body(id: "2", title: "A"), as: UTF8.self))]".utf8))
            }
        }
        let model = FiltersModel(api: FiltersModel.API(client: client(transport)), tasks: TaskScope())
        var changes = 0
        model.onChange = { changes += 1 }
        await model.reload(purpose: .action)?.value
        let loaded = try #require(model.filters)
        #expect(loaded.map(\.title) == ["A", "b"])

        var created = FilterDraft()
        created.title = "ab"
        var results: [ErrorPresentation?] = []
        await model.save(created) { results.append($0) }?.value
        #expect(model.filters?.map(\.title) == ["A", "ab", "b"])
        var edited = FilterDraft(editing: loaded[1])
        edited.title = "0"
        await model.save(edited) { results.append($0) }?.value

        #expect(model.filters?.map(\.title) == ["0", "A", "ab"])
        #expect(results == [nil, nil])
        #expect(changes == 2)
        #expect(!model.isSaving)
        #expect(transport.requests.map { $0.url?.path() } == ["/api/v2/filters", "/api/v2/filters", "/api/v2/filters/1"])
    }

    /// 保存できなかったら、理由を返し、リストは変えない。
    @Test func failedSaveReportsReasonAndKeepsList() async throws {
        let transport = RoutedTransport { request in
            request.httpMethod == "GET" ? (200, Data("[]".utf8)) : (422, Data(#"{"error":"Validation failed: Title is too long"}"#.utf8))
        }
        let model = FiltersModel(api: FiltersModel.API(client: client(transport)), tasks: TaskScope())
        var changes = 0
        model.onChange = { changes += 1 }
        await model.reload(purpose: .action)?.value

        var draft = FilterDraft()
        draft.title = "長い"
        var results: [ErrorPresentation?] = []
        await model.save(draft) { results.append($0) }?.value

        #expect(results.count == 1)
        #expect(results.first != .some(nil))
        #expect(model.filters == [])
        #expect(changes == 0)
        #expect(!model.isSaving)
    }

    /// 消せたらリストから外し、消せなかったら残して理由を返す。
    @Test func deletingRemovesOnlyWhenAccepted() async throws {
        let fails = Mutex(true)
        let transport = RoutedTransport { request in
            guard request.httpMethod == "DELETE" else {
                return (200, Data("[\(String(decoding: Self.body(id: "1", title: "一"), as: UTF8.self))]".utf8))
            }
            return fails.withLock { $0 } ? (500, Data("{}".utf8)) : (200, Data("{}".utf8))
        }
        let model = FiltersModel(api: FiltersModel.API(client: client(transport)), tasks: TaskScope())
        await model.reload(purpose: .action)?.value

        var results: [ErrorPresentation?] = []
        await model.delete("1") { results.append($0) }?.value
        #expect(model.filters?.map(\.id) == ["1"])
        #expect(results.count == 1)
        #expect(results.first != .some(nil))

        fails.withLock { $0 = false }
        await model.delete("1") { results.append($0) }?.value
        #expect(model.filters == [])
        #expect(results.last == .some(nil))
    }

    /// 保存を送っている間は消さない。保存の応答が削除のあとに届くと、消したフィルターをリストに戻してしまうため。
    @Test func deleteIsRefusedWhileSaving() async throws {
        let gate = Gate()
        let transport = RoutedTransport { request in
            switch request.httpMethod {
            case "PUT":
                try await gate.wait()
                return (200, Self.body(id: "1", title: "変えた"))
            case "DELETE": return (200, Data("{}".utf8))
            default: return (200, Data("[\(String(decoding: Self.body(id: "1", title: "一"), as: UTF8.self))]".utf8))
            }
        }
        let model = FiltersModel(api: FiltersModel.API(client: client(transport)), tasks: TaskScope())
        await model.reload(purpose: .action)?.value
        var draft = FilterDraft(editing: try #require(model.filters?.first))
        draft.title = "変えた"

        let saving = model.save(draft) { _ in }
        #expect(model.isSaving)
        #expect(model.delete("1") { _ in } == nil)
        gate.open()
        await saving?.value

        #expect(model.filters?.map(\.title) == ["変えた"])
        #expect(!transport.requests.contains { $0.httpMethod == "DELETE" })
    }

    /// 読んでいる間に保存したら、保存する前の応答で古いリストに戻さない。
    @Test func loadStartedBeforeSaveDoesNotOverwrite() async throws {
        let gate = Gate()
        let transport = RoutedTransport { request in
            guard request.httpMethod == "GET" else { return (200, Self.body(id: "3", title: "新しい")) }
            try await gate.wait()
            return (200, Data("[]".utf8))
        }
        let model = FiltersModel(api: FiltersModel.API(client: client(transport)), tasks: TaskScope())
        let loading = model.reload(purpose: .action)
        try await waitUntil { transport.requests.count >= 1 }

        var draft = FilterDraft()
        draft.title = "新しい"
        await model.save(draft) { _ in }?.value
        gate.open()
        await loading?.value

        #expect(model.filters?.map(\.id) == ["3"])
    }
}

import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// ミュートしたユーザー、ブロックしたユーザー、ブロックしたドメインの読み書き。
@MainActor
@Suite(.requestPurpose(.action))
struct ModerationTests {
    private func client(_ transport: StubTransport) -> MastodonClient {
        MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)
    }

    private static let relationship = #"{"id":"2","following":true,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"domain_blocking":true,"endorsed":false,"note":""}"#

    // MARK: - 通信

    /// ミュートとブロックの人のリストは、それぞれのパスで読み、続きを`Link`ヘッダーの`max_id`で読む。
    @Test func mutesAndBlocksUseTheirPaths() async throws {
        let transport = StubTransport([
            .json("[]", statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/mutes?max_id=55>; rel="next""#]),
            .json("[]", statusCode: 200),
        ])
        let client = client(transport)

        let mutes = try await client.accounts(in: .mutes, maxID: nil, limit: 40)
        _ = try await client.accounts(in: .blocks, maxID: "55", limit: 40)

        #expect(mutes.nextMaxID == "55")
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == ["/api/v1/mutes", "/api/v1/blocks"])
        #expect(requests[1].url?.query()?.contains("max_id=55") == true)
    }

    /// ブロックしたドメインは文字列の配列で返り、続きを`Link`ヘッダーで読む。足すのはPOST、解除はDELETEで、どちらもドメインをフォームで送る。
    @Test func domainBlocksReadAddAndRemove() async throws {
        let transport = StubTransport([
            .json(#"["a.example","b.example"]"#, statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/domain_blocks?max_id=16194>; rel="next", <https://example.social/api/v1/domain_blocks?since_id=16337>; rel="prev""#]),
            .json("{}", statusCode: 200),
            .json("{}", statusCode: 200),
        ])
        let client = client(transport)

        let page = try await client.domainBlocks(maxID: nil, limit: 100)
        try await client.blockDomain("c.example")
        try await client.unblockDomain("a.example")

        #expect(page == DomainBlockPage(domains: ["a.example", "b.example"], nextMaxID: "16194"))
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "DELETE"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/domain_blocks", "/api/v1/domain_blocks", "/api/v1/domain_blocks"])
        #expect(requests.dropFirst().map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } } == ["domain=c.example", "domain=a.example"])
    }

    /// ユーザーのメニューのドメインのブロックは、応答が空なので、送ったあとに相手との関係を読み直して返す。
    @Test func domainBlockFromMenuReadsRelationshipBack() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200), .json("[\(Self.relationship)]", statusCode: 200)])

        let relationship = try await client(transport).send(.blockDomain("remote.example"), to: "2")

        #expect(relationship.domainBlocking)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "GET"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/domain_blocks", "/api/v1/accounts/relationships"])
    }

    /// ドメインのブロックは送れたのに、そのあとの関係の読み直しだけ失敗したら、送れたことが分かる失敗にする。送れなかったときと同じ失敗にすると、ブロックできたのに失敗と知らせるため。
    @Test func domainBlockAppliedEvenIfRelationshipReloadFails() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200), .json("{}", statusCode: 500)])

        await #expect(throws: RelationChangeAppliedError.self) {
            try await client(transport).send(.blockDomain("remote.example"), to: "2")
        }
        #expect(await transport.requests.first?.httpMethod == "POST")
    }

    // MARK: - 人のリスト

    /// ミュートとブロックのリストは、解除したらその人の行を消す。ほかのリストは関係で行を決めない。
    @Test func accountListsDropUnmutedAndUnblocked() {
        #expect(AccountListKind.mutes.contains(Relationship(id: "2", muting: true)) == true)
        #expect(AccountListKind.mutes.contains(Relationship(id: "2", blocking: true)) == false)
        #expect(AccountListKind.blocks.contains(Relationship(id: "2", blocking: true)) == true)
        #expect(AccountListKind.blocks.contains(Relationship(id: "2", muting: true)) == false)
        #expect(AccountListKind.followers(accountID: "1").contains(Relationship(id: "2")) == nil)
        #expect(AccountListKind.mutes.removalChange.map { String(describing: $0) } == "unmute")
        #expect(AccountListKind.blocks.removalChange.map { String(describing: $0) } == "unblock")
        #expect(AccountListKind.listMembers(listID: "1").removalChange == nil)
    }

    /// Mastodonはドメインをブロックすると、そのドメインの人への自分のフォローも外すので、フォローを変える変更として相手のフォロワー数を読み直す。解除では戻らない。
    @Test func domainBlockChangesFollow() {
        #expect(UserRelationChange.blockDomain("remote.example").changesFollow)
        #expect(!UserRelationChange.unblockDomain("remote.example").changesFollow)
    }

    // MARK: - ブロックしたドメインのモデル

    private final class Server: Sendable {
        let pages: Mutex<[String?: DomainBlockPage]>
        let blocked = Mutex<[String]>([])
        let unblocked = Mutex<[String]>([])
        let fails = Mutex(false)
        /// 読み込みを止める門。読み込みごとに替えられる。
        let loadGate = Mutex(Gate(isOpen: true))

        init(pages: [String?: DomainBlockPage]) {
            self.pages = Mutex(pages)
        }

        var api: DomainBlocksModel.API {
            DomainBlocksModel.API(
                load: { maxID in
                    try await self.loadGate.withLock { $0 }.wait()
                    if self.fails.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                    return try #require(self.pages.withLock { $0[maxID] })
                },
                block: { domain in
                    if self.fails.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                    self.blocked.withLock { $0.append(domain) }
                },
                unblock: { domain in
                    if self.fails.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                    self.unblocked.withLock { $0.append(domain) }
                }
            )
        }
    }

    /// 続きのページは後ろにつなぎ、重なったドメインは1度だけ並べる。続きがなくなれば読まない。
    @Test func loadsPagesUntilEnd() async {
        let server = Server(pages: [
            nil: DomainBlockPage(domains: ["a.example", "b.example"], nextMaxID: "10"),
            "10": DomainBlockPage(domains: ["b.example", "c.example"], nextMaxID: nil),
        ])
        let model = DomainBlocksModel(api: server.api, tasks: TaskScope())

        await model.reload(purpose: .action)?.value
        #expect(model.domains == ["a.example", "b.example"])
        #expect(!model.reachedEnd)
        await model.loadMore(purpose: .display)?.value

        #expect(model.domains == ["a.example", "b.example", "c.example"])
        #expect(model.reachedEnd)
        #expect(model.loadMore(purpose: .display) == nil)
    }

    /// 入れた文字はドメインの形に直して送り、受け付けたら先頭に足す。解除を受け付けたら外す。
    @Test func blockNormalizesAndUnblockRemoves() async {
        let server = Server(pages: [nil: DomainBlockPage(domains: ["a.example"], nextMaxID: nil)])
        let model = DomainBlocksModel(api: server.api, tasks: TaskScope())
        var changed: [String] = []
        model.onChange = { changed.append($0) }
        await model.reload(purpose: .action)?.value

        var results: [ErrorPresentation?] = []
        await model.block(" https://Remote.Example/@bob ") { results.append($0) }?.value
        await model.unblock("a.example") { results.append($0) }?.value

        #expect(server.blocked.withLock { $0 } == ["remote.example"])
        #expect(server.unblocked.withLock { $0 } == ["a.example"])
        #expect(model.domains == ["remote.example"])
        #expect(results == [nil, nil])
        #expect(changed == ["remote.example", "a.example"])
        #expect(model.block("  ") { _ in } == nil)
    }

    /// 送れなかったら理由を返し、リストは変えない。
    @Test func failedChangeKeepsList() async {
        let server = Server(pages: [nil: DomainBlockPage(domains: ["a.example"], nextMaxID: nil)])
        let model = DomainBlocksModel(api: server.api, tasks: TaskScope())
        await model.reload(purpose: .action)?.value
        server.fails.withLock { $0 = true }

        var results: [ErrorPresentation?] = []
        await model.block("b.example") { results.append($0) }?.value
        await model.unblock("a.example") { results.append($0) }?.value
        await model.reload(purpose: .action)?.value

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0 != nil })
        #expect(model.domains == ["a.example"])
        #expect(model.loadFailure == nil)
    }

    /// 読み込みの途中で足したら、その前に送った読み込みの応答で、足したドメインのないリストに戻さない。
    @Test func changeDuringLoadIsNotOverwritten() async throws {
        let server = Server(pages: [nil: DomainBlockPage(domains: ["a.example"], nextMaxID: nil)])
        let model = DomainBlocksModel(api: server.api, tasks: TaskScope())
        await model.reload(purpose: .action)?.value
        let gate = Gate()
        server.loadGate.withLock { $0 = gate }

        let load = model.reload(purpose: .display)
        try await waitUntil { gate.waiterCount == 1 }
        await model.block("b.example") { _ in }?.value
        gate.open()
        await load?.value

        #expect(model.domains == ["b.example", "a.example"])
    }
}

@MainActor
@Suite(.requestPurpose(.action))
struct DomainBlocksRaceTests {
    private final class Server: Sendable {
        let pages: Mutex<[String?: DomainBlockPage]>
        let loadGate = Mutex(Gate(isOpen: true))
        let loads = Mutex(0)

        init(pages: [String?: DomainBlockPage]) {
            self.pages = Mutex(pages)
        }

        var api: DomainBlocksModel.API {
            DomainBlocksModel.API(
                load: { maxID in
                    self.loads.withLock { $0 += 1 }
                    let page = try #require(self.pages.withLock { $0[maxID] })
                    try await self.loadGate.withLock { $0 }.wait()
                    return page
                },
                block: { _ in },
                unblock: { _ in }
            )
        }
    }

    /// 続きを読んでいる途中に解除したドメインを、重なったページの応答で戻さない。
    @Test func unblockDuringLoadMoreIsKept() async throws {
        let server = Server(pages: [
            nil: DomainBlockPage(domains: ["a.example", "b.example"], nextMaxID: "10"),
            "10": DomainBlockPage(domains: ["b.example", "c.example"], nextMaxID: nil),
        ])
        let model = DomainBlocksModel(api: server.api, tasks: TaskScope())
        await model.reload(purpose: .action)?.value
        let gate = Gate()
        server.loadGate.withLock { $0 = gate }

        let more = model.loadMore(purpose: .display)
        try await waitUntil { gate.waiterCount == 1 }
        await model.unblock("b.example") { _ in }?.value
        gate.open()
        await more?.value

        #expect(model.domains == ["a.example", "c.example"])
    }

    /// 読んでいる途中にほかの入口（ユーザーのメニュー）でドメインのブロックが変わったら、その読み込みの応答を捨て、終わってから読み直す。
    @Test func outsideChangeDuringLoadReloadsAfterward() async throws {
        let server = Server(pages: [nil: DomainBlockPage(domains: ["a.example"], nextMaxID: nil)])
        let model = DomainBlocksModel(api: server.api, tasks: TaskScope())
        await model.reload(purpose: .action)?.value
        let gate = Gate()
        server.loadGate.withLock { $0 = gate }

        let load = model.reload(purpose: .display)
        try await waitUntil { gate.waiterCount == 1 }
        server.pages.withLock { $0[nil] = DomainBlockPage(domains: ["new.example", "a.example"], nextMaxID: nil) }
        model.didChangeOutside()
        gate.open()
        await load?.value
        try await waitUntil { model.domains == ["new.example", "a.example"] && model.runningTaskCount == 0 }

        #expect(server.loads.withLock { $0 } == 3)
    }

    /// 初めて読んでいる途中に変わっても、その応答を捨て、読み終えてから読み直す。
    @Test func outsideChangeDuringFirstLoadReloadsAfterward() async throws {
        let server = Server(pages: [nil: DomainBlockPage(domains: ["a.example"], nextMaxID: nil)])
        let model = DomainBlocksModel(api: server.api, tasks: TaskScope())
        let gate = Gate()
        server.loadGate.withLock { $0 = gate }

        let load = model.reload(purpose: .display)
        try await waitUntil { gate.waiterCount == 1 }
        server.pages.withLock { $0[nil] = DomainBlockPage(domains: ["new.example", "a.example"], nextMaxID: nil) }
        model.didChangeOutside()
        gate.open()
        await load?.value
        try await waitUntil { model.domains == ["new.example", "a.example"] && model.runningTaskCount == 0 }

        #expect(server.loads.withLock { $0 } == 2)
    }
}

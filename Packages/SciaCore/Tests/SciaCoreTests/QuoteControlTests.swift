import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 引用できる人の変更と、引用の取り消し。決まりはdocs/quote.mdの「投稿したあとに変える」と「引用を取り消す」にある。
@MainActor
@Suite(.serialized)
struct QuoteControlTests {
    private nonisolated static let me = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)

    private nonisolated static func status(_ id: String, automatic: [String] = ["public"], quotesCount: Int = 0, quote: Quote? = nil) -> Status {
        Status(
            id: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000), account: me, content: "<p>\(id)</p>", spoilerText: "", url: nil,
            quote: quote, quoteApproval: QuoteApproval(automatic: automatic, currentUser: "automatic"), quotesCount: quotesCount
        )
    }

    /// 一覧の代わりに、配られた変化を当てた投稿を持つ。
    private final class List: SessionStatusList {
        var statuses: [Status.ID: Status]
        var revokedQuotes: [Status.ID] = []

        init(_ statuses: [Status]) {
            self.statuses = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        }

        func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
            statuses[id] = statuses[id].map(transform)
        }

        func removeStatus(_ id: Status.ID) {
            statuses[id] = nil
        }

        func quoteWasRevoked(by quotingID: Status.ID) {
            revokedQuotes.append(quotingID)
        }
    }

    private func makeControl(_ list: List, respond: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) -> (QuoteControl, RoutedTransport) {
        let transport = RoutedTransport(respond)
        let statuses = SessionStatuses()
        statuses.register(list)
        return (QuoteControl(client: MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport), statuses: statuses, tasks: TaskScope()), transport)
    }

    /// 変えられたら、サーバーの応答の引用できる人を、その投稿を持つ一覧に当てる。ほかの中身は変えない。
    @Test func settingPolicyAdoptsServerApproval() async throws {
        let list = List([Self.status("10").settingFavourited(true)])
        let (control, transport) = makeControl(list) { _ in (200, try TimelineModelFixtures.body(Self.status("10", automatic: ["followers"]))) }
        let finished = Gate()

        control.setPolicy(.followers, of: Self.status("10")) { error in
            #expect(error == nil)
            finished.open()
        }
        try await finished.wait()

        #expect(list.statuses["10"]?.quoteApproval?.policy == .followers)
        #expect(list.statuses["10"]?.favourited == true)
        #expect(transport.requests.map { $0.url?.path() } == ["/api/v1/statuses/10/interaction_policy"])
    }

    /// 変えられなければ、一覧に触れずに理由を渡す。
    @Test func failedPolicyChangeLeavesStatus() async throws {
        let list = List([Self.status("10")])
        let (control, _) = makeControl(list) { _ in (422, Data(#"{"error":"Unprocessable"}"#.utf8)) }
        let finished = Gate()

        control.setPolicy(.nobody, of: Self.status("10")) { error in
            #expect(error != nil)
            finished.open()
        }
        try await finished.wait()

        #expect(list.statuses["10"]?.quoteApproval?.policy == .public)
    }

    /// 取り消せたら、引用した投稿の引用を取り消した状態にし、引用元の引用の数を1つ減らし、引用した投稿のタイムラインに取り消しを知らせる。
    @Test func revokingMarksQuoteRevokedAndDecrementsCount() async throws {
        let quoted = Self.status("10", quotesCount: 2)
        let quoting = Self.status("20", quote: Quote(state: "accepted", quotedStatus: quoted))
        let list = List([quoted, quoting])
        let (control, transport) = makeControl(list) { _ in (200, try TimelineModelFixtures.body(Self.status("20", quote: Quote(state: "revoked")))) }
        let finished = Gate()

        control.revoke(quoting) { error in
            #expect(error == nil)
            finished.open()
        }
        try await finished.wait()

        #expect(list.statuses["20"]?.quote?.state == .revoked)
        #expect(list.statuses["10"]?.quotesCount == 1)
        #expect(list.revokedQuotes == ["20"])
        #expect(transport.requests.map { $0.url?.path() } == ["/api/v1/statuses/10/quotes/20/revoke"])
    }
}

import Foundation
import Testing
@testable import SciaCore

/// 投稿の中の引用を、`state`とフィルターに従ってどう出すかを確かめる。決まりは`docs/quote.md`。
struct QuoteDisplayTests {
    private let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(_ id: String, content: String = "<p>本文</p>", quote: Quote? = nil, filtered: [FilterResult] = [], reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: bob, content: content, spoilerText: "", url: nil, quote: quote, filtered: filtered, reblog: reblog)
    }

    private func display(_ status: Status, isRevealed: Bool = false, verdict: (Status) -> FilterVerdict = { _ in .none }) -> QuoteDisplay? {
        QuoteDisplay(quoting: status, isRevealed: isRevealed, verdict: verdict)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// 引用元は`Quote`で投稿ごと届き、引用元の中の引用は`ShallowQuote`でIDだけが届く。
    @Test func decodesQuotedStatusAndShallowQuote() throws {
        let status = try MastodonDecoder.make().decode(Status.self, from: try fixture("status_with_quote"))
        let quote = try #require(status.quote)
        let quoted = try #require(quote.quotedStatus)

        #expect(quote.state == .accepted)
        #expect(quoted.id == "200")
        #expect(quote.quotedStatusID == "200")
        #expect(quoted.quote?.state == .accepted)
        #expect(quoted.quote?.quotedStatus == nil)
        #expect(quoted.quote?.quotedStatusID == "150")
    }

    /// 引用のある投稿では、サーバーが互換のために足す`RE: <リンク>`の段落を本文から除く。
    @Test func dropsQuoteInlineFromQuotingStatus() throws {
        let status = try MastodonDecoder.make().decode(Status.self, from: try fixture("status_with_quote"))

        #expect(RichText.status(status).plainText == "引用した本文")
    }

    /// 引用のない投稿では、同じクラスの段落も書いた人の本文として残す。
    @Test func keepsQuoteInlineWithoutQuote() {
        let content = #"<p class="quote-inline">RE: <a href="https://example.social/@bob/1">example.social/@bob/1</a></p><p>本文</p>"#

        #expect(RichText.status(status("1", content: content)).plainText.hasPrefix("RE: "))
    }

    /// 出せない`state`でも、`quote`があれば除く。引用の囲みの代わりに、出せない理由の1行を出すため。
    @Test func dropsQuoteInlineWhenQuoteIsUnavailable() {
        let content = #"<p class="quote-inline">RE: <a href="https://example.social/@bob/1">example.social/@bob/1</a></p><p>本文</p>"#

        #expect(RichText.status(status("1", content: content, quote: Quote(state: "pending"))).plainText == "本文")
    }

    @Test func showsAcceptedQuote() {
        let quoted = status("10")

        #expect(display(status("1", quote: Quote(state: "accepted", quotedStatus: quoted))) == .post(quoted))
        #expect(display(status("1")) == nil)
    }

    /// 知らない`state`は、ドキュメントに従って`unauthorized`として扱う。
    @Test func unavailableStatesShowReason() {
        #expect(display(status("1", quote: Quote(state: "pending"))) == .unavailable(.pending))
        #expect(display(status("1", quote: Quote(state: "rejected"))) == .unavailable(.withdrawn))
        #expect(display(status("1", quote: Quote(state: "revoked"))) == .unavailable(.withdrawn))
        #expect(display(status("1", quote: Quote(state: "deleted"))) == .unavailable(.deleted))
        #expect(display(status("1", quote: Quote(state: "unauthorized"))) == .unavailable(.unauthorized))
        #expect(display(status("1", quote: Quote(state: "a_future_state"))) == .unavailable(.unauthorized))
    }

    /// 出せる`state`なのに引用元が読めなかったときは、見られないものとして出す。
    @Test func acceptedWithoutQuotedStatusIsUnauthorized() {
        #expect(display(status("1", quote: Quote(state: "accepted"))) == .unavailable(.unauthorized))
    }

    /// 投稿を削除した応答などでは、出せない`state`でも引用元が入る。`state`に従って出さない。
    @Test func unavailableStateIgnoresQuotedStatus() {
        #expect(display(status("1", quote: Quote(state: "revoked", quotedStatus: status("10")))) == .unavailable(.withdrawn))
    }

    /// ブロックかミュートしている人の引用元は、押して開くまで出さない。
    @Test func blockedAndMutedAreConcealedUntilRevealed() {
        let quoted = status("10")

        #expect(display(status("1", quote: Quote(state: "blocked_account", quotedStatus: quoted))) == .concealed(.blockedAccount, quoted))
        #expect(display(status("1", quote: Quote(state: "blocked_domain", quotedStatus: quoted))) == .concealed(.blockedDomain, quoted))
        #expect(display(status("1", quote: Quote(state: "muted_account", quotedStatus: quoted))) == .concealed(.mutedAccount, quoted))
        #expect(display(status("1", quote: Quote(state: "muted_account", quotedStatus: quoted)), isRevealed: true) == .post(quoted))
    }

    /// 引用元がフィルターの「隠す」に一致したら、外側の投稿は出したまま、隠したことを示す。
    @Test func hiddenByFilterShowsFilteredLine() {
        let quoted = status("10")
        let hidden = FilterVerdict(isHidden: true, warningTitles: [], mediaTitles: [], ownMatchTitles: [])

        #expect(display(status("1", quote: Quote(state: "accepted", quotedStatus: quoted))) { $0.id == "10" ? hidden : .none } == .filtered)
    }

    /// フィルターの判定には、外側の投稿ではなく引用元の投稿を渡す。
    @Test func filterVerdictIsForQuotedStatus() {
        let hide = FilterResult(filter: FilterResult.Filter(id: "f", title: "隠す", context: [.home], filterAction: .hide), keywordMatches: ["x"])
        let quoted = status("10", filtered: [hide])
        let filtering = StatusFiltering(context: .home, myAccountID: "1")

        #expect(display(status("1", quote: Quote(state: "accepted", quotedStatus: quoted))) { filtering.verdict(for: $0) } == .filtered)
    }

    /// 囲みは1段だけ。引用元の中の引用は、IDが届くときだけ押せる1行にする。
    @Test func nestedQuoteLinksOnlyWithID() {
        #expect(NestedQuote(Quote(state: "accepted", quotedStatusID: "5")) == .link("5"))
        #expect(NestedQuote(Quote(state: "muted_account", quotedStatusID: "5")) == .link("5"))
        #expect(NestedQuote(Quote(state: "accepted")) == .unavailable(.unauthorized))
        #expect(NestedQuote(Quote(state: "pending")) == .unavailable(.pending))
        #expect(NestedQuote(Quote(state: "deleted")) == .unavailable(.deleted))
        #expect(NestedQuote(nil) == nil)
    }

    /// 開いたかは引用した投稿で覚え、ブーストの行もそろえる。
    @Test func revealsApplyToBoostsOfSameStatus() {
        let original = status("1")
        var reveals = QuoteReveals()
        reveals.reveal(original)

        #expect(reveals.isRevealed(status("2", reblog: original)))
        #expect(!reveals.isRevealed(status("3")))
    }
}

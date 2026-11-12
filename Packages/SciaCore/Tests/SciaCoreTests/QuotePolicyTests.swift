import Foundation
@testable import SciaCore
import Testing

/// 引用できる人の読み方。決まりはdocs/quote.mdの「引用できる人を決める」にある。
struct QuotePolicyTests {
    /// 投稿の値は`automatic`の先頭から読み、3つのどれでもなければ「自分のみ」にする。
    @Test(arguments: [
        (["public"], QuotePolicy.public),
        (["followers"], .followers),
        (["followers", "following"], .followers),
        ([], .nobody),
        (["unsupported_policy"], .nobody),
    ])
    func approvalPolicyReadsFirstAutomatic(automatic: [String], expected: QuotePolicy) {
        #expect(QuoteApproval(automatic: automatic, currentUser: "automatic").policy == expected)
    }

    @Test func statusReadsQuotesCount() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        func status(_ extra: String) throws -> Status {
            let json = #"{"id":"1","created_at":"2026-10-13T03:21:45Z","spoiler_text":"","content":"","sensitive":false,"account":{"id":"1","username":"a","acct":"a","display_name":"A","avatar":"https://example.social/a.png","note":"","fields":[],"emojis":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0}\#(extra)}"#
            return try decoder.decode(Status.self, from: Data(json.utf8))
        }

        #expect(try status(#","quotes_count":3"#).quotesCount == 3)
        #expect(try status("").quotesCount == 0)
    }

    @Test func scheduledParamsReadQuotePolicy() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func params(_ json: String) throws -> ScheduledStatus.Params {
            try decoder.decode(ScheduledStatus.Params.self, from: Data(json.utf8))
        }

        #expect(try params(#"{"text":"a","quote_approval_policy":"followers"}"#).quotePolicy == .followers)
        #expect(try params(#"{"text":"a","quote_approval_policy":null}"#).quotePolicy == nil)
        #expect(try params(#"{"text":"a"}"#).quotePolicy == nil)
    }
}

import Foundation
import Testing
@testable import SciaCore

struct LinkBrowserTests {
    @Test(arguments: ["https://example.com/a", "http://example.com/a", "HTTPS://example.com/a"])
    func opensWebLinksInAppWhenChosen(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(LinkBrowser.inApp.browser(for: url) == .inApp)
        #expect(LinkBrowser.external.browser(for: url) == .external)
    }

    /// アプリ内のSafariはhttpとhttps以外を渡すと落ちるため、Mastodonが本文に許すほかのスキームは外で開く。
    @Test(arguments: ["gemini://example.org/", "magnet:?xt=urn:btih:abc", "xmpp:user@example.org", "ipfs://bafy"])
    func opensOtherSchemesExternally(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(LinkBrowser.inApp.browser(for: url) == .external)
    }
}

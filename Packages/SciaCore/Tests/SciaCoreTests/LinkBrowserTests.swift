import Foundation
import Testing
@testable import SciaCore

struct LinkBrowserTests {
    @Test(arguments: ["https://example.com/a", "http://example.com/a", "HTTPS://example.com/a"])
    func opensWebLinksInAppWhenChosen(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(LinkBrowser.inApp.browser(for: url) == .inApp)
        #expect(LinkBrowser.inAppFullScreen.browser(for: url) == .inAppFullScreen)
        #expect(LinkBrowser.external.browser(for: url) == .external)
    }

    /// アプリ内のSafariはhttpとhttps以外を渡すと落ちるため、Mastodonが本文に許すほかのスキームは外で開く。
    @Test(arguments: ["gemini://example.org/", "magnet:?xt=urn:btih:abc", "xmpp:user@example.org", "ipfs://bafy"])
    func opensOtherSchemesExternally(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(LinkBrowser.inApp.browser(for: url) == .external)
        #expect(LinkBrowser.inAppFullScreen.browser(for: url) == .external)
    }

    /// メニューの「アプリ内のSafariで開く」は、設定で全画面を選んでいれば全画面、ほかはシートで開く。
    @Test(arguments: [(LinkBrowser.external, LinkBrowser.inApp), (.inApp, .inApp), (.inAppFullScreen, .inAppFullScreen)])
    func menuOpensInAppSafariInChosenStyle(setting: LinkBrowser, expected: LinkBrowser) throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(URLMenuAction.openInAppSafari.browser(for: url, following: setting) == expected)
        let mail = try #require(URL(string: "mailto:a@example.com"))
        #expect(URLMenuAction.openInAppSafari.browser(for: mail, following: setting) == nil)
    }
}

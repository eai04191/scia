import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// カスタム絵文字ごとの描き方を確かめる。決まりはdocs/animated-custom-emoji.mdの「絵文字ごとの描き方」にある。
@Suite(.scratch)
@MainActor
struct CustomEmojiDisplayTests {
    private func emoji(_ shortcode: String, domain: String? = nil) -> CustomEmoji {
        CustomEmoji(
            shortcode: shortcode,
            url: URL(filePath: "/emoji/\(shortcode).gif"),
            staticUrl: URL(filePath: "/emoji/static/\(shortcode).png"),
            domain: domain
        )
    }

    private func accountJSON(acct: String, emojis: String = "[]") -> String {
        """
        {"id": "1", "username": "alice", "acct": "\(acct)", "display_name": ":name:", "note": "", "locked": false, "bot": false,
         "followers_count": 0, "following_count": 0, "statuses_count": 0, "emojis": \(emojis)}
        """
    }

    private func emojiJSON(_ shortcode: String) -> String {
        #"{"shortcode": "\#(shortcode)", "url": "https://files.example/\#(shortcode).gif", "static_url": "https://files.example/\#(shortcode).png", "visible_in_picker": true}"#
    }

    private func statusJSON(acct: String, reblog: String = "null") -> String {
        """
        {"id": "10", "created_at": "2026-01-01T00:00:00.000Z", "content": "<p>:body:</p>", "spoiler_text": "", "sensitive": false,
         "account": \(accountJSON(acct: acct, emojis: "[\(emojiJSON("name"))]")),
         "emojis": [\(emojiJSON("body"))],
         "poll": {"id": "5", "expires_at": null, "expired": false, "multiple": false, "votes_count": 0, "options": [{"title": ":choice:", "votes_count": 0}], "emojis": [\(emojiJSON("choice"))]},
         "reblog": \(reblog)}
        """
    }

    private func decodeStatus(_ json: String) throws -> Status {
        try MastodonDecoder.make().decode(Status.self, from: Data(json.utf8))
    }

    /// APIは絵文字のサーバーを返さないので、本文、投票、表示名の絵文字に、書いた人のサーバーを付ける。ログインしているサーバーの人ならnil。
    @Test func decodedEmojisBelongToAuthorsServer() throws {
        let remote = try decodeStatus(statusJSON(acct: "alice@remote.example"))
        #expect(remote.emojis.map(\.domain) == ["remote.example"])
        #expect(remote.poll?.emojis.map(\.domain) == ["remote.example"])
        #expect(remote.account.emojis.map(\.domain) == ["remote.example"])

        let local = try decodeStatus(statusJSON(acct: "alice"))
        #expect(local.emojis.map(\.domain) == [nil])
        #expect(local.account.emojis.map(\.domain) == [nil])
    }

    /// ブーストは、ブーストした人ではなく、元の投稿を書いた人のサーバーの絵文字として読む。
    @Test func reblogEmojisBelongToOriginalAuthor() throws {
        let boost = try decodeStatus(statusJSON(acct: "bob", reblog: statusJSON(acct: "alice@remote.example")))
        #expect(boost.reblog?.emojis.map(\.domain) == ["remote.example"])
        #expect(boost.account.emojis.map(\.domain) == [nil])
    }

    /// 投票したときに届く投票は、絵文字のサーバーを持たないので、差し替えるときに投稿を書いた人のサーバーを付け直す。
    @Test func adoptedPollKeepsAuthorsServer() throws {
        let status = try decodeStatus(statusJSON(acct: "alice@remote.example"))
        let result = try MastodonDecoder.make().decode(Poll.self, from: Data("""
            {"id": "5", "expires_at": null, "expired": false, "multiple": false, "votes_count": 1, "voted": true, "own_votes": [0],
             "options": [{"title": ":choice:", "votes_count": 1}], "emojis": [\(emojiJSON("choice"))]}
            """.utf8))
        #expect(status.adoptingPoll(result).poll?.emojis.map(\.domain) == ["remote.example"])
    }

    /// ChuckyaとFirefishの形のサーバーは、ほかのサーバーの絵文字のリアクションを`shortcode@host`の名前で返すので、名前のサーバーを絵文字のサーバーにする。
    @Test func reactionEmojiCarriesServer() throws {
        let url = URL(filePath: "/emoji/blobcat.gif")
        let fedibird = try #require(ReactionEmoji(name: "blobcat", domain: "remote.example", url: url).customEmoji)
        #expect(fedibird.shortcode == "blobcat")
        #expect(fedibird.domain == "remote.example")
        let chuckya = try #require(ReactionEmoji(name: "blobcat@remote.example", url: url).customEmoji)
        #expect(chuckya.shortcode == "blobcat")
        #expect(chuckya.domain == "remote.example")
        #expect(try #require(ReactionEmoji(name: "blobcat", url: url).customEmoji).domain == nil)
    }

    /// 補完で選んだ人のように、保存して読み戻す絵文字も、付けたサーバーを保つ。読み戻すと、ログインしているサーバーの同じショートコードの絵文字と取り違えるため。
    @Test func storedMentionKeepsEmojiServer() throws {
        let account = try MastodonDecoder.make().decode(Account.self, from: Data(accountJSON(acct: "alice@remote.example", emojis: "[\(emojiJSON("name"))]").utf8))
        let stored = try JSONEncoder().encode([LocalMention(account: account)])
        let restored = try JSONDecoder().decode([LocalMention].self, from: stored)
        #expect(restored.first?.emojis.map(\.domain) == ["remote.example"])
    }

    /// サーバーの付いていない絵文字は、ログインしているサーバーの絵文字として引く。サーバーの名前は大文字と小文字を区別しない。
    /// 同じショートコードでも、サーバーが違えば別の絵文字。
    @Test func displaysAreLookedUpByShortcodeAndServer() {
        let rule = CustomEmojiDisplayRule(id: CustomEmojiID(shortcode: "blobcat", domain: "Remote.Example"), display: .hidden, url: emoji("blobcat").url, staticUrl: emoji("blobcat").staticUrl)
        let fromRemoteAccount = CustomEmojiDisplays(rules: [rule], localServer: "remote.example")
        let fromOtherAccount = CustomEmojiDisplays(rules: [rule], localServer: "home.example")

        #expect(fromRemoteAccount.display(of: emoji("blobcat")) == .hidden)
        #expect(fromOtherAccount.display(of: emoji("blobcat", domain: "remote.example")) == .hidden)
        #expect(fromOtherAccount.display(of: emoji("blobcat")) == .plays)
        #expect(fromOtherAccount.display(of: emoji("blobcat", domain: "third.example")) == .plays)
        #expect(fromOtherAccount.display(of: emoji("blobfox", domain: "remote.example")) == .plays)
    }

    /// アカウントの設定で変えた絵文字は、ほかのサーバーのアカウントの設定からも、同じ絵文字として引ける。変えた順に並べ、選び直しても位置は変えない。
    /// 既定に戻したら一覧から外す。
    @Test func settingDisplayIsSharedAcrossAccounts() throws {
        let defaults = TestScratch.defaults("CustomEmojiDisplayTests")
        let app = AppSettings(defaults: defaults)
        let home = app.forAccount("@alice@home.example")
        let other = app.forAccount("@alice@other.example")

        home.setCustomEmojiDisplay(.playsSlowly, of: emoji("first"))
        home.setCustomEmojiDisplay(.still, of: emoji("second", domain: "remote.example"))
        home.setCustomEmojiDisplay(.shortcode, of: emoji("first"))

        #expect(other.customEmojiDisplay(of: emoji("first", domain: "home.example")) == .shortcode)
        #expect(other.customEmojiDisplay(of: emoji("first")) == .plays)
        #expect(other.customEmojiDisplay(of: emoji("second", domain: "remote.example")) == .still)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.customEmojiDisplayRules.map(\.id) == [
            CustomEmojiID(shortcode: "first", domain: "home.example"),
            CustomEmojiID(shortcode: "second", domain: "remote.example"),
        ])
        #expect(reloaded.customEmojiDisplayRules.map(\.display) == [.shortcode, .still])

        reloaded.forAccount("@alice@home.example").setCustomEmojiDisplay(.plays, of: emoji("first"))
        #expect(AppSettings(defaults: defaults).customEmojiDisplayRules.map(\.id.shortcode) == ["second"])
    }

    /// 一覧を変えたら、描き方の引き方も変わる。
    @Test func displaysFollowRuleChanges() {
        let settings = AppSettings(defaults: TestScratch.defaults("CustomEmojiDisplayTests")).forAccount("@alice@home.example")
        settings.setCustomEmojiDisplay(.hidden, of: emoji("blobcat"))
        #expect(settings.customEmojiDisplay(of: emoji("blobcat")) == .hidden)

        settings.customEmojiDisplayRules.removeAll()
        #expect(settings.customEmojiDisplay(of: emoji("blobcat")) == .plays)
    }

    /// 置く側が描き方を変えられるときだけ「表示」を出し、今の描き方にチェックマークを付ける。名前の下に今の描き方を出す。
    @Test func menuOffersDisplayChoices() throws {
        var tree = CustomEmojiMenuTree(emoji: emoji("blobcat"))
        #expect(!MenuNodeTests.describe(tree.menu(groups: MenuFixture.customEmoji.groups).children).contains("表示"))

        tree.display = .still
        let menu = tree.menu(groups: MenuFixture.customEmoji.groups)
        let display = try #require(menu.children.flatMap(\.children).first { $0.title == "表示" })
        #expect(display.subtitle == "アニメーションしない")
        #expect(MenuNodeTests.describe([display]) == "表示[表示する,遅く再生,アニメーションしない✓,ショートコードで表示,表示しない]")
        guard case .setDisplay(.hidden) = display.children.last?.command else {
            Issue.record("“表示しない”で描き方を変えない")
            return
        }
    }

    /// 動かないと分かった絵文字では、動きだけを変える選択肢を出さない。選んである描き方は、チェックマークが消えないよう残す。
    @Test func menuHidesMotionChoicesForKnownStillEmoji() throws {
        var tree = CustomEmojiMenuTree(emoji: emoji("blobcat"))
        tree.isKnownStill = true
        func describeDisplay() throws -> String {
            let menu = tree.menu(groups: MenuFixture.customEmoji.groups)
            return MenuNodeTests.describe([try #require(menu.children.flatMap(\.children).first { $0.title == "表示" })])
        }

        tree.display = .plays
        #expect(try describeDisplay() == "表示[表示する✓,ショートコードで表示,表示しない]")
        tree.display = .playsSlowly
        #expect(try describeDisplay() == "表示[表示する,遅く再生✓,ショートコードで表示,表示しない]")
    }
}

import Foundation
import Testing
@testable import SciaCore

@MainActor
struct ComposeCompletionTests {
    /// 問い合わせを記録し、語ごとに決めた応答を返す。`held`の語は、`release`するまで応答を返さない（取り消されても返さない）。
    actor Server {
        private(set) var queries: [String] = []
        private(set) var emojiRequests = 0
        var failingQueries: Set<String> = []
        var failsEmojis = false
        var failsOwnTags = false
        private(set) var ownTagRequests = 0
        private(set) var hashtagQueries: [String] = []
        private var held: Set<String> = []
        private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

        func hold(_ query: String) { held.insert(query) }

        func release(_ query: String) {
            held.remove(query)
            for continuation in waiting.removeValue(forKey: query) ?? [] {
                continuation.resume()
            }
        }

        func setFailing(_ queries: Set<String>) { failingQueries = queries }
        func setFailsEmojis(_ fails: Bool) { failsEmojis = fails }
        func setFailsOwnTags(_ fails: Bool) { failsOwnTags = fails }
        private var failingHashtags: Set<String> = []
        func setFailingHashtags(_ queries: Set<String>) { failingHashtags = queries }

        func hashtags(_ query: String) async throws -> [Hashtag] {
            hashtagQueries.append(query)
            if held.contains(query) {
                await withCheckedContinuation { waiting[query, default: []].append($0) }
            }
            if failingHashtags.contains(query) {
                throw MastodonAPIError.from(statusCode: 502, body: Data())
            }
            return [Hashtag(name: query), Hashtag(name: "\(query)写真"), Hashtag(name: "\(query)2")]
        }

        func featured() throws -> [FeaturedTag] {
            ownTagRequests += 1
            if failsOwnTags {
                throw URLError(.notConnectedToInternet)
            }
            return [FeaturedTag(name: "猫写真", statusesCount: 10), FeaturedTag(name: "今日の猫", statusesCount: 300)]
        }

        func recent() -> [Hashtag] {
            [Hashtag(name: "猫"), Hashtag(name: "猫写真"), Hashtag(name: "犬")]
        }

        func accounts(_ query: String, limit: Int) async throws -> [Account] {
            queries.append(query)
            if held.contains(query) {
                await withCheckedContinuation { waiting[query, default: []].append($0) }
            }
            if failingQueries.contains(query) {
                throw MastodonAPIError.from(statusCode: 502, body: Data())
            }
            return (1 ... 3).map { Account.stub(id: "\(query)-\($0)", acct: "\(query)\($0)") }
        }

        func emojis() throws -> [ServerEmoji] {
            emojiRequests += 1
            if failsEmojis {
                throw URLError(.notConnectedToInternet)
            }
            return [
                ServerEmoji.stub("blobcat_heart"),
                ServerEmoji.stub("blobcat"),
                ServerEmoji.stub("hidden_blobcat", visible: false),
                ServerEmoji.stub("ablob"),
                ServerEmoji.stub("taiyaki"),
            ]
        }
    }

    private let server = Server()

    private func makeCompletion(limit: Int = 5) -> ComposeCompletion {
        let server = server
        return ComposeCompletion(
            sources: ComposeCompletion.Sources(
                searchAccounts: { try await server.accounts($0, limit: $1) },
                searchHashtags: { query, _ in try await server.hashtags(query) },
                customEmojis: { try await server.emojis() },
                featuredTags: { try await server.featured() },
                recentTags: { await server.recent() }
            ),
            settings: ComposeCompletion.Settings(debounce: .milliseconds(30), limit: limit)
        )
    }

    private func mention(_ query: String, at start: Int = 0) -> CompletionToken {
        CompletionToken(kind: .mention, range: start ..< start + 1 + query.utf16.count, query: query, needsLeadingSpace: false)
    }

    private func emoji(_ query: String) -> CompletionToken {
        CompletionToken(kind: .emoji, range: 0 ..< 1 + query.utf16.count, query: query, needsLeadingSpace: false)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("待っている状態になりませんでした")
    }

    private func accts(_ content: ComposeCompletion.Content?) -> [String] {
        guard case .candidates(let candidates) = content else { return [] }
        return candidates.map(\.completion)
    }

    /// 続けて打った間は問い合わせず、止まってから最後の語だけを問い合わせる。
    @Test func debouncesWhileTyping() async throws {
        let completion = makeCompletion()
        for query in ["b", "bo", "bob"] {
            completion.textDidChange(mention(query))
        }
        #expect(completion.content == .loading)
        try await waitUntil { !completion.isLoading }
        #expect(await server.queries == ["bob"])
        #expect(accts(completion.content) == ["@bob1", "@bob2", "@bob3"])
    }

    /// 語が変わる前に始まった問い合わせの応答は、遅れて届いても出さない。
    @Test func discardsStaleResponse() async throws {
        let completion = makeCompletion()
        await server.hold("bo")
        completion.textDidChange(mention("bo"))
        try await waitUntil { await server.queries == ["bo"] }
        completion.textDidChange(mention("bob"))
        try await waitUntil { !completion.isLoading }
        await server.release("bo")
        try await Task.sleep(for: .milliseconds(50))
        #expect(accts(completion.content) == ["@bob1", "@bob2", "@bob3"])
    }

    /// 前の語の候補は、新しい語の応答が届くまで出したままにする。種類が変われば消す。
    @Test func keepsPreviousCandidatesWhileLoading() async throws {
        let completion = makeCompletion()
        completion.textDidChange(mention("bo"))
        try await waitUntil { !completion.isLoading }
        completion.textDidChange(mention("bob"))
        #expect(completion.isLoading)
        #expect(accts(completion.content) == ["@bo1", "@bo2", "@bo3"])
        completion.textDidChange(CompletionToken(kind: .hashtag, range: 0 ..< 3, query: "ca", needsLeadingSpace: false))
        #expect(completion.content == .loading)
    }

    /// 一度引いた語は覚えておき、消して打ち直したときは問い合わせない。
    @Test func cachesResults() async throws {
        let completion = makeCompletion()
        completion.textDidChange(mention("bob"))
        try await waitUntil { !completion.isLoading }
        completion.textDidChange(mention("bo"))
        try await waitUntil { !completion.isLoading }
        completion.textDidChange(mention("Bob"))
        #expect(!completion.isLoading)
        #expect(accts(completion.content) == ["@bob1", "@bob2", "@bob3"])
        #expect(await server.queries == ["bob", "bo"])
    }

    /// 失敗は候補の場所に出し、再試行で問い合わせ直す。
    @Test func showsFailureAndRetries() async throws {
        let completion = makeCompletion()
        await server.setFailing(["bob"])
        completion.textDidChange(mention("bob"))
        try await waitUntil { !completion.isLoading }
        guard case .failed = completion.content else {
            Issue.record("失敗を出していません: \(String(describing: completion.content))")
            return
        }
        await server.setFailing([])
        completion.retry()
        #expect(completion.content == .loading)
        try await waitUntil { !completion.isLoading }
        #expect(accts(completion.content).count == 3)
        #expect(await server.queries == ["bob", "bob"])
    }

    /// 絵文字は一覧を一度だけ取り、手元で絞る。一覧に出さない絵文字は除く。
    @Test func filtersEmojisLocally() async throws {
        let completion = makeCompletion()
        completion.prefetch()
        try await waitUntil { await server.emojiRequests == 1 }
        try await Task.sleep(for: .milliseconds(20))
        completion.textDidChange(emoji("blob"))
        #expect(accts(completion.content) == [":blobcat:", ":blobcat_heart:", ":ablob:"])
        completion.textDidChange(emoji("taiy"))
        #expect(accts(completion.content) == [":taiyaki:"])
        // 0文字なら、短い順に並べる。
        completion.textDidChange(emoji(""))
        #expect(accts(completion.content) == [":ablob:", ":blobcat:", ":taiyaki:", ":blobcat_heart:"])
        completion.textDidChange(emoji("zz"))
        #expect(completion.content == .empty)
        #expect(await server.emojiRequests == 1)
    }

    /// 一覧を読む前に打ったら、読み終えたところで出す。読めなければ失敗を出し、再試行で読み直す。
    @Test func loadsEmojisOnDemandAndRetries() async throws {
        let completion = makeCompletion()
        await server.setFailsEmojis(true)
        completion.textDidChange(emoji("blob"))
        #expect(completion.content == .loading)
        try await waitUntil { !completion.isLoading }
        guard case .failed = completion.content else {
            Issue.record("失敗を出していません")
            return
        }
        await server.setFailsEmojis(false)
        completion.retry()
        try await waitUntil { !completion.isLoading }
        #expect(accts(completion.content).first == ":blobcat:")
    }

    /// Escで閉じたら、語の位置がずれても出さない。語が変われば出し直す。
    @Test func dismissHidesUntilQueryChanges() async throws {
        let completion = makeCompletion()
        completion.textDidChange(mention("bob"))
        completion.dismiss()
        #expect(completion.content == nil)
        completion.textDidChange(mention("bob", at: 4))
        #expect(completion.content == nil)
        completion.textDidChange(mention("bobb", at: 4))
        #expect(completion.content != nil)
    }

    /// カーソルが語の外へ出たら閉じる。同じ語の中で動いても閉じない。
    @Test func selectionOutsideTokenCloses() {
        let completion = makeCompletion()
        completion.textDidChange(mention("bob"))
        completion.selectionDidChange(mention("bob"))
        #expect(completion.content != nil)
        completion.selectionDidChange(nil)
        #expect(completion.content == nil)
        #expect(completion.token == nil)
    }

    /// UIKitは打った文字を入れると、本文が変わった知らせより先にカーソルが動いた知らせを送る。その順でも新しい語を問い合わせる。
    @Test func selectionBeforeTextChangeStillLoads() async throws {
        let completion = makeCompletion()
        completion.textDidChange(mention("bo"))
        completion.selectionDidChange(mention("bob"))
        completion.textDidChange(mention("bob"))
        try await waitUntil { !completion.isLoading }
        #expect(await server.queries == ["bob"])
    }

    /// ↑↓で選ぶ候補を移し、端で止める。語が変われば先頭に戻す。
    @Test func movesSelection() async throws {
        let completion = makeCompletion()
        completion.textDidChange(mention("bob"))
        try await waitUntil { !completion.isLoading }
        completion.moveSelection(by: -1)
        #expect(completion.selectedIndex == 0)
        completion.moveSelection(by: 1)
        completion.moveSelection(by: 5)
        #expect(completion.selectedIndex == 2)
        #expect(completion.selectedCandidate?.completion == "@bob3")
        completion.textDidChange(mention("bo"))
        #expect(completion.selectedIndex == 0)
    }

    /// 止められている間は、補完では自動で読み込み直さないので、押せば読み込めると伝える。
    @Test func pausedMessageSaysTapToRetry() {
        let message = ComposeCompletion.failureMessage(for: AutomaticRequestsPaused(until: Date(timeIntervalSinceNow: 300)))
        #expect(message.contains("押すと読み込み直せます"))
        #expect(!message.contains("自動で"))
    }

    private func hashtag(_ query: String) -> CompletionToken {
        CompletionToken(kind: .hashtag, range: 0 ..< 1 + query.utf16.count, query: query, needsLeadingSpace: false)
    }

    /// 自分のタグは、先頭一致を部分一致より先に、同じ一致の中ではプロフィールのタグ（投稿の多い順）を最近使ったタグより先に並べる。
    @Test func ordersOwnHashtags() {
        let tags = OwnHashtag.list(
            featured: [FeaturedTag(name: "猫写真", statusesCount: 10), FeaturedTag(name: "今日の猫", statusesCount: 300), FeaturedTag(name: "猫鍋", statusesCount: 50)],
            recent: [Hashtag(name: "猫"), Hashtag(name: "猫写真"), Hashtag(name: "犬")]
        )
        #expect(OwnHashtag.matching("猫", in: tags).map(\.name) == ["猫鍋", "猫写真", "猫", "今日の猫"])
        #expect(OwnHashtag.matching("猫写真", in: tags).map(\.source) == [.featured(statusesCount: 10)])
        #expect(OwnHashtag.matching("NEKO", in: [OwnHashtag(name: "neko", source: .recent)]).count == 1)
    }

    /// 合う自分のタグは検索を待たずに出し、届いた検索結果をその後ろに、同じタグを除いて続ける。
    @Test func showsOwnHashtagsFirst() async throws {
        let completion = makeCompletion()
        completion.prefetch()
        try await waitUntil { await server.ownTagRequests == 1 }
        try await Task.sleep(for: .milliseconds(20))
        completion.textDidChange(hashtag("猫"))
        #expect(completion.isLoading)
        #expect(accts(completion.content) == ["#猫写真", "#猫", "#今日の猫"])
        try await waitUntil { !completion.isLoading }
        #expect(accts(completion.content) == ["#猫写真", "#猫", "#今日の猫", "#猫2"])
        guard case .candidates(let candidates) = completion.content, case .ownHashtag(let first) = candidates[0] else {
            Issue.record("自分のタグが先頭にありません")
            return
        }
        #expect(first.source == .featured(statusesCount: 10))
    }

    /// 検索の結果が届いたあとに自分のタグを読めたら、混ぜ直す。
    @Test func mergesOwnHashtagsLoadedLater() async throws {
        let completion = makeCompletion()
        completion.textDidChange(hashtag("犬"))
        try await waitUntil { !completion.isLoading }
        #expect(accts(completion.content) == ["#犬", "#犬写真", "#犬2"])
        completion.prefetch()
        try await waitUntil { await server.ownTagRequests == 1 }
        try await Task.sleep(for: .milliseconds(20))
        guard case .candidates(let candidates) = completion.content, case .ownHashtag = candidates[0] else {
            Issue.record("自分のタグを混ぜ直していません")
            return
        }
        #expect(accts(completion.content) == ["#犬", "#犬写真", "#犬2"])
    }

    /// 自分のタグを読めなくても知らせず、検索の結果だけを出す。次に書き始めたときに読み直す。
    @Test func ownHashtagFailureIsSilent() async throws {
        let completion = makeCompletion()
        await server.setFailsOwnTags(true)
        completion.prefetch()
        try await waitUntil { await server.ownTagRequests == 1 }
        try await Task.sleep(for: .milliseconds(20))
        completion.textDidChange(hashtag("猫"))
        try await waitUntil { !completion.isLoading }
        #expect(accts(completion.content) == ["#猫", "#猫写真", "#猫2"])
        await server.setFailsOwnTags(false)
        completion.prefetch()
        try await waitUntil { await server.ownTagRequests == 2 }
    }

    /// 前の語の候補で下を選んでいる間に、少ない自分のタグが届いても、選んでいる位置を候補の中に収める。
    @Test func clampsSelectionWhenOwnHashtagsArrive() async throws {
        let completion = makeCompletion()
        completion.textDidChange(hashtag("犬"))
        try await waitUntil { !completion.isLoading }
        await server.hold("今日")
        completion.textDidChange(hashtag("今日"))
        completion.moveSelection(by: 2)
        #expect(completion.selectedIndex == 2)
        completion.prefetch()
        try await waitUntil { await server.ownTagRequests == 1 }
        try await Task.sleep(for: .milliseconds(5))
        #expect(completion.selectedCandidate != nil)
        await server.release("今日")
    }

    /// サーバーが同じタグとして扱う表記（アクセント、全角、大文字）は、自分のタグの方だけを残す。
    @Test func deduplicatesByServerNormalization() {
        #expect(Hashtag.normalizedName("Café") == Hashtag.normalizedName("cafe"))
        #expect(Hashtag.normalizedName("ＮＥＫＯ") == "neko")
        #expect(Hashtag.normalizedName("ガ") != Hashtag.normalizedName("カ"))
        #expect(CompletionCandidate.ownHashtag(OwnHashtag(name: "café", source: .recent)).id == CompletionCandidate.hashtag(Hashtag(name: "cafe")).id)
        #expect(OwnHashtag.matching("cafe", in: [OwnHashtag(name: "Café", source: .recent)]).count == 1)
    }

    /// 検索が失敗しても、合う自分のタグは選べるまま残し、その下に失敗を出す。
    @Test func searchFailureKeepsOwnHashtags() async throws {
        let completion = makeCompletion()
        completion.prefetch()
        try await waitUntil { await server.ownTagRequests == 1 }
        try await Task.sleep(for: .milliseconds(20))
        await server.setFailingHashtags(["猫"])
        completion.textDidChange(hashtag("猫"))
        try await waitUntil { !completion.isLoading }
        guard case .candidatesWithFailure(let candidates, _) = completion.content else {
            Issue.record("自分のタグと失敗を出していません: \(String(describing: completion.content))")
            return
        }
        #expect(candidates.map(\.completion) == ["#猫写真", "#猫", "#今日の猫"])
        #expect(completion.selectedCandidate?.completion == "#猫写真")
    }

    /// メンションには自分のタグを混ぜない。
    @Test func ownHashtagsOnlyForHashtags() async throws {
        let completion = makeCompletion()
        completion.prefetch()
        try await waitUntil { await server.ownTagRequests == 1 }
        try await Task.sleep(for: .milliseconds(20))
        completion.textDidChange(mention("猫"))
        try await waitUntil { !completion.isLoading }
        #expect(accts(completion.content) == ["@猫1", "@猫2", "@猫3"])
    }

    @Test func didCompleteCloses() async throws {
        let completion = makeCompletion()
        completion.textDidChange(mention("bob"))
        completion.didComplete()
        #expect(completion.content == nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await server.queries.isEmpty)
    }
}

private extension Account {
    static func stub(id: String, acct: String) -> Account {
        Account(id: id, username: acct, acct: acct, displayName: acct, avatar: nil)
    }
}

private extension ServerEmoji {
    static func stub(_ shortcode: String, visible: Bool = true) -> ServerEmoji {
        let url = URL(filePath: "/emoji/\(shortcode).png")
        return ServerEmoji(shortcode: shortcode, url: url, staticUrl: url, visibleInPicker: visible)
    }
}

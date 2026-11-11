import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 本文とTranslationフレームワークのあいだの変換。決まりはdocs/auto-translation.mdの「本文の扱い」にある。
struct RichTextTranslationPlanTests {
    private let url = URL(string: "https://example.com/a")!  // swiftlint:disable:this force_unwrapping
    private let emoji = CustomEmoji(shortcode: "blob", url: URL(string: "https://example.com/e.png")!, staticUrl: URL(string: "https://example.com/e.png")!)  // swiftlint:disable:this force_unwrapping

    private func block(_ inlines: RichText.Inline...) -> RichText.Block {
        RichText.Block(inlines: inlines)
    }

    /// リンクと絵文字とインラインのコードは訳さない部分にし、改行は文字として渡す。
    @Test func splitsTextAndPreservedParts() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [
            block(.text("See ", []), .link("example.com", .url(url), []), .text(" and ", []), .emoji(emoji), .lineBreak, .text("run ", []), .text("make", .code)),
        ])))

        #expect(plan.paragraphs == [[
            .text("See "), .preserved("example.com", id: 0), .text(" and "), .preserved(":blob:", id: 1), .text("\nrun "), .preserved("make", id: 2),
        ]])
    }

    /// 語順が変わっても、残す部分は元のインラインに戻る。境目の空白は訳文の側に残す。
    @Test func restoresPreservedPartsInTranslatedOrder() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("See ", []), .link("example.com", .url(url), [.bold]))])))

        let result = try plan.applying([[.preserved("example.com ", id: 0), .text("を見て")]])

        #expect(result.blocks[0].inlines == [.link("example.com", .url(url), [.bold, .original]), .text(" を見て", [])])
    }

    /// 続けて返った改行は、1つの改行に戻す。
    @Test func collapsesRepeatedNewlines() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("One", []), .lineBreak, .text("Two", []))])))

        let result = try plan.applying([[.text("一\n\n二\n")]])

        #expect(result.blocks[0].inlines == [.text("一", []), .lineBreak, .text("二", [])])
    }

    /// コードブロックと文字のない段落は渡さず、原文の部分として残す。引用とリストの形も保つ。
    @Test func keepsCodeBlocksAndBlockShape() throws {
        let code = RichText.Block(inlines: [.text("let a", [])], isCode: true)
        let emojiOnly = block(.emoji(emoji))
        let quote = RichText.Block(inlines: [.text("Hello", [])], quoteLevel: 1, listMarker: "• ", listLevel: 1)
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [code, emojiOnly, quote])))

        let result = try plan.applying([[.text("こんにちは")]])

        #expect(result.blocks[0] == RichText.Block(inlines: [.text("let a", .original)], isCode: true))
        #expect(result.blocks[1] == emojiOnly)
        #expect(result.blocks[2] == RichText.Block(inlines: [.text("こんにちは", [])], quoteLevel: 1, listMarker: "• ", listLevel: 1))
    }

    /// 残したインラインのコードの書式は、後ろの訳文に移らない。
    @Test func keepsInlineCodeSeparateFromFollowingText() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("make", .code), .text(" now", []))])))

        let result = try plan.applying([[.preserved("make", id: 0), .text("今すぐ")]])

        #expect(result.blocks[0].inlines == [.text("make", [.code, .original]), .text("今すぐ", [])])
    }

    /// 残す部分にもともとある空白は、Translationフレームワークがそのまま返しても増やさない。Translationフレームワークが足した分だけ受け取る。
    @Test func doesNotDoubleOriginalWhitespace() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("Run", []), .text(" x ", .code), .text("now", []))])))

        let unchanged = try plan.applying([[.text("Run"), .preserved(" x ", id: 0), .text("now")]])
        let added = try plan.applying([[.text("Run"), .preserved("  x  ", id: 0), .text("now")]])

        #expect(unchanged.plainText == "Run x now")
        #expect(added.plainText == "Run  x  now")
    }

    @Test func hasNoPlanWithoutWords() {
        #expect(RichTextTranslationPlan(RichText(blocks: [block(.emoji(emoji), .text(" !!", []))])) == nil)
    }

    /// ハッシュタグは残す部分として渡し、名前を出てくる順に1回ずつ挙げる。
    @Test func listsHashtagsOnce() throws {
        let tag = RichText.Inline.link("#hiking", .hashtag(name: "hiking", url: url), [])
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("Went ", []), tag), block(tag, .text(" ", []), .link("#Cats", .hashtag(name: "Cats", url: url), []))])))

        #expect(plan.paragraphs == [[.text("Went "), .preserved("#hiking", id: 0)]])
        #expect(plan.hashtags == ["hiking", "Cats"])
    }

    /// 併記する訳は、訳した段落のハッシュタグにも、渡さなかった段落のハッシュタグにも、同じ開く先の別のインラインで足す。ハッシュタグは原文の部分、訳は訳文にする。
    @Test func appendsHashtagSuffixes() throws {
        let tag = RichText.Inline.link("#hiking", .hashtag(name: "hiking", url: url), [])
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("Went ", []), tag), block(tag)])))

        let result = try plan.applying([[.preserved("#hiking", id: 0), .text("に行った")]], hashtagSuffixes: ["hiking": "（ハイキング）"])

        let glossed: [RichText.Inline] = [.link("#hiking", .hashtag(name: "hiking", url: url), .original), .link("（ハイキング）", .hashtag(name: "hiking", url: url), [])]
        #expect(result.blocks.map(\.inlines) == [glossed + [.text("に行った", [])], glossed])
    }

    /// 書式で分かれた1つのハッシュタグには、最後にだけ足す。
    @Test func appendsSuffixOnceToSplitHashtag() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [
            block(.link("#", .hashtag(name: "hiking", url: url), []), .link("hiking", .hashtag(name: "hiking", url: url), [.bold])),
        ])))

        let result = try plan.applying([], hashtagSuffixes: ["hiking": " (x)"])

        #expect(result.plainText == "#hiking (x)")
    }

    /// インラインのコードの中のハッシュタグは、訳す対象に挙げず、併記もしない。
    @Test func leavesHashtagInInlineCode() throws {
        let code = RichText.Inline.link("#hiking", .hashtag(name: "hiking", url: url), [.code])
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("Run ", []), code)])))

        let result = try plan.applying([[.text("実行 "), .preserved("#hiking", id: 0)]], hashtagSuffixes: ["hiking": "（ハイキング）"])

        #expect(plan.hashtags.isEmpty)
        #expect(result.blocks[0].inlines == [.text("実行 ", []), .link("#hiking", .hashtag(name: "hiking", url: url), [.code, .original])])
    }

    @Test(arguments: [
        ("CatsOfMastodon", "Cats Of Mastodon"), ("hiking", "hiking"), ("HTMLParser", "HTML Parser"), ("snake_case_tag", "snake case tag"), ("Web3Summit", "Web3 Summit"),
    ])
    func splitsHashtagIntoWords(name: String, words: String) {
        #expect(HashtagGloss.words(of: name) == words)
    }

    @Test func hasNoWordsWithoutLetters() {
        #expect(HashtagGloss.words(of: "2024") == nil)
    }

    /// 訳が元の名前と同じ文字なら併記しない。大文字と小文字、空白の違いは見ない。
    @Test(arguments: [("Fedi Art", "FediArt", String?.none), ("Photography", "photography", nil), ("  ", "x", nil), (" ハイキング\n", "hiking", "ハイキング")])
    func glossesOnlyWhenTranslationDiffers(translated: String, name: String, gloss: String?) {
        #expect(HashtagGloss.gloss(translated: translated, name: name) == gloss)
    }

    @Test(arguments: [("ja", "（猫）"), ("zh-TW", "（猫）"), ("en", " (猫)"), ("ko", " (猫)")])
    func wrapsGlossForTarget(target: String, suffix: String) {
        #expect(HashtagGloss.suffix("猫", target: target) == suffix)
    }

    /// 残す部分が欠けたら、訳文を使わない。
    @Test func rejectsLostPreservedPart() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("See ", []), .link("example.com", .url(url), []))])))

        #expect(throws: StatusTranslationError.preservedPartsChanged) {
            try plan.applying([[.text("見て")]])
        }
    }
}

@MainActor
struct StatusTranslationStoreTests {
    /// 頼まれた段落を覚えて、先頭に「訳:」を付けて返す。`gate`が閉じている間は止まる。
    private final class FakeTranslator: StatusTranslating {
        let requests = Mutex<[String]>([])
        let notInstalledLanguages: Mutex<Set<String>>
        let attemptCount = Mutex(0)
        let targetRequests = Mutex<[String]>([])
        let strategyRequests = Mutex<[TranslationStrategy]>([])
        let gate: Gate
        let failureGate: Gate
        /// 訳すと失敗する段落の文字。
        let failingTexts: Set<String>

        struct Failure: Error {}

        init(notInstalledLanguages: Set<String> = [], failingTexts: Set<String> = [], gate: Gate = Gate(isOpen: true), failureGate: Gate = Gate(isOpen: true)) {
            self.failingTexts = failingTexts
            self.notInstalledLanguages = Mutex(notInstalledLanguages)
            self.gate = gate
            self.failureGate = failureGate
        }

        func translate(_ parts: [TranslationPart], from source: String, to target: String, strategy: TranslationStrategy) async throws -> [TranslationPart] {
            attemptCount.withLock { $0 += 1 }
            guard !notInstalledLanguages.withLock({ $0.contains(source) }) else {
                try await failureGate.wait()
                throw StatusTranslationError.notInstalled
            }
            requests.withLock { $0.append(Self.text(of: parts)) }
            targetRequests.withLock { $0.append(target) }
            strategyRequests.withLock { $0.append(strategy) }
            try await gate.wait()
            guard !failingTexts.contains(Self.text(of: parts)) else { throw Failure() }
            return parts.map { part in
                if case .text(let text) = part { .text("訳:" + text) } else { part }
            }
        }

        private static func text(of parts: [TranslationPart]) -> String {
            parts.map { part in
                switch part {
                case .text(let text): text
                case .preserved(let text, _): text
                }
            }.joined()
        }

        var requested: [String] { requests.withLock { $0 } }
        var attempts: Int { attemptCount.withLock { $0 } }
        var targets: [String] { targetRequests.withLock { $0 } }
        var strategies: [TranslationStrategy] { strategyRequests.withLock { $0 } }

        func install() {
            notInstalledLanguages.withLock { $0 = [] }
        }
    }

    private let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(_ id: String, language: String? = "en", content: String? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: content ?? "<p>post \(id)</p>", spoilerText: "", language: language, url: nil)
    }

    private func store(_ translator: FakeTranslator, clock: TestClock, scope: TaskScope, languages: [String] = ["en"]) -> StatusTranslationStore {
        let store = StatusTranslationStore(translator: translator, targetLanguage: "ja", strategy: .highFidelity, scope: scope, clock: clock, applyInterval: { .milliseconds(250) })
        store.setLanguages(languages)
        return store
    }

    private func waitForDelivery(of ids: Set<Status.ID>, clock: TestClock, delivered: @escaping () -> Set<Status.ID>) async throws {
        try await waitUntil {
            clock.advance(by: .milliseconds(250))
            return delivered().isSuperset(of: ids)
        }
    }

    /// 翻訳と、まとめて知らせる待ち時間が終わるまで待つ。
    private func waitUntilSettled(_ scope: TaskScope, clock: TestClock) async throws {
        try await waitUntil {
            clock.advance(by: .milliseconds(250))
            return scope.runningCount == 0
        }
    }

    @Test func translatesAndDeliversBody() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let store = store(FakeTranslator(), clock: clock, scope: scope)
        var delivered: Set<Status.ID> = []
        store.onChange = { delivered.formUnion($0) }
        let post = status("1")

        store.request([post])
        try await waitForDelivery(of: ["1"], clock: clock) { delivered }

        #expect(store.translation(for: post)?.plainText == "訳:post 1")
        #expect(store.hasTranslation(of: post))
    }

    /// ハッシュタグは語に分けて1つずつ訳し、後ろに併記する。同じハッシュタグは訳し直さない。
    @Test func glossesHashtags() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let translator = FakeTranslator()
        let store = store(translator, clock: clock, scope: scope)
        var delivered: Set<Status.ID> = []
        store.onChange = { delivered.formUnion($0) }
        let tag = #"<a href="https://example.social/tags/CatsOfMastodon" class="mention hashtag" rel="tag">#<span>CatsOfMastodon</span></a>"#
        let post = status("1", content: "<p>Look \(tag)</p>")
        let tagOnly = status("2", content: "<p>\(tag)</p>")

        store.request([post, tagOnly])
        try await waitForDelivery(of: ["1", "2"], clock: clock) { delivered }

        #expect(translator.requested == ["Look #CatsOfMastodon", "Cats Of Mastodon"])
        #expect(store.translation(for: post)?.plainText == "訳:Look #CatsOfMastodon（訳:Cats Of Mastodon）")
        #expect(store.translation(for: tagOnly)?.plainText == "#CatsOfMastodon（訳:Cats Of Mastodon）")
    }

    /// ハッシュタグの訳だけが失敗したら、本文の訳は使い、そのハッシュタグには併記しない。次に出たときに訳し直す。
    @Test func keepsBodyWhenHashtagGlossFails() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let translator = FakeTranslator(failingTexts: ["hiking"])
        let store = store(translator, clock: clock, scope: scope)
        var delivered: Set<Status.ID> = []
        store.onChange = { delivered.formUnion($0) }
        let tag = #"<a href="https://example.social/tags/hiking" class="mention hashtag" rel="tag">#<span>hiking</span></a>"#
        let post = status("1", content: "<p>Went \(tag)</p>")

        store.request([post, status("2", content: "<p>Again \(tag)</p>")])
        try await waitForDelivery(of: ["1", "2"], clock: clock) { delivered }

        #expect(store.translation(for: post)?.plainText == "訳:Went #hiking")
        #expect(translator.requested == ["Went #hiking", "hiking", "Again #hiking", "hiking"])
    }

    /// 地域の違う投稿も、言語が同じなら訳す。Translationフレームワークには投稿の言語をそのまま渡す。
    @Test func comparesByLanguageCode() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let store = store(FakeTranslator(), clock: clock, scope: scope, languages: ["en-GB"])
        var delivered: Set<Status.ID> = []
        store.onChange = { delivered.formUnion($0) }

        store.request([status("1", language: "en-GB")])
        try await waitForDelivery(of: ["1"], clock: clock) { delivered }
    }

    /// 選んでいない言語、言語のない投稿、端末の言語の投稿は訳さない。
    @Test(arguments: [String?.some("de"), nil, "ja"])
    func skipsOtherLanguages(language: String?) {
        let scope = TaskScope()
        let translator = FakeTranslator()
        let store = store(translator, clock: TestClock(), scope: scope, languages: ["en", "ja"])

        store.request([status("1", language: language)])

        #expect(scope.runningCount == 0)
        #expect(translator.requested.isEmpty)
    }

    /// 新しく頼むと、前に頼んでまだ訳していない投稿は取り下げる。訳している途中の投稿は最後まで訳す。
    @Test func replacesWaitingRequests() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let gate = Gate()
        let translator = FakeTranslator(gate: gate)
        let store = store(translator, clock: clock, scope: scope)
        var delivered: Set<Status.ID> = []
        store.onChange = { delivered.formUnion($0) }

        store.request([status("1"), status("2")])
        try await waitUntil { gate.waiterCount >= 1 }
        store.request([status("3")])
        gate.open()
        try await waitForDelivery(of: ["1", "3"], clock: clock) { delivered }

        #expect(translator.requested == ["post 1", "post 3"])
    }

    /// 続けて届いた訳文は、まとめて知らせる。
    @Test func deliversChangesTogether() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let translator = FakeTranslator()
        let store = store(translator, clock: clock, scope: scope)
        var deliveries: [Set<Status.ID>] = []
        store.onChange = { deliveries.append($0) }
        let posts = [status("1"), status("2")]

        store.request(posts)
        try await waitUntil { posts.allSatisfy(store.hasTranslation(of:)) }
        try await clock.advance(afterSleeping: .milliseconds(250))
        try await waitUntil { !deliveries.isEmpty }

        #expect(deliveries == [["1", "2"]])
    }

    /// 言語モデルがなければ、同じ言語の残りは試さない。ダウンロードが終わったあとに頼まれたら、訳す。
    @Test func retriesUninstalledLanguageOnNextRequest() async throws {
        let scope = TaskScope()
        let translator = FakeTranslator(notInstalledLanguages: ["en"])
        let clock = TestClock()
        let store = store(translator, clock: clock, scope: scope)

        store.request([status("1"), status("2")])
        try await waitUntilSettled(scope, clock: clock)
        #expect(translator.attempts == 1)

        translator.install()
        store.request([status("1")])
        try await waitUntil { store.hasTranslation(of: status("1")) }
    }

    /// 訳す言語は、地域と文字体系まで含めて比べる。`zh`と`zh-CN`は同じ言語として扱う。
    @Test(arguments: [("zh-TW", "zh"), ("zh", "zh-TW"), ("en", "en-GB")])
    func matchesLanguagesIncludingRegionAndScript(selected: String, other: String) async throws {
        let scope = TaskScope()
        let store = store(FakeTranslator(), clock: TestClock(), scope: scope, languages: [selected])
        let matching = status("1", language: selected)
        let different = status("2", language: other)
        store.request([different, matching])
        try await waitUntil { store.hasTranslation(of: matching) }

        #expect(!store.hasTranslation(of: different))
    }

    @Test func treatsDefaultRegionAsSameLanguage() async throws {
        let scope = TaskScope()
        let store = store(FakeTranslator(), clock: TestClock(), scope: scope, languages: ["zh"])
        let post = status("1", language: "zh-CN")
        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }
    }

    /// 本文を変えずに言語だけを直した投稿は、前の言語の訳文を使わずに訳し直す。
    @Test func retranslatesAfterLanguageOnlyEdit() async throws {
        let scope = TaskScope()
        let translator = FakeTranslator()
        let store = store(translator, clock: TestClock(), scope: scope, languages: ["en", "de"])
        let post = status("1", language: "en")
        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }

        let edited = status("1", language: "de")
        #expect(store.translation(for: edited) == nil)
        store.request([edited])
        try await waitUntil { store.hasTranslation(of: edited) }

        #expect(translator.attempts == 2)
    }

    /// 本文のない投稿は頼まない。訳せなかった投稿の記録も増やさない。
    @Test func doesNotRequestEmptyBody() {
        let scope = TaskScope()
        let translator = FakeTranslator()
        let store = store(translator, clock: TestClock(), scope: scope)

        store.request([status("1", content: "")])

        #expect(scope.runningCount == 0)
        #expect(translator.attempts == 0)
    }

    /// モデルが入る前に始めた翻訳の失敗が、モデルが入って頼み直したあとに届いても、頼み直しを消さない。
    @Test func retriesAfterInstallWhileOldFailureIsPending() async throws {
        let scope = TaskScope()
        let failureGate = Gate()
        let translator = FakeTranslator(notInstalledLanguages: ["en"], failureGate: failureGate)
        let store = store(translator, clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { failureGate.waiterCount >= 1 }

        translator.install()
        store.setLanguages(["en"])
        store.request([post])
        failureGate.open()

        try await waitUntil { store.hasTranslation(of: post) }
    }

    /// 訳せなかった投稿も、本文が編集されたら訳し直す。
    @Test func retriesSkippedStatusAfterEdit() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let store = store(FakeTranslator(), clock: clock, scope: scope)
        let codeOnly = status("1", content: "<pre><code>let a = 1</code></pre>")

        store.request([codeOnly])
        try await waitUntilSettled(scope, clock: clock)
        store.request([codeOnly])
        #expect(scope.runningCount == 0)

        let edited = status("1", content: "<p>Hello</p>")
        store.request([edited])
        try await waitUntil { store.hasTranslation(of: edited) }
    }

    /// 本文が編集されたら、前の訳文は使わずに訳し直す。
    @Test func retranslatesEditedStatus() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let translator = FakeTranslator()
        let store = store(translator, clock: clock, scope: scope)
        var delivered: [Set<Status.ID>] = []
        store.onChange = { delivered.append($0) }

        store.request([status("1")])
        try await waitUntil { store.hasTranslation(of: status("1")) }
        let edited = status("1", content: "<p>edited</p>")
        #expect(store.translation(for: edited) == nil)

        store.request([edited])
        try await waitUntil { store.translation(for: edited)?.plainText == "訳:edited" }
    }

    /// 原文に戻すと訳文を出さず、もう一度切り替えると出す。
    @Test func togglesOriginal() async throws {
        let scope = TaskScope()
        let store = store(FakeTranslator(), clock: TestClock(), scope: scope)
        var delivered: [Set<Status.ID>] = []
        store.onChange = { delivered.append($0) }
        let post = status("1")
        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }

        store.toggleOriginal(of: post)
        #expect(store.translation(for: post) == nil)
        #expect(store.hasTranslation(of: post))
        #expect(store.isShowingOriginal(post))

        store.toggleOriginal(of: post)
        #expect(store.translation(for: post) != nil)
        #expect(delivered == [["1"], ["1"]])
    }

    /// 訳文が届くまで待っている状態で、届いたら待っていない。
    @Test func isTranslatingUntilTranslationArrives() async throws {
        let scope = TaskScope()
        let gate = Gate()
        let store = store(FakeTranslator(gate: gate), clock: TestClock(), scope: scope)
        let post = status("1")
        #expect(store.isTranslating(post))

        store.request([post])
        try await waitUntil { gate.waiterCount >= 1 }
        #expect(store.isTranslating(post))

        gate.open()
        try await waitUntil { store.hasTranslation(of: post) }
        #expect(!store.isTranslating(post))
    }

    /// 選んでいない言語の投稿と本文のない投稿は、待っている状態にしない。
    @Test func isNotTranslatingWhenNothingToTranslate() {
        let store = store(FakeTranslator(), clock: TestClock(), scope: TaskScope())

        #expect(!store.isTranslating(status("1", language: "de")))
        #expect(!store.isTranslating(status("2", content: "")))
    }

    /// 言語モデルがないと分かったら、同じ言語の投稿を待っている状態から外して知らせる。入ったあとで訳せたら、その言語はまた待つ。
    @Test func stopsTranslatingWhenLanguageIsNotInstalled() async throws {
        let scope = TaskScope()
        let translator = FakeTranslator(notInstalledLanguages: ["en"])
        let clock = TestClock()
        let store = store(translator, clock: clock, scope: scope)
        var delivered: Set<Status.ID> = []
        store.onChange = { delivered.formUnion($0) }

        store.request([status("1"), status("2")])
        try await waitForDelivery(of: ["1", "2"], clock: clock) { delivered }

        #expect(delivered == ["1", "2"])
        #expect(!store.isTranslating(status("1")))

        translator.install()
        store.request([status("1")])
        try await waitUntil { store.hasTranslation(of: status("1")) }
        #expect(store.isTranslating(status("2")))
    }

    /// 訳せなかった投稿は、待っている状態から外して知らせる。
    @Test func stopsTranslatingSkippedStatus() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let store = store(FakeTranslator(), clock: clock, scope: scope)
        var delivered: Set<Status.ID> = []
        store.onChange = { delivered.formUnion($0) }
        let codeOnly = status("1", content: "<pre><code>let a = 1</code></pre>")

        store.request([codeOnly])
        try await waitForDelivery(of: ["1"], clock: clock) { delivered }

        #expect(delivered == ["1"])
        #expect(!store.isTranslating(codeOnly))
    }

    /// 翻訳先を変えると、持っている訳文を捨て、新しい翻訳先で訳し直す。
    @Test func retranslatesAfterChangingTarget() async throws {
        let scope = TaskScope()
        let translator = FakeTranslator()
        let store = store(translator, clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }

        store.setTargetLanguage("ko")
        #expect(store.translation(for: post) == nil)

        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }
        #expect(translator.targets == ["ja", "ko"])
    }

    /// 翻訳の方式を変えたら、持っている訳文を捨てて、新しい方式で訳し直す。
    @Test func retranslatesAfterChangingStrategy() async throws {
        let scope = TaskScope()
        let translator = FakeTranslator()
        let store = store(translator, clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }

        store.setStrategy(.lowLatency)
        #expect(store.translation(for: post) == nil)

        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }
        #expect(translator.strategies == [.highFidelity, .lowLatency])
    }

    /// 訳している途中で翻訳の方式を変えたら、変える前に始めた結果は持たない。
    @Test func dropsTranslationFinishedAfterChangingStrategy() async throws {
        let scope = TaskScope()
        let gate = Gate()
        let store = store(FakeTranslator(gate: gate), clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { gate.waiterCount >= 1 }

        store.setStrategy(.lowLatency)
        gate.open()
        try await waitUntil { scope.runningCount == 0 }

        #expect(!store.hasTranslation(of: post))
    }

    /// 同じ方式を入れ直しても、持っている訳文は捨てない。
    @Test func keepsTranslationWhenStrategyIsUnchanged() async throws {
        let scope = TaskScope()
        let store = store(FakeTranslator(), clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }

        store.setStrategy(.highFidelity)

        #expect(store.hasTranslation(of: post))
    }

    /// 翻訳先と同じ言語の投稿は訳さない。
    @Test func skipsTargetLanguage() {
        let scope = TaskScope()
        let translator = FakeTranslator()
        let store = store(translator, clock: TestClock(), scope: scope)

        store.setTargetLanguage("en-GB")
        store.request([status("1", language: "en")])

        #expect(scope.runningCount == 0)
        #expect(translator.requested.isEmpty)
    }

    /// 訳している途中で翻訳先を変えたら、前の翻訳先の訳文を持たない。
    @Test func dropsTranslationFinishedAfterChangingTarget() async throws {
        let scope = TaskScope()
        let gate = Gate()
        let store = store(FakeTranslator(gate: gate), clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { gate.waiterCount >= 1 }

        store.setTargetLanguage("ko")
        gate.open()
        try await waitUntil { scope.runningCount == 0 }

        #expect(!store.hasTranslation(of: post))
    }

    /// 訳している途中で翻訳先を変えて元に戻しても、変える前に始めた結果は持たない。
    @Test func dropsTranslationFinishedAfterRoundTripOfTarget() async throws {
        let scope = TaskScope()
        let gate = Gate()
        let store = store(FakeTranslator(gate: gate), clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { gate.waiterCount >= 1 }

        store.setTargetLanguage("ko")
        store.setTargetLanguage("ja")
        gate.open()
        try await waitUntil { scope.runningCount == 0 }

        #expect(!store.hasTranslation(of: post))
    }

    /// 言語を外すと、持っている訳文を出さない。
    @Test func hidesTranslationAfterRemovingLanguage() async throws {
        let scope = TaskScope()
        let store = store(FakeTranslator(), clock: TestClock(), scope: scope)
        let post = status("1")
        store.request([post])
        try await waitUntil { store.hasTranslation(of: post) }

        store.setLanguages([])

        #expect(store.translation(for: post) == nil)
    }
}

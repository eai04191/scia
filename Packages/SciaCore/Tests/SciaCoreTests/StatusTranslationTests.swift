import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 本文と翻訳器のあいだの変換。決まりはdocs/auto-translation.mdの「本文の扱い」にある。
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

        #expect(result.blocks[0].inlines == [.link("example.com", .url(url), [.bold]), .text(" を見て", [])])
    }

    /// 続けて返った改行は、1つの改行に戻す。
    @Test func collapsesRepeatedNewlines() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("One", []), .lineBreak, .text("Two", []))])))

        let result = try plan.applying([[.text("一\n\n二\n")]])

        #expect(result.blocks[0].inlines == [.text("一", []), .lineBreak, .text("二", [])])
    }

    /// コードブロックと文字のない段落は渡さず、そのまま残す。引用とリストの形も保つ。
    @Test func keepsCodeBlocksAndBlockShape() throws {
        let code = RichText.Block(inlines: [.text("let a", [])], isCode: true)
        let emojiOnly = block(.emoji(emoji))
        let quote = RichText.Block(inlines: [.text("Hello", [])], quoteLevel: 1, listMarker: "• ", listLevel: 1)
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [code, emojiOnly, quote])))

        let result = try plan.applying([[.text("こんにちは")]])

        #expect(result.blocks[0] == code)
        #expect(result.blocks[1] == emojiOnly)
        #expect(result.blocks[2] == RichText.Block(inlines: [.text("こんにちは", [])], quoteLevel: 1, listMarker: "• ", listLevel: 1))
    }

    /// 残したインラインのコードの書式は、後ろの訳文に移らない。
    @Test func keepsInlineCodeSeparateFromFollowingText() throws {
        let plan = try #require(RichTextTranslationPlan(RichText(blocks: [block(.text("make", .code), .text(" now", []))])))

        let result = try plan.applying([[.preserved("make", id: 0), .text("今すぐ")]])

        #expect(result.blocks[0].inlines == [.text("make", .code), .text("今すぐ", [])])
    }

    /// 残す部分にもともとある空白は、翻訳器がそのまま返しても増やさない。翻訳器が足した分だけ受け取る。
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
        let gate: Gate

        init(notInstalledLanguages: Set<String> = [], gate: Gate = Gate(isOpen: true)) {
            self.notInstalledLanguages = Mutex(notInstalledLanguages)
            self.gate = gate
        }

        func translate(_ parts: [TranslationPart], from source: String, to target: String) async throws -> [TranslationPart] {
            attemptCount.withLock { $0 += 1 }
            guard !notInstalledLanguages.withLock({ $0.contains(source) }) else { throw StatusTranslationError.notInstalled }
            requests.withLock { $0.append(Self.text(of: parts)) }
            targetRequests.withLock { $0.append(target) }
            try await gate.wait()
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

        func install() {
            notInstalledLanguages.withLock { $0 = [] }
        }
    }

    private let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(_ id: String, language: String? = "en", content: String? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: content ?? "<p>post \(id)</p>", spoilerText: "", language: language, url: nil)
    }

    private func store(_ translator: FakeTranslator, clock: TestClock, scope: TaskScope, languages: [String] = ["en"]) -> StatusTranslationStore {
        let store = StatusTranslationStore(translator: translator, targetLanguage: "ja", scope: scope, clock: clock, applyInterval: { .milliseconds(250) })
        store.setLanguages(languages)
        return store
    }

    private func waitForDelivery(of ids: Set<Status.ID>, clock: TestClock, delivered: @escaping () -> Set<Status.ID>) async throws {
        try await waitUntil {
            clock.advance(by: .milliseconds(250))
            return delivered().isSuperset(of: ids)
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

    /// 地域の違う投稿も、言語が同じなら訳す。翻訳器には投稿の言語をそのまま渡す。
    @Test func comparesByLanguageCode() async throws {
        let scope = TaskScope()
        let clock = TestClock()
        let store = store(FakeTranslator(), clock: clock, scope: scope)
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
        let store = store(translator, clock: TestClock(), scope: scope)

        store.request([status("1"), status("2")])
        try await waitUntil { scope.runningCount == 0 }
        #expect(translator.attempts == 1)

        translator.install()
        store.request([status("1")])
        try await waitUntil { store.hasTranslation(of: status("1")) }
    }

    /// 訳せなかった投稿も、本文が編集されたら訳し直す。
    @Test func retriesSkippedStatusAfterEdit() async throws {
        let scope = TaskScope()
        let store = store(FakeTranslator(), clock: TestClock(), scope: scope)
        let codeOnly = status("1", content: "<pre><code>let a = 1</code></pre>")

        store.request([codeOnly])
        try await waitUntil { scope.runningCount == 0 }
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

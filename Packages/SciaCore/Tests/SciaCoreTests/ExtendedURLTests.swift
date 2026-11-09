@testable import SciaCore
import SciaTesting
import Testing

/// ペーストか共有で入れたURLの後ろに続いた文字を見つける。決まりはdocs/compose.mdの「URLの後ろに続いた文字」にある。
@MainActor
struct ExtendedURLTests {
    private func makeModel() -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", post: { _ in })
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        return model
    }

    /// 入れたURLの後ろに空白なしで書いた日本語は、続いた文字として見つけ、その前に改行を入れられる。
    @Test func findsTextWrittenRightAfterInsertedURL() {
        let text = "見て https://example.com/a/bこれ良い"
        let found = ExtendedURL.find(in: text, inserted: ["https://example.com/a/b"])

        #expect(found == [ExtendedURL(insertedURL: "https://example.com/a/b", continuation: "これ良い", offset: 26)])
        #expect(ExtendedURL.separating(found, in: text) == "見て https://example.com/a/b\nこれ良い")
    }

    /// 入れたURLとまったく同じURL、空白で区切ったURL、入れていないURLは見つけない。
    @Test(arguments: [
        "https://example.com/a",
        "https://example.com/a これ良い",
        "https://example.com/a\nこれ良い",
        "https://other.example/aこれ良い",
    ])
    func ignoresURLsNotExtended(text: String) {
        #expect(ExtendedURL.find(in: text, inserted: ["https://example.com/a"]).isEmpty)
    }

    /// 括弧で囲んだURLは、Mastodon（UTS #58）と同じく、対になる開き括弧のない閉じ括弧で終わるので、後ろの文は続いた文字にしない。
    @Test(arguments: ["「https://example.com/a」これ良い", "(https://example.com/a)これ良い", "【https://example.com/a】これ良い"])
    func closingBracketEndsURL(text: String) {
        #expect(ExtendedURL.find(in: text, inserted: ["https://example.com/a"]).isEmpty)
    }

    /// 括弧ごとペーストしたURLも、括弧を外したURLで覚える。括弧を消してURLの後ろに書き足せば見つける。
    @Test func bracketedPasteRemembersURLWithoutBracket() {
        let model = makeModel()
        model.noteInsertedText("「https://example.com/a」")
        model.text = "https://example.com/aこれ良い"

        #expect(model.extendedURLs.map(\.continuation) == ["これ良い"])
    }

    /// 閉じ括弧で切った後ろに空白なしで続くURLも、別のURLとして見つける。
    @Test func findsURLAfterClosingBracket() {
        let text = "「https://example.com/a」「https://example.org/bこれ」"
        let found = ExtendedURL.find(in: text, inserted: ["https://example.com/a", "https://example.org/b"])

        #expect(found.map(\.continuation) == ["これ"])
    }

    /// URLの中で対になる括弧は、URLに含める。
    @Test func pairedBracketsStayInURL() {
        let text = "https://ja.wikipedia.org/wiki/A_(B)これ"
        let found = ExtendedURL.find(in: text, inserted: ["https://ja.wikipedia.org/wiki/A_(B)"])

        #expect(found.map(\.continuation) == ["これ"])
    }

    /// 下書きを空に戻す前にペーストを読み始めていたら、読み終えても前の下書きのURLとして覚えない。
    @Test func staleInsertedTextIsIgnoredAfterReset() {
        let model = makeModel()
        let token = model.insertedTextToken
        model.reset()
        model.noteInsertedText("https://example.com/a", token: token)
        model.text = "https://example.com/aこれ"

        #expect(model.extendedURLs.isEmpty)
    }

    /// 続いた文字ごとコピーしたURLは、そのまま覚えるので見つけない。
    @Test func ignoresURLCopiedWithContinuation() {
        let model = makeModel()
        model.noteInsertedText("https://ja.wikipedia.org/wiki/日本")
        model.text = "https://ja.wikipedia.org/wiki/日本"

        #expect(model.extendedURLs.isEmpty)
    }

    /// 始まりの合う入れたURLが複数あれば、いちばん長いものの後ろを続いた文字にする。
    @Test func usesLongestInsertedPrefix() {
        let found = ExtendedURL.find(in: "https://example.com/a/bこれ", inserted: ["https://example.com/a", "https://example.com/a/b"])

        #expect(found.map(\.continuation) == ["これ"])
    }

    /// 2つのURLの後ろに続いていれば、両方に改行を入れる。
    @Test func separatesEveryExtendedURL() {
        let model = makeModel()
        model.noteInsertedText("https://a.example/x と https://b.example/y")
        model.text = "https://a.example/xあ\nhttps://b.example/yい"

        model.separateExtendedURLs()

        #expect(model.text == "https://a.example/x\nあ\nhttps://b.example/y\nい")
        #expect(model.extendedURLs.isEmpty)
    }

    /// 下書きを空に戻すと、入れたURLを忘れる。
    @Test func resetForgetsInsertedURLs() {
        let model = makeModel()
        model.noteInsertedText("https://example.com/a")
        model.reset()
        model.text = "https://example.com/aこれ"

        #expect(model.extendedURLs.isEmpty)
    }

    /// シートの題でリンクに入る文字を示し、URLは本文に書いたまま並べる。予約なら「予約」と書く。
    @Test func promptShowsContinuation() throws {
        let prompt = try #require(ExtendedURLPrompt(
            [ExtendedURL(insertedURL: "https://example.com/a/b", continuation: "これ良い", offset: 23)],
            scheduling: true
        ))

        #expect(prompt.title == "“これ良い”もリンクになります")
        #expect(prompt.lines.map(\.url) == ["https://example.com/a/b"])
        #expect(prompt.lines.map(\.continuation) == ["これ良い"])
        #expect([prompt.separateTitle, prompt.postAsIsTitle] == ["改行を入れて予約", "そのまま予約"])
        #expect(ExtendedURLPrompt([], scheduling: false) == nil)
    }

    /// 長いURLと長い文も「…」で縮めない。文が長ければ、題には挙げず、見本には枠の幅を超えるだけの長さを渡す。
    @Test func promptDoesNotShortenWithEllipsis() throws {
        let url = "https://example.com/" + String(repeating: "x", count: 60) + "/end"
        let prompt = try #require(ExtendedURLPrompt(
            [ExtendedURL(insertedURL: url, continuation: String(repeating: "あ", count: 200), offset: url.utf16.count)],
            scheduling: false
        ))

        #expect(prompt.title == "URLの後ろの文字もリンクになります")
        #expect(prompt.lines[0].url == url)
        #expect(prompt.lines[0].continuation == String(repeating: "あ", count: 120))
    }

    /// 題に挙げられる長さの文なら、そのまま挙げる。
    @Test func promptQuotesContinuationUpToLimit() throws {
        let continuation = String(repeating: "あ", count: 20)
        let prompt = try #require(ExtendedURLPrompt([ExtendedURL(insertedURL: "https://example.com", continuation: continuation, offset: 19)], scheduling: false))

        #expect(prompt.title == "“\(continuation)”もリンクになります")
    }

    /// 2つ以上なら、題では文字を挙げず、すべての行を並べる。
    @Test func promptListsEveryURL() throws {
        let prompt = try #require(ExtendedURLPrompt([
            ExtendedURL(insertedURL: "https://a.example/x", continuation: "あ", offset: 19),
            ExtendedURL(insertedURL: "http://b.example/y", continuation: "い", offset: 40),
        ], scheduling: false))

        #expect(prompt.title == "URLの後ろの文字もリンクになります")
        #expect(prompt.lines.map(\.continuation) == ["あ", "い"])
    }
}

import Foundation
import SciaTesting
import Testing
@testable import SciaCore

struct PageTitleTests {
    private func title(_ html: String, contentType: String? = "text/html; charset=utf-8") -> String? {
        PageTitle.title(in: Data(html.utf8), contentType: contentType)
    }

    /// YouTubeの`<title>`は「- YouTube」が付き、ページの初めには中身のない`<title>YouTube</title>`もあるため、og:titleを先に使う。
    @Test func prefersOGTitleOverTitleElement() {
        let html = #"<html><head><title>YouTube</title></head><body><meta property="og:title" content="Me at the zoo"><title>Me at the zoo - YouTube</title></body></html>"#
        #expect(title(html) == "Me at the zoo")
    }

    @Test func readsOGTitleWithAttributesInAnyOrder() {
        #expect(title(#"<meta content='題' name="og:title" />"#) == "題")
        #expect(title(#"<META PROPERTY="OG:TITLE" CONTENT="大文字">"#) == "大文字")
    }

    @Test func fallsBackToFirstTitleElement() {
        #expect(title(#"<head><title data-server="1">ページの題</title></head><body><title>別の題</title></body>"#) == "ページの題")
    }

    @Test func decodesCharacterReferences() {
        #expect(title(#"<meta property="og:title" content="A &amp; B &quot;C&quot; &#x1F600;">"#) == "A & B \"C\" 😀")
    }

    @Test func readsGreaterThanInsideQuotedAttribute() {
        #expect(title(#"<meta property="og:title" content="A > B"><title>代わり</title>"#) == "A > B")
    }

    @Test func readsLessThanInsideTitleElement() {
        #expect(title("<title>1 < 2</title>") == "1 < 2")
    }

    /// ページのタイトルには、Mastodonの本文には出ない名前付きの文字参照がよく使われる。
    @Test func decodesCommonNamedReferences() {
        #expect(title("<title>A &ndash; B &hellip; &copy; &rsquo;</title>") == "A – B … © ’")
    }

    @Test func skipsEmptyOGTitle() {
        #expect(title(#"<meta property="og:title" content=""><title>代わり</title>"#) == "代わり")
    }

    @Test func returnsNilWithoutTitle() {
        #expect(title("<html><body>本文だけ</body></html>") == nil)
    }

    /// ヘッダーに文字コードがなければ、metaのcharsetで読む。ITmediaなど、Shift_JISのページがある。
    @Test func readsCharsetFromMetaWhenHeaderHasNone() throws {
        let html = #"<meta http-equiv="content-type" content="text/html;charset=shift_jis"><title>日本語の題</title>"#
        let data = try #require(html.data(using: .shiftJIS))
        #expect(PageTitle.title(in: data, contentType: "text/html") == "日本語の題")
    }

    @Test func readsCharsetFromHeader() throws {
        let data = try #require("<title>日本語の題</title>".data(using: .japaneseEUC))
        #expect(PageTitle.title(in: data, contentType: "text/html; charset=EUC-JP") == "日本語の題")
    }

    /// 読む量の上限で、複数バイトの文字の途中で切れても、読めた分で読む。
    @Test func readsTruncatedShiftJIS() throws {
        let html = #"<meta charset="Shift_JIS"><title>日本語の題</title><p>あ"#
        let data = try #require(html.data(using: .shiftJIS))
        #expect(PageTitle.title(in: data.dropLast(1), contentType: nil) == "日本語の題")
    }

    // MARK: - 読むのを止めるところ

    /// scriptの中の文字列や、空のog:titleでは止めない。本物のog:titleがあとに出てくることがあるため。
    @Test func keepsReadingPastFakeOrEmptyOGTitle() {
        #expect(!PageTitle.hasOGTitle(in: Data(#"<script>var key = "og:title"; if (a > b) {}</script>"#.utf8), contentType: nil))
        #expect(!PageTitle.hasOGTitle(in: Data(#"<meta property="og:title" content="">"#.utf8), contentType: nil))
    }

    @Test func stopsReadingAfterOGTitleTagEnds() {
        #expect(!PageTitle.hasOGTitle(in: Data(#"<meta property="og:title" content="途中"#.utf8), contentType: nil))
        #expect(PageTitle.hasOGTitle(in: Data(#"<meta property="og:title" content="済み">"#.utf8), contentType: nil))
    }

    // MARK: - HTMLかどうか

    @Test func readsOnlyHTMLPages() {
        #expect(PageTitleLoader.isHTML("text/html; charset=utf-8"))
        #expect(PageTitleLoader.isHTML("application/xhtml+xml"))
        #expect(PageTitleLoader.isHTML(nil))
        #expect(!PageTitleLoader.isHTML("image/png"))
        #expect(!PageTitleLoader.isHTML("application/pdf"))
    }

    // MARK: - 読み込み

    private func loader(_ responses: [StubTransport.Response]) -> PageTitleLoader {
        PageTitleLoader(client: HTTPClient(transport: StubTransport(responses), retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock()))
    }

    @Test func loadsTitleOfPage() async throws {
        let page = StubTransport.Response(statusCode: 200, body: Data("<html><head><title>見出し</title></head></html>".utf8), headers: ["Content-Type": "text/html"])
        #expect(try await loader([page]).title(of: try #require(URL(string: "https://example.com/"))) == "見出し")
    }

    /// サーバーが混んでいるときの429は、ほかの経路と同じく、再開までの長さを持つ失敗にする。
    @Test func rateLimitedPageIsStatusError() async throws {
        let busy = StubTransport.Response.json("", statusCode: 429, headers: ["Retry-After": "30"])
        let error = await #expect(throws: HTTPStatusError.self) {
            try await loader([busy]).title(of: try #require(URL(string: "https://example.com/")))
        }
        #expect(error?.statusCode == 429)
        #expect(error?.retryAfter == .seconds(30))
    }

    /// 上限より長いページは、上限までで探す。上限の後ろにあるタイトルは読まない。
    @Test func readsUpToMaxByteCount() async throws {
        let filler = String(repeating: " ", count: PageTitleLoader.maxByteCount)
        let page = StubTransport.Response(statusCode: 200, body: Data("<html>\(filler)<title>後ろ</title></html>".utf8), headers: ["Content-Type": "text/html"])
        #expect(try await loader([page]).title(of: try #require(URL(string: "https://example.com/"))) == nil)
    }

    // MARK: - 悪意のある形のページ

    /// `og:title`や閉じのない`<title`、`<meta "`を上限まで並べても、読み直しや探し直しで手間が2乗に増えない。
    /// 時間ではなく、探すのに見たバイトの数で確かめる。探すのは候補の数の上限までで、1回の探しでページを書き方（小文字、大文字、先頭だけ大文字）の数だけ見通すので、
    /// 見る量はページの大きさの決まった倍数と、候補ごとの決まった幅に収まる。
    @Test func staysLinearOnPagesFullOfCandidates() {
        let size = PageTitleLoader.maxByteCount
        // og:titleは、タイトルを読むときと、読み終えたかを確かめるときの2回探す。<titleは、開きと閉じを探す。
        let finds = 2 * PageTitle.maxOGTitleCandidates + 2 * PageTitle.maxTitleCandidates
        let windows = (2 * PageTitle.maxOGTitleCandidates + PageTitle.maxTitleCandidates) * (PageTitle.metaLookBehind + PageTitle.tagWindow)
        for unit in ["og:title", "<title ", #"<meta ""#] {
            let data = Data(String(repeating: unit, count: size / unit.utf8.count).utf8)
            var scanned = 0
            _ = PageTitle.title(in: data, contentType: nil, scanned: &scanned)
            _ = PageTitle.hasOGTitle(in: data, contentType: nil, scanned: &scanned)
            #expect(scanned <= 3 * finds * data.count + windows, "\(unit): \(scanned)")
        }
    }

    /// 調べ済みの位置より前のog:titleは、探し直さない。
    @Test func searchesFromGivenOffset() {
        let data = Data(#"<meta property="og:title" content="前">"#.utf8)
        #expect(PageTitle.hasOGTitle(in: data, contentType: nil, searchingFrom: 0))
        #expect(!PageTitle.hasOGTitle(in: data, contentType: nil, searchingFrom: data.count))
    }
}

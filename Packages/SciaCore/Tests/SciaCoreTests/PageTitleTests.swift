import Foundation
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

    // MARK: - 悪意のある形のページ

    /// `og:title`や閉じのない`<title`、`<meta "`を上限まで並べても、読み直しや探し直しで手間が2乗に増えない。
    @Test func staysFastOnPagesFullOfCandidates() {
        let size = PageTitleLoader.maxByteCount
        for unit in ["og:title", "<title ", #"<meta ""#] {
            let data = Data(String(repeating: unit, count: size / unit.utf8.count).utf8)
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                _ = PageTitle.title(in: data, contentType: nil)
                _ = PageTitle.hasOGTitle(in: data, contentType: nil)
            }
            #expect(elapsed < .seconds(2), "\(unit): \(elapsed)")
        }
    }

    /// 調べ済みの位置より前のog:titleは、探し直さない。
    @Test func searchesFromGivenOffset() {
        let data = Data(#"<meta property="og:title" content="前">"#.utf8)
        #expect(PageTitle.hasOGTitle(in: data, contentType: nil, searchingFrom: 0))
        #expect(!PageTitle.hasOGTitle(in: data, contentType: nil, searchingFrom: data.count))
    }
}

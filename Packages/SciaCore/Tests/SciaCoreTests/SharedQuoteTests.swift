import SciaCore
import Testing

struct SharedQuoteTests {
    @Test func putsTitleURLAndQuoteOnSeparateLines() {
        #expect(SharedQuote.body(title: "ページ", url: "https://example.com/a", selection: "選んだ文") == "ページ\nhttps://example.com/a\n> 選んだ文\n")
    }

    @Test func quotesEveryLineIncludingBlankOnes() {
        let selection = "1行目\n2行目\n\n次の段落\r\n改行コードが違う行"
        #expect(SharedQuote.body(title: nil, url: nil, selection: selection) == "> 1行目\n> 2行目\n>\n> 次の段落\n> 改行コードが違う行\n")
    }

    @Test func trimsWhitespaceAroundSelectionAndURL() {
        #expect(SharedQuote.body(title: nil, url: " https://example.com\n", selection: "\n  選んだ文 \n\n") == "https://example.com\n> 選んだ文\n")
    }

    @Test func putsTitleOnOneLine() {
        #expect(SharedQuote.body(title: "  長い\nタイトル  ", url: "https://example.com", selection: nil) == "長い タイトル\nhttps://example.com\n")
    }

    @Test(arguments: [nil, "", " \n"])
    func omitsQuoteWithoutSelection(_ selection: String?) {
        #expect(SharedQuote.body(title: "ページ", url: "https://example.com", selection: selection) == "ページ\nhttps://example.com\n")
    }

    @Test func usesOnlyQuoteWithoutTitleAndURL() {
        #expect(SharedQuote.body(title: nil, url: nil, selection: "選んだ文") == "> 選んだ文\n")
    }

    @Test func returnsNilWithoutAnything() {
        #expect(SharedQuote.body(title: " ", url: "", selection: "\n") == nil)
    }

    @Test(arguments: [
        ("", "共有"),
        ("@alice ", "@alice \n共有"),
        ("書きかけ", "書きかけ\n共有"),
        ("書きかけ\n", "書きかけ\n共有"),
    ])
    func appendsSharedTextToDraft(_ text: String, expected: String) {
        #expect(SharedQuote.appending("共有", to: text) == expected)
    }
}

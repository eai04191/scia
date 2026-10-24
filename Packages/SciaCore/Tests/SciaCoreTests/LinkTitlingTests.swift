import Foundation
import Testing
@testable import SciaCore

struct LinkTitlingTests {
    // MARK: - URLの一覧

    @Test func listsURLsInOrderOfAppearance() {
        let text = "見て https://b.example/2 と https://a.example/1"
        #expect(LinkTitling.urls(in: text) == ["https://b.example/2", "https://a.example/1"])
    }

    @Test func listsSameURLOnce() {
        let text = "https://a.example/ https://b.example/ https://a.example/"
        #expect(LinkTitling.urls(in: text) == ["https://a.example/", "https://b.example/"])
    }

    @Test func excludesTrailingPunctuationFromURL() {
        #expect(LinkTitling.urls(in: "これ https://a.example/x.") == ["https://a.example/x"])
    }

    /// 合成済みの「é」と、「e」と結合文字の「é」は、Swiftの文字列では同じとみなされるが、パーセントエンコードすると別のURLになる。
    @Test func listsCanonicallyEquivalentURLsSeparately() {
        let text = "https://a.example/caf\u{E9} https://a.example/cafe\u{301}"
        #expect(LinkTitling.urls(in: text).count == 2)
    }

    @Test func listsNothingWithoutURL() {
        #expect(LinkTitling.urls(in: "@bob #tag mail@example.com").isEmpty)
    }

    // MARK: - 置き換え

    @Test func replacesURLWithTitleAndURL() throws {
        let text = "見て https://youtu.be/abc"
        let replacement = try #require(LinkTitling.replacement(of: "https://youtu.be/abc", title: "動画の題", in: text))
        #expect(replacement.range == 3 ..< 23)
        #expect(replacement.text == "動画の題 https://youtu.be/abc")
    }

    /// 共有で貼ったリンクのように行の頭にあるURLは、タイトルを1行にし、改行で区切る。
    @Test func separatesTitleWithNewlineAtStartOfText() throws {
        let replacement = try #require(LinkTitling.replacement(of: "https://youtu.be/abc", title: "動画の題", in: "https://youtu.be/abc"))
        #expect(replacement.text == "動画の題\nhttps://youtu.be/abc")
    }

    @Test func separatesTitleWithNewlineAfterLineBreak() throws {
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "題", in: "見て\nhttps://a.example/"))
        #expect(replacement.range == 3 ..< 21)
        #expect(replacement.text == "題\nhttps://a.example/")
    }

    /// 前にその行の空白しかなければ、行の頭とみなす。字下げの空白は残す。
    @Test func treatsIndentedURLAsStartOfLine() throws {
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "題", in: "見て\n  https://a.example/"))
        #expect(replacement.range == 5 ..< 23)
        #expect(replacement.text == "題\nhttps://a.example/")
    }

    /// 前の文字とくっついているURLは、タイトルの前にも空白を入れ、前の文とつながらないようにする。
    @Test func insertsLeadingSpaceWhenURLFollowsText() throws {
        let text = "見てhttps://a.example/"
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "題名", in: text))
        #expect(replacement.text == " 題名 https://a.example/")
        #expect(replacement.titleRange == 3 ..< 5)
        #expect(replacement.urlRange == 6 ..< 24)
        let replaced = (text as NSString).replacingCharacters(in: NSRange(replacement.range), with: replacement.text) as NSString
        #expect(replaced.substring(with: NSRange(replacement.titleRange)) == "題名")
        #expect(replaced.substring(with: NSRange(replacement.urlRange)) == "https://a.example/")
    }

    /// 同じURLが2回あれば、最初の1か所だけを置き換える。
    @Test func replacesOnlyFirstOccurrence() throws {
        let text = "https://a.example/ と https://a.example/"
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "A", in: text))
        #expect(replacement.range == 0 ..< 18)
    }

    /// 選んだURLを前に含む長いURLは、別のURLとして置き換えない。
    @Test func doesNotReplaceLongerURLStartingWithSameText() throws {
        let text = "https://a.example/long https://a.example/"
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "A", in: text))
        #expect(replacement.range == 23 ..< 41)
    }

    /// 読んでいる間に、見た目が同じでも別のURLに書き換えられていれば、置き換えない。
    @Test func doesNotReplaceCanonicallyEquivalentURL() {
        let text = "https://a.example/cafe\u{301}"
        #expect(LinkTitling.replacement(of: "https://a.example/caf\u{E9}", title: "A", in: text) == nil)
    }

    /// 読んでいる間にURLが消されていれば、置き換えない。
    @Test func replacesNothingWhenURLIsGone() {
        #expect(LinkTitling.replacement(of: "https://a.example/", title: "A", in: "消した") == nil)
    }

    /// 位置はUTF-16で数える。絵文字の後ろのURLでも、入力欄の位置と合う。
    @Test func countsRangeInUTF16() throws {
        let text = "👍 https://a.example/"
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "A", in: text))
        #expect(replacement.range == 3 ..< 21)
    }

    /// ハイライトして押した2つ目を置き換える。読んでいる間に前で打たれてずれても、いちばん近いものを選ぶ。
    @Test func replacesOccurrenceNearestToPressedLocation() throws {
        let text = "前に足した https://a.example/ と https://a.example/"
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "A", in: text, nearestTo: 20))
        #expect(replacement.range == 27 ..< 45)
    }

    @Test func listsEveryOccurrenceWithRange() {
        let text = "https://a.example/ https://a.example/"
        #expect(LinkTitling.occurrences(in: text).map(\.range) == [0 ..< 18, 19 ..< 37])
    }

    /// 置き換えたあとの、タイトルとURLの範囲。浮かび上がらせる場所と、URLを動かす先を測るために使う。
    @Test func reportsTitleAndURLRangesAfterReplacement() throws {
        let replacement = try #require(LinkTitling.replacement(of: "https://a.example/", title: "題名", in: "見て https://a.example/"))
        #expect(replacement.titleRange == 3 ..< 5)
        #expect(replacement.urlRange == 6 ..< 24)
        let replaced = ("見て https://a.example/" as NSString).replacingCharacters(in: NSRange(location: 3, length: 18), with: replacement.text) as NSString
        #expect(replaced.substring(with: NSRange(location: 6, length: 18)) == "https://a.example/")
    }

    /// 同じURLを2か所続けて読み、先に前の方を置き換えたら、後の読み込みの場所を増えた分だけずらし、後の方を置き換える。
    @Test func shiftsPendingOccurrenceAfterEarlierReplacement() throws {
        let text = "https://a.example/ https://a.example/"
        let occurrences = LinkTitling.occurrences(in: text)
        let first = try #require(LinkTitling.replacement(of: "https://a.example/", title: "A page title", in: text, nearestTo: occurrences[0].range.lowerBound))
        let replaced = (text as NSString).replacingCharacters(in: NSRange(first.range), with: first.text)
        let pending = occurrences[1].adjusted(afterReplacing: first)
        let second = try #require(LinkTitling.replacement(of: "https://a.example/", title: "B", in: replaced, nearestTo: pending.range.lowerBound))
        #expect(second.range == 32 ..< 50)
    }

    @Test func keepsOccurrenceBeforeReplacement() throws {
        let text = "https://a.example/ https://b.example/"
        let occurrences = LinkTitling.occurrences(in: text)
        let replacement = try #require(LinkTitling.replacement(of: "https://b.example/", title: "B", in: text))
        #expect(occurrences[0].adjusted(afterReplacing: replacement) == occurrences[0])
    }

    // MARK: - タイトル

    @Test func joinsLinesOfTitleWithSpace() {
        #expect(LinkTitling.normalizedTitle("  上の行\n\n下の行\t ") == "上の行 下の行")
    }

    @Test func treatsBlankTitleAsNone() {
        #expect(LinkTitling.normalizedTitle(" \n ") == nil)
        #expect(LinkTitling.normalizedTitle(nil) == nil)
    }
}

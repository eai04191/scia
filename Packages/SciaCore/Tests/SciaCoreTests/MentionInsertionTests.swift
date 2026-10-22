import Testing
@testable import SciaCore

struct MentionInsertionTests {
    @Test func insertsMentionAndSpaceIntoEmptyText() {
        let insertion = MentionInsertion.insertion(of: "bob@example.com", in: "", replacing: 0 ..< 0)
        #expect(insertion == TextInsertion(range: 0 ..< 0, text: "@bob@example.com ", cursor: 17))
    }

    /// 前の文字とつながると、サーバーがメンションとして読まないため、前に空白を入れる。
    @Test func separatesMentionFromPrecedingText() {
        let insertion = MentionInsertion.insertion(of: "bob", in: "こんにちは", replacing: 5 ..< 5)
        #expect(insertion.text == " @bob ")
        #expect(insertion.cursor == 11)
    }

    @Test func addsNoLeadingSpaceAfterWhitespaceOrNewline() {
        #expect(MentionInsertion.insertion(of: "bob", in: "a ", replacing: 2 ..< 2).text == "@bob ")
        #expect(MentionInsertion.insertion(of: "bob", in: "a\n", replacing: 2 ..< 2).text == "@bob ")
    }

    /// 後ろにもとからある空白は足さず、カーソルをその空白の後ろに置く。
    @Test func reusesFollowingSpace() {
        let insertion = MentionInsertion.insertion(of: "bob", in: "a  b", replacing: 2 ..< 2)
        #expect(insertion.text == "@bob")
        #expect(insertion.cursor == 7)
    }

    @Test func separatesMentionFromFollowingText() {
        let insertion = MentionInsertion.insertion(of: "bob", in: "ab", replacing: 0 ..< 0)
        #expect(insertion.text == "@bob ")
        #expect(insertion.cursor == 5)
    }

    @Test func replacesSelection() {
        let insertion = MentionInsertion.insertion(of: "bob", in: "a xx b", replacing: 2 ..< 4)
        #expect(insertion == TextInsertion(range: 2 ..< 4, text: "@bob", cursor: 7))
    }

    /// 絵文字のように2単位の文字のあとでも、UTF-16で数える。
    @Test func countsInUTF16() {
        let insertion = MentionInsertion.insertion(of: "bob", in: "😀", replacing: 2 ..< 2)
        #expect(insertion == TextInsertion(range: 2 ..< 2, text: " @bob ", cursor: 8))
    }

    @Test func clampsSelectionOutsideText() {
        let insertion = MentionInsertion.insertion(of: "bob", in: "a", replacing: 5 ..< 9)
        #expect(insertion.range == 1 ..< 1)
    }
}
